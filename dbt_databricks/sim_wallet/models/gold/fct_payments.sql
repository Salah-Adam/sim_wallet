with window_bounds as (
    select observation_start_utc, observation_cutoff_utc
    from {{ ref('dataset_metadata') }}
),

attempt_rollup as (
    select payment_id,
           count(*)                                                    as attempt_count,
           max(case when final_outcome = 'SUCCEEDED' then 1 else 0 end) = 1 as has_succeeded_attempt,
           -- first attempt (attempt_number = smallest)
           min_by(final_outcome,       attempt_number)                 as first_attempt_outcome,
           min_by(failure_reason_code, attempt_number)                 as first_failure_reason_code,
           -- latest attempt (attempt_number = largest)
           max_by(attempt_id,          attempt_number)                 as latest_attempt_id,
           max_by(final_outcome,       attempt_number)                 as latest_attempt_outcome,
           max_by(outcome_source,      attempt_number)                 as latest_outcome_source,
           max_by(started_at_utc,      attempt_number)                 as latest_attempt_started_at_utc
    from {{ ref('int_attempt_outcomes') }}
    group by payment_id
),

payments as (
    select p.payment_id,
           p.sender_wallet_id,
           sw.customer_id                                              as sender_customer_id,
           p.recipient_wallet_id,
           p.amount_cents,
           p.currency,
           p.channel,
           p.origin_city,
           p.payment_type,
           p.requested_at_utc,
           from_utc_timestamp(p.requested_at_utc, 'Africa/Mogadishu')  as requested_at_local,
           to_date(from_utc_timestamp(p.requested_at_utc, 'Africa/Mogadishu')) as requested_date_local
    from {{ ref('payment_requests') }} p
    left join {{ ref('wallet_opening') }} sw on sw.wallet_id = p.sender_wallet_id
)

select p.*,
       coalesce(r.attempt_count, 0)                                     as attempt_count,
       r.first_attempt_outcome,
       case when r.first_attempt_outcome = 'FAILED'
            then coalesce(r.first_failure_reason_code, 'UNKNOWN')
       end                                                              as first_failure_reason_code,
       r.latest_attempt_id,
       r.latest_attempt_started_at_utc,
       case
           when r.payment_id is null   then 'NO_ATTEMPT'
           when r.has_succeeded_attempt then 'SUCCEEDED'
           else r.latest_attempt_outcome
       end                                                              as final_outcome,
       r.latest_outcome_source                                          as final_outcome_source,
       coalesce(r.has_succeeded_attempt, false)                         as is_successful,
       r.first_attempt_outcome = 'FAILED'                               as is_first_attempt_failed,
       r.first_attempt_outcome = 'FAILED' and r.has_succeeded_attempt   as is_recovered,
       case when r.has_succeeded_attempt then p.amount_cents else 0 end as successful_amount_cents,
       p.requested_at_utc >= w.observation_start_utc
         and p.requested_at_utc < w.observation_cutoff_utc              as is_in_observation_window,
       w.observation_cutoff_utc,
       round((unix_timestamp(w.observation_cutoff_utc) - unix_timestamp(p.requested_at_utc)) / 3600.0, 1)
                                                                        as follow_up_hours_at_cutoff,
       current_timestamp()                                              as gold_processed_at_utc
from payments p
cross join window_bounds w
left join attempt_rollup r on r.payment_id = p.payment_id