with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id')           as snapshot_id,
        get_json_object(record_json, '$.data.source_row_id')    as source_row_id,
        get_json_object(record_json, '$.data.event_id')         as event_id,
        get_json_object(record_json, '$.data.payment_id')       as payment_id,
        get_json_object(record_json, '$.data.attempt_id')       as attempt_id,
        get_json_object(record_json, '$.data.event_at')         as event_at,
        get_json_object(record_json, '$.data.status')           as status,
        get_json_object(record_json, '$.data.reason_code')      as reason_code,
        get_json_object(record_json, '$.data.reason_source')    as reason_source,
        get_json_object(record_json, '$.data.system_component') as system_component,
        get_json_object(record_json, '$.data.incident_id')      as incident_id,
        get_json_object(record_json, '$.data.delivery_id')      as delivery_id,
        get_json_object(record_json, '$.data.ingested_at')      as ingested_at,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'event_deliveries') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       try_cast(source_row_id as bigint)      as source_row_id,
       nullif(trim(event_id), '')             as event_id,
       nullif(trim(payment_id), '')           as payment_id,
       nullif(trim(attempt_id), '')           as attempt_id,
       try_cast(event_at as timestamp)        as event_at_utc,
       nullif(trim(status), '')               as status,
       nullif(trim(reason_code), '')          as reason_code,
       nullif(trim(reason_source), '')        as reason_source,
       nullif(trim(system_component), '')     as system_component,
       nullif(trim(incident_id), '')          as incident_id,
       nullif(trim(delivery_id), '')          as delivery_id,
       try_cast(ingested_at as timestamp)     as ingested_at_utc,
       current_timestamp()                    as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted