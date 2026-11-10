-- One row per wallet: opening balance, ledger movements, closing snapshot, reconciliation and unresolved attempts.
-- Held balances are recorded per wallet; they are not allocated to individual attempts.
with ledger as (
    select wallet_id,
           count(*)                                                                    as ledger_entry_count,
           sum(signed_amount_cents)                                                    as ledger_movement_cents,
           sum(case when signed_amount_cents < 0 then -signed_amount_cents else 0 end) as sent_cents,
           sum(case when signed_amount_cents > 0 then  signed_amount_cents else 0 end) as received_cents
    from {{ ref('ledger_entries') }}
    group by wallet_id
),

unresolved as (
    select sender_wallet_id                    as wallet_id,
           count(*)                            as unresolved_attempt_count,
           count_if(final_outcome = 'PENDING') as pending_attempt_count,
           count_if(final_outcome = 'UNKNOWN') as unknown_attempt_count,
           sum(requested_amount_cents)         as unresolved_requested_amount_cents
    from {{ ref('fct_payment_attempts') }}
    where not is_definitive
    group by sender_wallet_id
),

joined as (
    select w.wallet_id,
           w.customer_id,
           w.status                                                       as wallet_status,
           w.opening_balance_cents,
           coalesce(l.ledger_entry_count, 0)                              as ledger_entry_count,
           coalesce(l.sent_cents, 0)                                      as sent_cents,
           coalesce(l.received_cents, 0)                                  as received_cents,
           coalesce(l.ledger_movement_cents, 0)                           as ledger_movement_cents,
           w.opening_balance_cents + coalesce(l.ledger_movement_cents, 0) as expected_closing_ledger_cents,
           c.wallet_id is not null                                        as has_closing_snapshot,
           c.ledger_balance_cents                                         as closing_ledger_balance_cents,
           c.held_balance_cents                                           as closing_held_balance_cents,
           c.available_balance_cents                                      as closing_available_balance_cents,
           coalesce(u.unresolved_attempt_count, 0)                        as unresolved_attempt_count,
           coalesce(u.pending_attempt_count, 0)                           as pending_attempt_count,
           coalesce(u.unknown_attempt_count, 0)                           as unknown_attempt_count,
           coalesce(u.unresolved_requested_amount_cents, 0)               as unresolved_requested_amount_cents
    from {{ ref('wallet_opening') }} w
    left join {{ ref('wallet_closing') }} c on c.wallet_id = w.wallet_id
    left join ledger l                       on l.wallet_id = w.wallet_id
    left join unresolved u                   on u.wallet_id = w.wallet_id
)

select *,
       closing_ledger_balance_cents - expected_closing_ledger_cents                                       as ledger_reconciliation_diff_cents,
       closing_ledger_balance_cents - (closing_held_balance_cents + closing_available_balance_cents)      as balance_split_diff_cents,
       coalesce(closing_ledger_balance_cents = expected_closing_ledger_cents, false)                      as is_ledger_reconciled,
       coalesce(closing_ledger_balance_cents = closing_held_balance_cents + closing_available_balance_cents, false) as is_balance_split_reconciled,
       coalesce(closing_held_balance_cents, 0) > 0                                                        as has_held_balance,
       unresolved_attempt_count > 0                                                                       as has_unresolved_attempts,
       current_timestamp()                                                                                as gold_processed_at_utc
from joined
