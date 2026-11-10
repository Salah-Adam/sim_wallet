with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id') as snapshot_id,
        get_json_object(record_json, '$.data.wallet_id') as wallet_id,
        get_json_object(record_json, '$.data.ledger_balance_cents') as ledger_balance_cents,
        get_json_object(record_json, '$.data.currency') as currency,
        get_json_object(record_json, '$.data.available_balance_cents') as available_balance_cents,
        get_json_object(record_json, '$.data.held_balance_cents') as held_balance_cents,
        get_json_object(record_json, '$.data.snapshot_at') as snapshot_at,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'wallets_closing') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(wallet_id), '') as wallet_id,
       nullif(trim(currency), '') as currency,
       try_cast(ledger_balance_cents as bigint) as ledger_balance_cents,
       try_cast(available_balance_cents as bigint) as available_balance_cents,
       try_cast(held_balance_cents as bigint) as held_balance_cents,
       try_cast(snapshot_at as timestamp) as snapshot_at_utc,
       source_file, bronze_loaded_at,
       current_timestamp() as silver_processed_at_utc
from extracted