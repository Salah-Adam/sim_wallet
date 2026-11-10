with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id') AS snapshot_id,
        get_json_object(record_json, '$.data.attempt_id') AS attempt_id,
        get_json_object(record_json, '$.data.payment_id') AS payment_id,
        get_json_object(record_json, '$.data.attempt_number') AS attempt_number,
        get_json_object(record_json, '$.data.started_at') AS started_at,
        get_json_object(record_json, '$.data.available_balance_cents_at_start') AS available_balance_cents_at_start,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'payment_attempts') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(attempt_id), '') as attempt_id,
       nullif(trim(payment_id), '') as payment_id,
       try_cast(attempt_number as int) as attempt_number,
       try_cast(started_at as timestamp) as started_at_utc,
       try_cast(available_balance_cents_at_start as bigint) as available_balance_cents_at_start,
       current_timestamp() as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted
