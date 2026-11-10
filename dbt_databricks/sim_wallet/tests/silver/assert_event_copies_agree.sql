-- Copies of one event_id must be identical in every business field.
select event_id, count(*) as variants
from (
    select distinct event_id, payment_id, attempt_id, event_at_utc, status,
                    reason_code, reason_source, system_component, incident_id
    from {{ ref('event_deliveries') }}
)
group by event_id
having count(*) > 1