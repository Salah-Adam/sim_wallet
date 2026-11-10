with ranked as (
    select *,
           row_number()         over (partition by event_id order by ingested_at_utc, source_row_id) as copy_number,
           count(*)             over (partition by event_id) as delivery_count,
           max(ingested_at_utc) over (partition by event_id) as last_ingested_at_utc
    from {{ ref('event_deliveries') }}
)
select snapshot_id,
       event_id, payment_id, attempt_id,
       event_at_utc, status, reason_code, reason_source, system_component, incident_id,
       delivery_id                        as first_delivery_id,
       ingested_at_utc                    as first_ingested_at_utc,
       last_ingested_at_utc,
       delivery_count,
       unix_timestamp(ingested_at_utc) - unix_timestamp(event_at_utc) as latency_seconds,
       (unix_timestamp(ingested_at_utc) - unix_timestamp(event_at_utc))
           > {{ var('late_threshold_seconds') }}                       as is_late,
       current_timestamp()                as silver_processed_at_utc
from ranked
where copy_number = 1