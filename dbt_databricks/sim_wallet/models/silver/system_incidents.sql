with extracted as (
    select
       get_json_object(record_json, '$.snapshot_id') AS snapshot_id,
        get_json_object(record_json, '$.data.incident_id') AS incident_id,
        get_json_object(record_json, '$.data.incident_type') AS incident_type,
        get_json_object(record_json, '$.data.affected_channel') AS affected_channel,
        get_json_object(record_json, '$.data.affected_city') AS affected_city,
        get_json_object(record_json, '$.data.started_at') AS started_at,
        get_json_object(record_json, '$.data.ended_at') AS ended_at,
        get_json_object(record_json, '$.data.recorded_by') AS recorded_by,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'system_incidents') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(incident_id), '') as incident_id,
       nullif(trim(incident_type), '') as incident_type,
       nullif(trim(affected_channel), '') as affected_channel,
       nullif(trim(affected_city), '') as affected_city,
       try_cast(started_at as timestamp) as started_at_utc,
       try_cast(ended_at as timestamp) as ended_at_utc,
       nullif(trim(recorded_by), '') as recorded_by,
       current_timestamp() as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted
