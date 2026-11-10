with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id') as snapshot_id,
        get_json_object(record_json, '$.data.entry_id') as entry_id,
        get_json_object(record_json, '$.data.wallet_id') as wallet_id,
        get_json_object(record_json, '$.data.attempt_id') as attempt_id,
        get_json_object(record_json, '$.data.payment_id') as payment_id,
        get_json_object(record_json, '$.data.entry_type') as entry_type,
        get_json_object(record_json, '$.data.currency') as currency,
        get_json_object(record_json, '$.data.signed_amount_cents') as signed_amount_cents,
        get_json_object(record_json, '$.data.posted_at') as posted_at,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'ledger_entries') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(entry_id), '') as entry_id,
       nullif(trim(wallet_id), '') as wallet_id,
       nullif(trim(attempt_id), '') as attempt_id,
       nullif(trim(payment_id), '') as payment_id,
       nullif(trim(entry_type), '') as entry_type,
       nullif(trim(currency), '') as currency,
       try_cast(signed_amount_cents as bigint) as signed_amount_cents,
       try_cast(posted_at as timestamp) as posted_at_utc,
       current_timestamp() as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted
