-- Q7: every attempt without a definitive supported outcome at the cutoff, ranked for investigation.
-- Ranking uses stated sort criteria, not a weighted score. Age bands are proposed triage bands, not an SLA.
with wallets as (
    select wallet_id, closing_held_balance_cents
    from {{ ref('fct_wallet_balances') }}
),

queue as (
    select a.attempt_id,
           a.payment_id,
           a.attempt_number,
           a.sender_customer_id,
           a.sender_wallet_id,
           a.recipient_wallet_id,
           a.requested_amount_cents,
           a.channel,
           a.origin_city,
           a.final_outcome                           as supported_outcome,
           a.outcome_source                          as evidence_status,
           a.latest_status                           as latest_observed_status,
           a.latest_reason_code                      as last_system_reason,
           a.latest_system_component,
           a.latest_incident_id,
           a.started_at_utc                          as attempt_started_at_utc,
           a.started_at_local                        as attempt_started_at_local,
           a.age_at_cutoff_hours,
           a.event_count,
           a.ledger_entry_count,
           a.has_balanced_ledger,
           coalesce(w.closing_held_balance_cents, 0) as sender_wallet_held_balance_cents,
           a.is_payment_in_observation_window
    from {{ ref('fct_payment_attempts') }} a
    left join wallets w on w.wallet_id = a.sender_wallet_id
    where not a.is_definitive
)

select *,
       case
           when age_at_cutoff_hours < 24      then '1: under 1 day'
           when age_at_cutoff_hours < 24 * 7  then '2: 1-7 days'
           when age_at_cutoff_hours < 24 * 30 then '3: 7-30 days'
           else                                    '4: 30+ days'
       end                                                         as proposed_age_band,
       case
           when supported_outcome = 'CONFLICT'
               then 'Events and/or ledger contradict each other: confirm the true attempt state in the payment system'
           when supported_outcome = 'PENDING' and sender_wallet_held_balance_cents > 0
               then 'System reported pending and the sender wallet holds funds: confirm the final status with the payment system and ask Wallet Reconciliation to review the hold'
           when supported_outcome = 'PENDING'
               then 'System reported pending but no hold is visible on the sender wallet: confirm the final status and the reservation'
           when evidence_status = 'REQUESTED_ONLY'
               then 'Final event missing from the analytics feed and no ledger posting: request the attempt status from payment-system logs'
           else 'No analytics events received for this attempt: check feed completeness, then request the status from payment-system logs'
       end                                                         as next_evidence_check,
       case
           when supported_outcome = 'PENDING' then 'Payment Operations'
           else                                    'Payment Engineering'
       end                                                         as proposed_owner,
       row_number() over (
           order by case when supported_outcome = 'CONFLICT' then 0 else 1 end,
                    case when sender_wallet_held_balance_cents > 0 then 0 else 1 end,
                    age_at_cutoff_hours desc,
                    requested_amount_cents desc,
                    attempt_id
       )                                                           as priority_rank,
       'Conflicting evidence first, then funds held on the sender wallet, then oldest at cutoff, then largest requested amount'
                                                                   as priority_basis,
       current_timestamp()                                         as gold_processed_at_utc
from queue
