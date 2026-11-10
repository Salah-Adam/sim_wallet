with extracted as (
    select
       get_json_object(record_json, '$.snapshot_id') AS snapshot_id,
        get_json_object(record_json, '$.data.reason_code') AS reason_code,
        get_json_object(record_json, '$.data.reason_class') AS reason_class,
        get_json_object(record_json, '$.data.description') AS description,
        get_json_object(record_json, '$.data.retry_after_confirmed_failure') AS retry_after_confirmed_failure,
        get_json_object(record_json, '$.data.system_component') AS system_component,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'reason_codes') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(reason_code), '') as reason_code,
       nullif(trim(reason_class), '') as reason_class,
       nullif(trim(description), '') as description,
       nullif(trim(retry_after_confirmed_failure), '') as retry_after_confirmed_failure,
       nullif(trim(system_component), '') as system_component,
       current_timestamp() as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted
