with cutoff as (
    select observation_cutoff_utc from {{ ref('dataset_metadata') }}
),

attempts as (
    select attempt_id, payment_id, attempt_number, started_at_utc,
           max(attempt_number) over (partition by payment_id) > attempt_number as has_later_attempt
    from {{ ref('payment_attempts') }}
),

-- only what analytics had received before the cutoff
known_events as (
    select e.*
    from {{ ref('events') }} e
    cross join cutoff c
    where e.first_ingested_at_utc < c.observation_cutoff_utc
),

event_evidence as (
    select attempt_id,
           count(*)                                                 as event_count,
           max(case when status = 'PENDING'   then 1 else 0 end) = 1 as has_pending,
           max(case when status = 'SUCCEEDED' then 1 else 0 end) = 1 as has_succeeded,
           max(case when status = 'FAILED'    then 1 else 0 end) = 1 as has_failed,
           max(case when status = 'FAILED'    then reason_code end)  as failure_reason_code
    from known_events
    group by attempt_id
),

-- latest event by business time; on a tie, the more advanced status wins
latest_event as (
    select attempt_id,
           status           as latest_status,
           event_at_utc     as latest_event_at_utc,
           reason_code      as latest_reason_code,
           system_component as latest_system_component,
           incident_id      as latest_incident_id
    from (
        select *,
               row_number() over (
                   partition by attempt_id
                   order by event_at_utc desc,
                            case status when 'REQUESTED' then 1 when 'PENDING' then 2 else 3 end desc
               ) as rn
        from known_events
    )
    where rn = 1
),

ledger_evidence as (
    select attempt_id,
           count(*)                 as ledger_entry_count,
           sum(signed_amount_cents) as ledger_net_cents
    from {{ ref('ledger_entries') }}
    group by attempt_id
),

combined as (
    select a.attempt_id, a.payment_id, a.attempt_number, a.started_at_utc, a.has_later_attempt,
           c.observation_cutoff_utc,
           coalesce(ev.event_count, 0)       as event_count,
           coalesce(ev.has_pending, false)   as has_pending,
           coalesce(ev.has_succeeded, false) as has_succeeded,
           coalesce(ev.has_failed, false)    as has_failed,
           ev.failure_reason_code,
           le.latest_status, le.latest_event_at_utc, le.latest_reason_code,
           le.latest_system_component, le.latest_incident_id,
           coalesce(l.ledger_entry_count, 0) as ledger_entry_count,
           coalesce(l.ledger_net_cents, 0)   as ledger_net_cents,
           coalesce(l.ledger_entry_count, 0) = 2 and coalesce(l.ledger_net_cents, 0) = 0 as has_balanced_ledger
    from attempts a
    cross join cutoff c
    left join event_evidence  ev on ev.attempt_id = a.attempt_id
    left join latest_event    le on le.attempt_id = a.attempt_id
    left join ledger_evidence l  on l.attempt_id  = a.attempt_id
),

classified as (
    select *,
           case
               when has_succeeded and has_failed          then 'CONFLICT'
               when has_failed and ledger_entry_count > 0 then 'CONFLICT'
               when has_succeeded                         then 'SUCCEEDED'
               when has_failed                            then 'FAILED'
               when has_balanced_ledger                   then 'SUCCEEDED'
               when has_later_attempt                     then 'FAILED'
               when has_pending                           then 'PENDING'
               else                                            'UNKNOWN'
           end as final_outcome,
           case
               when (has_succeeded and has_failed)
                 or (has_failed and ledger_entry_count > 0) then 'CONFLICTING_EVIDENCE'
               when has_succeeded or has_failed             then 'EVENT'
               when has_balanced_ledger                     then 'LEDGER'
               when has_later_attempt                       then 'RETRY'
               when has_pending                             then 'PENDING_EVENT'
               when event_count > 0                         then 'REQUESTED_ONLY'
               else                                              'NO_EVENTS'
           end as outcome_source
    from combined
)

select *,
       final_outcome in ('SUCCEEDED', 'FAILED') as is_definitive,
       case when final_outcome not in ('SUCCEEDED', 'FAILED')
            then unix_timestamp(observation_cutoff_utc) - unix_timestamp(started_at_utc)
       end as age_at_cutoff_seconds
from classified