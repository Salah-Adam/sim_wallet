with extracted as (
    select
        get_json_object(record_json, '$.snapshot_id')        as snapshot_id,
        get_json_object(record_json, '$.data.metadata_key')  as metadata_key,
        get_json_object(record_json, '$.data.metadata_json') as metadata_json,
        source_file,
        loaded_at as bronze_loaded_at
    from {{ source('bronze', 'dataset_metadata') }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select snapshot_id,
       nullif(trim(metadata_key), '') as metadata_key,
       try_cast(get_json_object(metadata_json, '$.observation_start_utc') as timestamp)            as observation_start_utc,
       try_cast(get_json_object(metadata_json, '$.observation_cutoff_exclusive_utc') as timestamp) as observation_cutoff_utc,
       get_json_object(metadata_json, '$.business_timezone')                                       as business_timezone,
       get_json_object(metadata_json, '$.currency')                                                as currency,
       try_cast(get_json_object(metadata_json, '$.days') as int)                                   as days,
       try_cast(get_json_object(metadata_json, '$.customers') as int)                              as customers,
       try_cast(get_json_object(metadata_json, '$.payments') as int)                               as payments,
       try_cast(get_json_object(metadata_json, '$.transfer_limit_cents') as bigint)                as transfer_limit_cents,
       try_cast(get_json_object(metadata_json, '$.max_attempts') as int)                           as max_attempts,
       try_cast(get_json_object(metadata_json, '$.duplicate_rate') as double)                      as duplicate_rate,
       try_cast(get_json_object(metadata_json, '$.late_rate') as double)                           as late_rate,
       try_cast(get_json_object(metadata_json, '$.drop_rate') as double)                           as drop_rate,
       try_cast(get_json_object(metadata_json, '$.retry_probability') as double)                   as retry_probability,
       get_json_object(metadata_json, '$.generator_version')                                       as generator_version,
       metadata_json                                                                               as metadata_json_raw,
       current_timestamp() as silver_processed_at_utc,
       source_file, bronze_loaded_at
from extracted
where trim(metadata_key) = 'generation_config'