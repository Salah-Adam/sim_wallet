with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id') as snapshot_id,
        get_json_object(record_json, '$.data.wallet_id') as wallet_id,
        get_json_object(record_json, '$.data.customer_id') as customer_id,
        get_json_object(record_json, '$.data.currency') as currency,
        get_json_object(record_json, '$.data.opening_balance_cents') as opening_balance_cents,
        get_json_object(record_json, '$.data.snapshot_at') as snapshot_at,
        get_json_object(record_json, '$.data.status') as status,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'wallets_opening') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(wallet_id), '') as wallet_id,
       nullif(trim(customer_id), '') as customer_id,
       nullif(trim(currency), '') as currency,
       try_cast(opening_balance_cents as bigint) as opening_balance_cents,
       nullif(trim(status), '') as status,
       try_cast(snapshot_at as timestamp) as snapshot_at_utc,
       source_file, bronze_loaded_at,
       current_timestamp() as silver_processed_at_utc
from extracted