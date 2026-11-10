-- Q4: one row per incident. Attempts during the incident (inside its city/channel scope) are compared with
-- the same scope, the same local weekday and the same local clock-time window on other dates.
-- Comparison attempts that fall inside any incident are excluded. This shows association, not cause.
with incidents as (
    select incident_id, incident_type, affected_city, affected_channel,
           started_at_utc, ended_at_utc, started_at_local, ended_at_local,
           incident_date_local, incident_weekday_local, duration_minutes,
           hour(started_at_local) * 3600 + minute(started_at_local) * 60 + second(started_at_local) as start_second_of_day,
           hour(ended_at_local)   * 3600 + minute(ended_at_local)   * 60 + second(ended_at_local)   as end_second_of_day
    from {{ ref('dim_incident') }}
),

attempts as (
    select a.attempt_id, a.channel, a.origin_city,
           a.started_at_utc, a.started_date_local, a.started_weekday_local,
           hour(a.started_at_local) * 3600 + minute(a.started_at_local) * 60 + second(a.started_at_local) as second_of_day,
           a.is_definitive,
           a.failure_reason_code,
           coalesce(r.failure_category, 'NOT_FAILED') as failure_category
    from {{ ref('fct_payment_attempts') }} a
    left join {{ ref('dim_reason') }} r on r.reason_code = a.failure_reason_code
),

-- every (incident, attempt) pair inside the incident's city and channel scope
in_scope as (
    select i.incident_id,
           a.*,
           a.started_at_utc >= i.started_at_utc
             and a.started_at_utc < i.ended_at_utc               as is_during_incident,
           a.started_date_local <> i.incident_date_local
             and a.started_weekday_local = i.incident_weekday_local
             and a.second_of_day >= i.start_second_of_day
             and a.second_of_day <  i.end_second_of_day          as is_in_comparison_window
    from incidents i
    join attempts a
      on (i.affected_city    = 'ALL' or a.origin_city = i.affected_city)
     and (i.affected_channel = 'ALL' or a.channel     = i.affected_channel)
),

attempts_during_any_incident as (
    select distinct attempt_id
    from in_scope
    where is_during_incident
),

during as (
    select incident_id,
           count(*)                                              as attempts,
           count_if(failure_category = 'TECHNICAL_FAILURE')      as technical_failures,
           count_if(failure_reason_code = 'SERVICE_UNAVAILABLE') as service_unavailable_failures,
           count_if(failure_reason_code = 'PROCESSING_ERROR')    as processing_error_failures,
           count_if(failure_reason_code = 'PROCESSING_EXPIRED')  as processing_expired_failures,
           count_if(failure_category = 'UNKNOWN_REASON')         as unknown_reason_failures,
           count_if(failure_category = 'VALID_REJECTION')        as valid_rejections,
           count_if(not is_definitive)                           as unresolved_attempts
    from in_scope
    where is_during_incident
    group by incident_id
),

comparison as (
    select s.incident_id,
           count(distinct s.started_date_local)                  as comparison_days,
           count(*)                                              as attempts,
           count_if(s.failure_category = 'TECHNICAL_FAILURE')    as technical_failures,
           count_if(not s.is_definitive)                         as unresolved_attempts
    from in_scope s
    left anti join attempts_during_any_incident x on x.attempt_id = s.attempt_id
    where s.is_in_comparison_window
    group by s.incident_id
),

-- attempts whose latest event carries this incident_id (context only, not proof of cause)
linked as (
    select latest_incident_id as incident_id,
           count(*)           as attempts_linked_by_event
    from {{ ref('fct_payment_attempts') }}
    where latest_incident_id is not null
    group by latest_incident_id
),

metrics as (
    select i.incident_id,
           i.incident_type,
           i.affected_city,
           i.affected_channel,
           i.started_at_local,
           i.ended_at_local,
           i.incident_date_local,
           i.incident_weekday_local,
           i.duration_minutes,
           coalesce(d.attempts, 0)                                  as incident_attempts,
           coalesce(d.technical_failures, 0)                        as incident_technical_failures,
           coalesce(d.service_unavailable_failures, 0)              as incident_service_unavailable_failures,
           coalesce(d.processing_error_failures, 0)                 as incident_processing_error_failures,
           coalesce(d.processing_expired_failures, 0)               as incident_processing_expired_failures,
           coalesce(d.unknown_reason_failures, 0)                   as incident_unknown_reason_failures,
           coalesce(d.valid_rejections, 0)                          as incident_valid_rejections,
           coalesce(d.unresolved_attempts, 0)                       as incident_unresolved_attempts,
           d.technical_failures  / nullif(d.attempts, 0)            as incident_technical_failure_rate,
           d.unresolved_attempts / nullif(d.attempts, 0)            as incident_unresolved_rate,
           coalesce(c.comparison_days, 0)                           as comparison_days,
           coalesce(c.attempts, 0)                                  as comparison_attempts,
           c.attempts / nullif(c.comparison_days, 0)                as comparison_attempts_per_day,
           coalesce(c.technical_failures, 0)                        as comparison_technical_failures,
           coalesce(c.unresolved_attempts, 0)                       as comparison_unresolved_attempts,
           c.technical_failures  / nullif(c.attempts, 0)            as comparison_technical_failure_rate,
           c.unresolved_attempts / nullif(c.attempts, 0)            as comparison_unresolved_rate,
           coalesce(l.attempts_linked_by_event, 0)                  as attempts_linked_by_event
    from incidents i
    left join during d     on d.incident_id = i.incident_id
    left join comparison c on c.incident_id = i.incident_id
    left join linked l     on l.incident_id = i.incident_id
)

select incident_id,
       incident_type,
       affected_city,
       affected_channel,
       started_at_local,
       ended_at_local,
       incident_date_local,
       incident_weekday_local,
       duration_minutes,
       incident_attempts,
       incident_technical_failures,
       incident_service_unavailable_failures,
       incident_processing_error_failures,
       incident_processing_expired_failures,
       incident_unknown_reason_failures,
       incident_valid_rejections,
       incident_unresolved_attempts,
       round(incident_technical_failure_rate, 4)                                   as incident_technical_failure_rate,
       round(incident_unresolved_rate, 4)                                          as incident_unresolved_rate,
       comparison_days,
       comparison_attempts,
       round(comparison_attempts_per_day, 1)                                       as comparison_attempts_per_day,
       comparison_technical_failures,
       comparison_unresolved_attempts,
       round(comparison_technical_failure_rate, 4)                                 as comparison_technical_failure_rate,
       round(comparison_unresolved_rate, 4)                                        as comparison_unresolved_rate,
       round(incident_technical_failure_rate - comparison_technical_failure_rate, 4) as technical_failure_rate_difference,
       round(incident_unresolved_rate - comparison_unresolved_rate, 4)             as unresolved_rate_difference,
       attempts_linked_by_event,
       incident_attempts < {{ var('min_sample_attempts') }}                        as is_small_sample,
       current_timestamp()                                                         as gold_processed_at_utc
from metrics
