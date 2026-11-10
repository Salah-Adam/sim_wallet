with extracted as (
    select
       get_json_object(record_json, '$.snapshot_id') AS snapshot_id,
        get_json_object(record_json, '$.data.payment_id') AS payment_id,
        get_json_object(record_json, '$.data.sender_wallet_id') AS sender_wallet_id,
        get_json_object(record_json, '$.data.recipient_wallet_id') AS recipient_wallet_id,
        get_json_object(record_json, '$.data.amount_cents') AS amount_cents,
        get_json_object(record_json, '$.data.payment_type') AS payment_type,
        get_json_object(record_json, '$.data.currency') AS currency,
        get_json_object(record_json, '$.data.channel') AS channel,
        get_json_object(record_json, '$.data.origin_city') AS origin_city,
        get_json_object(record_json, '$.data.requested_at') AS requested_at,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'payment_requests') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(payment_id), '') as payment_id,
       nullif(trim(sender_wallet_id), '') as sender_wallet_id,
       nullif(trim(recipient_wallet_id), '') as recipient_wallet_id,
       try_cast(amount_cents as bigint) as amount_cents,
       nullif(trim(payment_type), '') as payment_type,
       nullif(trim(currency), '') as currency,
       nullif(trim(channel), '') as channel,
       nullif(trim(origin_city), '') as origin_city,
       try_cast(requested_at as timestamp) as requested_at_utc,
       current_timestamp() as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted
