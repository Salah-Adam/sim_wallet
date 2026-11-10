# Bronze to Silver with dbt: a simple three-step guide

Updated 27 October 2026 · Somali mobile-money project · Databricks + PyCharm

**Your workflow: explore Bronze → write one transformation query → build and inspect the Silver table.**

Your screenshot confirmed the earlier customer build succeeded. Keep your existing environment, connection profile and dbt project. Do not initialize the project or reload MySQL/landing/Bronze again.

This version removes the separate customer staging model and postpones automated dbt tests. It keeps manual inspection inside the workflow. A successful SQL execution alone does not prove that the data is correct.

## Before you start: switch your existing customer model once

Your project folder is:

```text
C:\Users\hp\Documents\Data\practice\som-telecom\assets\dbt_databricks\sim_wallet
```

Keep `dbt_project.yml`, `models/sources.yml`, and `models/silver/customers.sql`.

When you reach step 2, replace the content of the existing `customers.sql` with the direct-from-Bronze query below. Do not create a second customer model with the same name.

To retire the old customer example, create `archive_previous_customer` directly inside the project root, beside `models` and `tests`. Move these three example files there, preserving their subfolders if you prefer:

- `models/staging/stg_customers.sql`
- `models/customers_tests.yml`
- `tests/customers_blank_fields.sql`

Do this only for the original example files. If you have added other models or tests referencing `stg_customers`, update those references before retiring it. If a YAML file contains other models' tests, move only the customer-related sections. Keep the archive outside the configured `models` and `tests` paths so dbt will not parse the retired files. Leaving a test that references a removed model can cause a parsing error even with `dbt run`.

The old `sim_wallet.silver.stg_customers` view can remain in Databricks for now; the new customer model will not use it. Removing a local model file does not automatically remove the corresponding database view. No database deletion is needed for this change.

Use the project settings in the reference section below, or remove only the unused `staging:` configuration if no staging models remain. You do not need new test files for this workflow.

## Step 1 — Explore the Bronze table

**Where:** Databricks SQL editor.

Before writing transformations, find out what one row represents and which values need attention. For customers, the intended result is one row per `customer_id` in the selected snapshot.

### Check the structure and snapshot first

```sql
DESCRIBE TABLE sim_wallet.bronze.customers;

SELECT
    get_json_object(record_json, '$.snapshot_id') AS snapshot_id,
    COUNT(*) AS row_count
FROM sim_wallet.bronze.customers
GROUP BY 1;
```

The expected Bronze columns are `record_json`, `source_file`, and `loaded_at`. Confirm that `somali_snapshot_v1` exists before using that ID below. A NULL snapshot ID needs investigation: it could mean malformed JSON or a missing field. Do not silently ignore such rows by immediately filtering to a valid snapshot.

### Inspect some original values

```sql
SELECT
    get_json_object(record_json, '$.data.customer_id') AS customer_id,
    get_json_object(record_json, '$.data.full_name') AS full_name,
    get_json_object(record_json, '$.data.home_city') AS home_city,
    get_json_object(record_json, '$.data.registered_at') AS registered_at
FROM sim_wallet.bronze.customers
WHERE get_json_object(record_json, '$.snapshot_id') = 'somali_snapshot_v1'
LIMIT 20;
```

A sample helps you understand the format. It does not prove that every row is valid.

### Check the whole selected customer snapshot

```sql
WITH extracted AS (
    SELECT
        get_json_object(record_json, '$.data.customer_id') AS customer_id,
        get_json_object(record_json, '$.data.full_name') AS full_name,
        get_json_object(record_json, '$.data.home_city') AS home_city,
        get_json_object(record_json, '$.data.registered_at') AS registered_at
    FROM sim_wallet.bronze.customers
    WHERE get_json_object(record_json, '$.snapshot_id') = 'somali_snapshot_v1'
)
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT customer_id) AS distinct_customer_ids,
    COUNT_IF(customer_id IS NULL OR TRIM(customer_id) = '') AS missing_ids,
    COUNT_IF(full_name IS NULL OR TRIM(full_name) = '') AS missing_names,
    COUNT_IF(home_city IS NULL OR TRIM(home_city) = '') AS missing_cities,
    COUNT_IF(registered_at IS NULL OR TRIM(registered_at) = '') AS missing_dates,
    COUNT_IF(
        registered_at IS NOT NULL
        AND TRIM(registered_at) <> ''
        AND TRY_CAST(registered_at AS TIMESTAMP) IS NULL
    ) AS invalid_dates
FROM extracted;
```

After accounting for NULL IDs, compare row count with distinct IDs to spot repeated IDs. If counts indicate a problem, inspect the affected records before choosing a fix. Do not deduplicate customers by name: different people can share the same name.

For city spellings, inspect the distinct values and their frequencies. Standardize only variants you have confirmed refer to the same place. Registration dates before July are valid; check implausibly late dates against the dataset's snapshot cutoff, not today's date.

### Decide the transformation rules

For the starter customer model we will:

