-- Q10: data-engineering metrics for the event feed (one row per metric).
-- configured_rate comes from the generator settings; settings are probabilities, not exact expected counts.
with meta as (
    select observation_cutoff_utc, duplicate_rate, late_rate, drop_rate
    from {{ ref('dataset_metadata') }}
),

deliveries as (
    select count(*) as delivery_rows
    from {{ ref('event_deliveries') }}
),

event_stats as (
    select count(*)                                                   as distinct_events,
           count_if(e.delivery_count > 1)                             as events_with_duplicates,
           sum(e.delivery_count - 1)                                  as duplicate_deliveries,
           count_if(e.is_late)                                        as late_events,
           max(e.latency_seconds)                                     as max_latency_seconds,
           count_if(e.first_ingested_at_utc >= m.observation_cutoff_utc) as events_after_cutoff
    from {{ ref('events') }} e
    cross join meta m
),

-- per attempt: did events arrive in a different order from when they happened?
attempt_events as (
    select attempt_id,
           max_by(event_id, first_ingested_at_utc) as last_arrived_event_id,
           max_by(event_id, event_at_utc)          as latest_business_event_id,
           count_if(status = 'REQUESTED')          as requested_events
    from {{ ref('events') }}
    group by attempt_id
),

arrival_stats as (
    select count(*)                                                     as attempts_with_events,
           count_if(last_arrived_event_id <> latest_business_event_id) as attempts_with_out_of_order_arrival,
           count_if(requested_events = 0)                               as attempts_missing_requested_event
    from attempt_events
),

attempt_totals as (
    select count(*) as attempts
    from {{ ref('fct_payment_attempts') }}
),

outcome_sources as (
    select outcome_source, count(*) as attempts
    from {{ ref('fct_payment_attempts') }}
    group by outcome_source
),

metrics as (
    select 1 as metric_order, 'DUPLICATES' as metric_group, 'delivery_rows' as metric_name,
           cast(d.delivery_rows as double) as metric_value, cast(null as bigint) as denominator,
           cast(null as double) as configured_rate,
           'Physical event copies received in the analytics feed' as note
    from deliveries d

    union all
    select 2, 'DUPLICATES', 'distinct_events', cast(s.distinct_events as double), null, null,
           'Unique events after deduplication on event_id (silver.events)'
    from event_stats s

    union all
    select 3, 'DUPLICATES', 'duplicate_deliveries', cast(s.duplicate_deliveries as double), s.distinct_events, m.duplicate_rate,
           'Extra copies beyond the first delivery of each event; removed before counting outcomes'
    from event_stats s cross join meta m

    union all
    select 4, 'DUPLICATES', 'events_with_duplicates', cast(s.events_with_duplicates as double), s.distinct_events, m.duplicate_rate,
           'Events that arrived more than once'
    from event_stats s cross join meta m

    union all
    select 5, 'LATENESS', 'late_events', cast(s.late_events as double), s.distinct_events, m.late_rate,
           concat('First copy arrived more than ', '{{ var("late_threshold_seconds") }}', ' seconds after the event happened')
    from event_stats s cross join meta m

    union all
    select 6, 'LATENESS', 'max_latency_hours', round(s.max_latency_seconds / 3600.0, 2), null, null,
           'Longest delay between an event happening and its first arrival'
    from event_stats s

    union all
    select 7, 'LATENESS', 'events_received_after_cutoff', cast(s.events_after_cutoff as double), s.distinct_events, null,
           'Not known to analytics at the cutoff; excluded from outcomes'
    from event_stats s

    union all
    select 8, 'LATENESS', 'attempts_with_out_of_order_arrival', cast(a.attempts_with_out_of_order_arrival as double), a.attempts_with_events, null,
           'Last event to arrive was not the latest by event time; outcomes use event time, so the late event did not overwrite the later state'
    from arrival_stats a

    union all
    select 9, 'COMPLETENESS', 'attempts_missing_requested_event', cast(a.attempts_missing_requested_event as double), a.attempts_with_events, m.drop_rate,
           'Attempts that have events but no REQUESTED event'
    from arrival_stats a cross join meta m

    union all
    select 10, 'COMPLETENESS', concat('attempts_outcome_source_', lower(o.outcome_source)), cast(o.attempts as double), t.attempts, null,
           case o.outcome_source
               when 'EVENT'                then 'Outcome confirmed by a SUCCEEDED or FAILED event'
               when 'LEDGER'               then 'Success event missing; success recovered from balanced ledger postings'
               when 'RETRY'                then 'Failure event missing; failure inferred from a later retry'
               when 'PENDING_EVENT'        then 'System reported pending; no final result at the cutoff'
               when 'REQUESTED_ONLY'       then 'Only REQUESTED seen; final evidence missing'
               when 'NO_EVENTS'            then 'No analytics events at all for this attempt'
               when 'CONFLICTING_EVIDENCE' then 'Events and/or ledger contradict each other'
           end
    from outcome_sources o cross join attempt_totals t
)

select metric_order,
       metric_group,
       metric_name,
       metric_value,
       denominator,
       round(metric_value / denominator, 5) as rate,
       configured_rate,
       note,
       current_timestamp()                  as gold_processed_at_utc
from metrics
