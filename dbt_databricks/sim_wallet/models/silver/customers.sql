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
    nullif(trim(customer_id), '') as customer_id,
    nullif(trim(full_name), '') as full_name,
    nullif(trim(home_city), '') as home_city,
    try_cast(registered_at as timestamp) as registered_at_utc,
    source_file,
    bronze_loaded_at,
    current_timestamp() as silver_processed_at_utc
from extracted