- Preserve customer IDs as received.
- Trim surrounding spaces from names and cities.
- Represent blank names and cities as NULL, so missing values are visible.
- Convert registration strings into timestamps.
- Keep the snapshot ID and ingestion provenance for traceability.
- Preserve rows; do not invent missing names, automatically deduplicate, or silently drop bad records.

These are starter rules, not proof that your data has those problems. Add further rules only after exploring the data. If you find invalid required values, investigate and decide whether to correct or quarantine them before treating the result as ready for analysis.

## Step 2 — Write one transformation query

**Where:** PyCharm, in `models/silver/customers.sql`.

Replace the previous customer query with:

```sql
with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id') as snapshot_id,
        get_json_object(record_json, '$.data.customer_id') as customer_id,
        get_json_object(record_json, '$.data.full_name') as full_name,
        get_json_object(record_json, '$.data.home_city') as home_city,
        get_json_object(record_json, '$.data.registered_at') as registered_at,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'customers') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select
    snapshot_id,
    customer_id,
    nullif(trim(full_name), '') as full_name,
    nullif(trim(home_city), '') as home_city,
    try_cast(registered_at as timestamp) as registered_at_utc,
    source_file,
    bronze_loaded_at
from extracted
```

**This is one model and one output table.** The `extracted` section is a CTE: a named section inside the SQL query. It does not create a separate staging view or table.

`source('bronze', 'customers')` points to `sim_wallet.bronze.customers` through `models/sources.yml`. Write a SELECT statement; dbt handles creating the output table. Do not add CREATE TABLE or INSERT here.

Malformed dates become NULL with `TRY_CAST`; that makes the problem visible but does not repair it. Original values remain available in Bronze. With the UTC connection setting, timestamp processing uses UTC.

## Step 3 — Build the Silver table and inspect it

**Where to run dbt:** PyCharm's PowerShell terminal.

```powershell
cd "C:\Users\hp\Documents\Data\practice\som-telecom\assets\dbt_databricks\sim_wallet"
..\.venv\Scripts\dbt.exe run --select customers
```

This executes your transformation in Databricks and creates or rebuilds:

```text
sim_wallet.silver.customers
```

There is no separate loading command. `dbt run` builds the selected model without running automated data tests. There is no need for `+customers` here because the model reads directly from an existing Bronze source and has no upstream dbt models to build.

Your laptop sends the SQL; Databricks processes the data and stores the Delta table. A normal rerun of this ordinary table model rebuilds the result rather than appending another copy. No extraction checkpoint or incremental model is needed for this frozen snapshot.

**Then inspect the output in the Databricks SQL editor:**

```sql
SELECT * FROM sim_wallet.silver.customers LIMIT 20;

DESCRIBE DETAIL sim_wallet.silver.customers;
```

Confirm the format is Delta. For this transformation, no rows should be added or removed. Compare counts for the same snapshot:

```sql
SELECT 'bronze' AS layer, COUNT(*) AS row_count
FROM sim_wallet.bronze.customers
WHERE get_json_object(record_json, '$.snapshot_id') = 'somali_snapshot_v1'
UNION ALL
SELECT 'silver' AS layer, COUNT(*) AS row_count
FROM sim_wallet.silver.customers
WHERE snapshot_id = 'somali_snapshot_v1';
```

Matching counts are useful but do not prove that every value is correct. Also check the output:

```sql
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT customer_id) AS distinct_customer_ids,
    COUNT_IF(customer_id IS NULL OR TRIM(customer_id) = '') AS missing_ids,
    COUNT_IF(full_name IS NULL OR TRIM(full_name) = '') AS missing_names,
    COUNT_IF(home_city IS NULL OR TRIM(home_city) = '') AS missing_cities,
    COUNT_IF(registered_at_utc IS NULL) AS missing_or_invalid_dates
FROM sim_wallet.silver.customers
WHERE snapshot_id = 'somali_snapshot_v1';
```

For this customer table, expect a nonempty result, unique nonblank IDs, and no missing required fields. Investigate discrepancies rather than assuming the expected row count is always 5,000. Compare a few records with Bronze to verify the cleaning itself. These are manual SQL checks, not extra dbt test files.

If a check reveals a problem, return to step 1, adjust the query in step 2, and rerun step 3. Keep Bronze unchanged.

## Three steps or seven steps: when to use each

| Situation | Simple three-step workflow | Earlier seven-step workflow |
|---|---|---|
| Main purpose | Learn and deliver a straightforward transformation | Manage reusable logic and repeatable quality checks |
| Typical structure | Bronze → one Silver model | Bronze → staging model → Silver model, with tests |
| Good fit | Your frozen snapshot, simple tables, one learner | Shared projects, repeated runs, several dependent models |
| Quality checks | You run and inspect SQL checks manually | dbt runs the checks automatically |
| Main tradeoff | Fewer files; easier to forget a check or repeat logic | More files and setup; easier to reuse logic and catch regressions |
| When to change | Repeated cleaning logic, long queries, or overlooked checks | Simplify stages that add no meaningful reuse or clarity |

The earlier seven activities were: explore, decide rules, write staging SQL, write staging tests, write Silver SQL, write Silver tests, then build and inspect. The three-step version groups rule decisions into exploration and manual checks into the final step. It also removes the separate staging model.

