with payments as (
    select payment_id,
           sender_wallet_id,
           sender_customer_id,
           recipient_wallet_id,
           amount_cents                 as requested_amount_cents,
           channel,
           origin_city,
           final_outcome                as payment_final_outcome,
           is_in_observation_window     as is_payment_in_observation_window
    from {{ ref('fct_payments') }}
),

window_bounds as (
    select observation_start_utc, observation_cutoff_utc
    from {{ ref('dataset_metadata') }}
),

attempts as (
    select *,
           from_utc_timestamp(started_at_utc, 'Africa/Mogadishu') as started_at_local
    from {{ ref('int_attempt_outcomes') }}
)

select a.attempt_id,
       a.payment_id,
       a.attempt_number,
       a.attempt_number = 1                                   as is_first_attempt,
       not a.has_later_attempt                                as is_latest_attempt,

       -- time
       a.started_at_utc,
       a.started_at_local,
       to_date(a.started_at_local)                            as started_date_local,
       hour(a.started_at_local)                               as started_hour_local,
       date_format(a.started_at_local, 'EEEE')                as started_weekday_local,

       -- payment context
       p.sender_wallet_id,
       p.sender_customer_id,
       p.recipient_wallet_id,
       p.requested_amount_cents,
       p.channel,
       p.origin_city,
       p.payment_final_outcome,

       -- outcome
       a.final_outcome,
       a.outcome_source,
       a.is_definitive,
       a.final_outcome = 'FAILED'                             as is_confirmed_failure,
       case when a.final_outcome = 'FAILED'
            then coalesce(a.failure_reason_code, 'UNKNOWN')
       end                                                    as failure_reason_code,

       -- evidence (for Q7 and Q10)
       a.event_count,
       a.latest_status,
       a.latest_event_at_utc,
       a.latest_reason_code,
       a.latest_system_component,
       a.latest_incident_id,
       a.ledger_entry_count,
       a.ledger_net_cents,
       a.has_balanced_ledger,
       a.age_at_cutoff_seconds,
       round(a.age_at_cutoff_seconds / 3600.0, 1)             as age_at_cutoff_hours,

       -- cohorts
       p.is_payment_in_observation_window,
       a.started_at_utc >= w.observation_start_utc
         and a.started_at_utc < w.observation_cutoff_utc      as is_started_in_observation_window,

       current_timestamp()                                    as gold_processed_at_utc
from attempts a
cross join window_bounds w
left join payments p on p.payment_id = a.payment_id