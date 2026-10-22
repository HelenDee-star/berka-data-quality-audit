-- ============================================================
-- Step 4: Data quality rules - Berka dataset
-- Script 01: Inspect, load raw tables, check row counts
-- Source path: /Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/
-- ============================================================

-- 1. Inspect the files (nothing is created, we only look)

-- 1.1 Account
SELECT *
FROM read_csv_auto('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/account.asc', delim=';')
LIMIT 10;

-- 1.2 Client
SELECT *
FROM read_csv_auto('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/client.asc', delim=';')
LIMIT 10;

-- 1.3 Disposition
SELECT *
FROM read_csv_auto('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/disp.asc', delim=';')
LIMIT 10;

-- 1.4 Transaction
SELECT *
FROM read_csv_auto('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/trans.asc', delim=';')
LIMIT 10;


-- 2. Load untouched copies of the source (all columns as text)

CREATE TABLE raw_account AS
SELECT *
FROM read_csv('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/account.asc',
              delim=';', header=true, all_varchar=true);

CREATE TABLE raw_client AS
SELECT *
FROM read_csv('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/client.asc',
              delim=';', header=true, all_varchar=true);

CREATE TABLE raw_disp AS
SELECT *
FROM read_csv('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/disp.asc',
              delim=';', header=true, all_varchar=true);

CREATE TABLE raw_trans AS
SELECT *
FROM read_csv('/Users/helenadesoba/Desktop/D Girl/Data Governance_Materials/DG_Training/berka-dataset-master/trans.asc',
              delim=';', header=true, all_varchar=true);


-- 3. Row counts (compare with the source: expect about 4500 / 5369 / 5369 / 1056320)

SELECT 'account' AS table_name, COUNT(*) AS row_count FROM raw_account
UNION ALL SELECT 'client', COUNT(*) FROM raw_client
UNION ALL SELECT 'disp',   COUNT(*) FROM raw_disp
UNION ALL SELECT 'trans',  COUNT(*) FROM raw_trans;



-- ============================================================
-- Step 4: Data quality rules - Berka dataset
-- Script 02: Profile raw_trans (look before writing rules)
-- ============================================================


-- 1. Values in the direction column (type): which values exist and how often?
SELECT type, COUNT(*) AS row_count
FROM raw_trans
GROUP BY type
ORDER BY row_count DESC;


-- 2. Amount: can every value be read as a number?
-- (rows where the text cannot be converted)
SELECT COUNT(*) AS not_a_number
FROM raw_trans
WHERE TRY_CAST(amount AS DECIMAL(18,2)) IS NULL;


-- 3. Amount: how many are zero or negative? (rule: greater than zero)
SELECT COUNT(*) AS amount_not_positive
FROM raw_trans
WHERE TRY_CAST(amount AS DECIMAL(18,2)) <= 0;


-- 4. Amount: show those rows so we can see what they look like
SELECT *
FROM raw_trans
WHERE TRY_CAST(amount AS DECIMAL(18,2)) <= 0;


-- 5. Date: can every value be read as a date? (format YYMMDD)
SELECT COUNT(*) AS invalid_date
FROM raw_trans
WHERE TRY_STRPTIME(date, '%y%m%d') IS NULL;


-- 6. Uniqueness of the transaction identifier
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT trans_id) AS distinct_ids
FROM raw_trans;


-- ============================================================
-- Step 4: Data quality rules - Berka dataset
-- Script 03: Profile raw_account, raw_client, raw_disp
-- ============================================================


-- 1. Direction mapping: which type/operation combinations exist?
SELECT type, operation, COUNT(*) AS row_count
FROM raw_trans
GROUP BY type, operation
ORDER BY type, operation;


-- 2. Uniqueness of the account identifier
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT account_id) AS distinct_ids
FROM raw_account;


-- 3. Uniqueness of the client identifier
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT client_id) AS distinct_ids
FROM raw_client;


-- 4. Accounts with no OWNER (rule: every Account has at least one Account Holder)
SELECT COUNT(*) AS accounts_without_owner
FROM raw_account a
WHERE NOT EXISTS (
    SELECT 1 FROM raw_disp d
    WHERE d.account_id = a.account_id
      AND d.type = 'OWNER'
);


-- 5. Clients with no OWNER record (these would be reported for review)
SELECT COUNT(*) AS clients_without_owner_record
FROM raw_client c
WHERE NOT EXISTS (
    SELECT 1 FROM raw_disp d
    WHERE d.client_id = c.client_id
      AND d.type = 'OWNER'
);


-- 6. Accounts opened AFTER their first transaction (date level only)
SELECT COUNT(*) AS opened_after_first_transaction
FROM raw_account a
JOIN (
    SELECT account_id,
           MIN(TRY_STRPTIME(date, '%y%m%d')) AS first_trans_date
    FROM raw_trans
    GROUP BY account_id
) t ON a.account_id = t.account_id
WHERE TRY_STRPTIME(a.date, '%y%m%d') > t.first_trans_date;

-- 7. what are the credits with no operation? (basis for "internal posting")

-- WHY: Query 1 showed 183,114 PRIJEM (credit) transactions with an empty
--      operation. In the model every column is required (L6), so these rows
--      would have no Channel. Before deciding how to treat them, we needed to
--      know what they are.
-- FINDING: All 183,114 have k_symbol = UROK (interest credited). This
--      supports adding an "internal posting" value to Channel Type, as a
--      model decision that needs an approver.
SELECT k_symbol, COUNT(*) AS row_count
FROM raw_trans
WHERE operation IS NULL OR TRIM(operation) = ''
GROUP BY k_symbol
ORDER BY row_count DESC;


-- 8. Are the 869 clients without an OWNER exactly the DISPONENT clients?
-- WHY: Query 5 returned 869 clients with no OWNER record, which is the same
--      number as the DISPONENT rows in disp. The matching count suggested a
--      cause, but did not prove it. This query tests it directly.
-- FINDING: Returns 869. Every client without an OWNER is a DISPONENT.
--      Authorised signatories are out of scope (C3), so these clients appear
--      as Customers with no Account Holder. This is an effect of the chosen
--      scope, not a data error, which is why rule R5 is a review queue.
SELECT COUNT(*) AS clients_only_disponent
FROM raw_client c
WHERE NOT EXISTS (SELECT 1 FROM raw_disp d WHERE d.client_id = c.client_id AND d.type = 'OWNER')
  AND EXISTS     (SELECT 1 FROM raw_disp d WHERE d.client_id = c.client_id AND d.type = 'DISPONENT');


