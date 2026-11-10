-- Q3: one row per origin city x channel for payments requested in the observation window.
-- Rates are stored next to their numerators and denominators; never average these rates across rows.
with payments as (
    select p.payment_id,
           p.origin_city,
           p.channel,
           p.sender_customer_id,
           p.amount_cents,
           p.final_outcome,
           fa.available_balance_cents_at_start as first_attempt_available_balance_cents
    from {{ ref('fct_payments') }} p
    left join {{ ref('payment_attempts') }} fa
           on fa.payment_id = p.payment_id
          and fa.attempt_number = 1
    where p.is_in_observation_window
),

payment_metrics as (
    select origin_city,
           channel,
           count(*)                                                                as payments,
           count_if(final_outcome = 'SUCCEEDED')                                   as successful_payments,
           count_if(final_outcome = 'FAILED')                                      as failed_payments,
           count_if(final_outcome not in ('SUCCEEDED', 'FAILED'))                  as unresolved_payments,
           count(distinct sender_customer_id)                                      as senders,
           sum(amount_cents)                                                       as requested_amount_cents,
           percentile_approx(amount_cents, 0.5)                                    as median_amount_cents,
           percentile_approx(first_attempt_available_balance_cents, 0.5)           as median_available_balance_cents
    from payments
    group by origin_city, channel
),

attempt_metrics as (
    select a.origin_city,
           a.channel,
           count(*)                                                                as attempts,
           count_if(a.is_confirmed_failure)                                        as failed_attempts,
           count_if(r.failure_category = 'TECHNICAL_FAILURE')                      as technical_failed_attempts,
           count_if(r.failure_category = 'VALID_REJECTION')                        as valid_rejection_attempts,
           count_if(r.failure_category = 'UNKNOWN_REASON')                         as unknown_reason_failed_attempts,
           count(distinct case when a.is_confirmed_failure then a.sender_customer_id end) as affected_senders
    from {{ ref('fct_payment_attempts') }} a
    left join {{ ref('dim_reason') }} r on r.reason_code = a.failure_reason_code
    where a.is_payment_in_observation_window
    group by a.origin_city, a.channel
)

select p.origin_city,
       p.channel,
       p.payments,
       p.successful_payments,
       p.failed_payments,
       p.unresolved_payments,
       round(p.failed_payments     / p.payments, 4)           as payment_failure_rate,
       round(p.unresolved_payments / p.payments, 4)           as payment_unresolved_rate,
       a.attempts,
       a.failed_attempts,
       a.technical_failed_attempts,
       a.valid_rejection_attempts,
       a.unknown_reason_failed_attempts,
       round(a.failed_attempts           / a.attempts, 4)     as attempt_failure_rate,
       round(a.technical_failed_attempts / a.attempts, 4)     as technical_failure_rate,
       p.senders,
       a.affected_senders,
       round(a.affected_senders / p.senders, 4)               as affected_sender_share,
       p.requested_amount_cents,
       p.median_amount_cents,
       p.median_available_balance_cents,
       p.payments < {{ var('small_group_min_payments') }}     as is_small_group,
       current_timestamp()                                    as gold_processed_at_utc
from payment_metrics p
left join attempt_metrics a
       on a.origin_city = p.origin_city
      and a.channel     = p.channel