**Staging and automated tests are independent choices.** You can keep one direct Bronze-to-Silver model and add tests to it later. You do not have to adopt all seven activities as separate stages. A simple production model can also read Bronze directly; frequent or important outputs benefit from automated checks regardless of model count.

Use the simple version now. When two models repeat the same parsing or cleaning, consider a shared staging model. When you keep repeating the same manual checks, turn them into dbt tests. Staging views do not inherently make transformations faster, and a large row count alone does not require a staging layer.

For the remaining payment tables, repeat the three-step workflow with table-specific rules. Event delivery deduplication, attempt outcomes and ledger reconciliation need more thought than trimming customer names. In particular:

- Repeated `event_id` values can be legitimate repeated deliveries; `delivery_id` identifies a distinct delivery.
- A negative ledger amount can be a valid debit.
- A failed transfer is a business outcome, not automatically a bad data row.
- PENDING/timeouts are not confirmed failures; failure reasons come from the system only.
- Do not join one payment to many events and then sum its requested amount repeatedly.

Split a complicated query into purposeful models when it becomes hard to understand or needs reuse. You do not have to force one output table per source forever.

## Reference: the settings you keep

These settings support the three steps; they are not tasks to repeat for every table. Preserve unrelated settings or models you have added.

### dbt_project.yml

```yaml
name: sim_wallet
version: '1.0.0'
config-version: 2
profile: sim_wallet

model-paths: ['models']
test-paths: ['tests']
analysis-paths: ['analyses']
seed-paths: ['seeds']
macro-paths: ['macros']
snapshot-paths: ['snapshots']
clean-targets: ['target', 'dbt_packages']

vars:
  bronze_catalog: sim_wallet
  bronze_schema: bronze
  snapshot_id: somali_snapshot_v1

models:
  sim_wallet:
    silver:
      +materialized: table
      +file_format: delta
```

The profile already targets the `silver` schema. Do not add `+schema: silver`, which would produce `silver_silver` with dbt's default custom-schema naming.

### models/sources.yml

```yaml
version: 2
sources:
  - name: bronze
    database: "{{ var('bronze_catalog') }}"
    schema: "{{ var('bronze_schema') }}"
    tables:
      - name: customers
      - name: wallets_opening
      - name: wallets_closing
      - name: payment_requests
      - name: payment_attempts
      - name: event_deliveries
      - name: ledger_entries
      - name: reason_codes
      - name: system_incidents
      - name: dataset_metadata
```

Here `database` means the Databricks catalog. This file describes existing Bronze tables; it does not create or load them.

### Connection profile: C:\Users\hp\.dbt\profiles.yml

Keep your working profile. Your confirmed settings were:

```yaml
sim_wallet:
  target: dev
  outputs:
    dev:
      type: databricks
      host: dbc-38d47863-b618.cloud.databricks.com
      http_path: /sql/1.0/warehouses/45fc9650c093b0d2
      catalog: sim_wallet
      schema: silver
      auth_type: oauth
      threads: 1
      session_properties:
        TIMEZONE: UTC
```

If the warehouse changes, copy its new HTTP path from SQL Warehouses → Connection details. Use `TIMEZONE`, not the rejected `spark.sql.session.timeZone` setting. To diagnose a connection issue from the project folder:

```powershell
..\.venv\Scripts\dbt.exe debug
```

### Automatic initialization — only for a fresh project

Your current project already exists. These commands are only a reference for starting again in a new, empty parent folder with Python 3.12; do not run them again in your working project:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install "dbt-databricks==1.12.8"
.\.venv\Scripts\dbt.exe init sim_wallet --skip-profile-setup
```

Then configure the OAuth profile, remove the untouched generated `models/example` files, and use the settings above. The virtual environment is in `dbt_databricks`; the project is its `sim_wallet` subfolder. No new PyCharm window or dbt Cloud account is required.

## Scope and verification

This guide implements the customer example only. The other source declarations are available for you to develop their transformations. The existing Silver learning guide remains a deeper reference; its staging/test examples are optional extensions, not prerequisites for this simpler workflow.

The three YAML blocks were validated and all seven SELECT statements passed a Databricks-dialect syntax parser after substituting the dbt references. DESCRIBE commands were excluded from that parser check. These checks do not execute SQL or establish data correctness. The rewritten model has not been executed against your Databricks workspace while preparing this document. Your earlier screenshot verified the previous two-model build, not this revised direct model. Use step 3 to confirm its output with your actual data.

## References

- [dbt SQL models: how SELECT statements become tables](https://docs.getdbt.com/docs/build/sql-models)
- [dbt run](https://docs.getdbt.com/reference/commands/run)
- [dbt staging guidance: reusable source preparation](https://docs.getdbt.com/best-practices/how-we-structure/2-staging)
- [dbt data tests](https://docs.getdbt.com/docs/build/data-tests)
- [Databricks: connect dbt Core](https://docs.databricks.com/aws/en/partners/prep/dbt)
- [Databricks SQL TIMEZONE](https://docs.databricks.com/aws/en/sql/language-manual/parameters/timezone)
