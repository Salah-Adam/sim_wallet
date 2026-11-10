-- Q9 (detail): one row per reconciliation problem. An empty table means every check passed.
-- Discrepancies are listed as they are; nothing is forced to agree.
with attempt_ledger as (
    select attempt_id,
           count(*)                                                                  as entry_count,
           sum(signed_amount_cents)                                                  as net_cents,
           count_if(entry_type = 'TRANSFER_OUT')                                     as debit_count,
           count_if(entry_type = 'TRANSFER_IN')                                      as credit_count,
           max(case when entry_type = 'TRANSFER_OUT' then wallet_id end)             as debit_wallet_id,
           max(case when entry_type = 'TRANSFER_IN'  then wallet_id end)             as credit_wallet_id,
           sum(case when entry_type = 'TRANSFER_IN'  then signed_amount_cents else 0 end) as credit_cents
    from {{ ref('ledger_entries') }}
    group by attempt_id
),

attempts as (
    select a.attempt_id, a.payment_id, a.final_outcome,
           a.sender_wallet_id, a.recipient_wallet_id, a.requested_amount_cents,
           coalesce(l.entry_count, 0)  as entry_count,
           coalesce(l.net_cents, 0)    as net_cents,
           coalesce(l.debit_count, 0)  as debit_count,
           coalesce(l.credit_count, 0) as credit_count,
           l.debit_wallet_id,
           l.credit_wallet_id,
           coalesce(l.credit_cents, 0) as credit_cents
    from {{ ref('fct_payment_attempts') }} a
    left join attempt_ledger l on l.attempt_id = a.attempt_id
),

success_posting_mismatch as (
    select 'SUCCESS_POSTING_MISMATCH'        as exception_type,
           'ATTEMPT'                         as entity_type,
           attempt_id                        as entity_id,
           payment_id,
           sender_wallet_id                  as wallet_id,
           requested_amount_cents            as expected_cents,
           credit_cents                      as actual_cents,
           concat_ws('; ',
               case when entry_count <> 2 then concat('expected 2 postings, found ', cast(entry_count as string)) end,
               case when net_cents <> 0 then concat('postings net to ', cast(net_cents as string), ' instead of 0') end,
               case when debit_count <> 1 or credit_count <> 1 then 'expected one TRANSFER_OUT and one TRANSFER_IN' end,
               case when not (debit_wallet_id <=> sender_wallet_id) then 'debit is not on the sender wallet' end,
               case when not (credit_wallet_id <=> recipient_wallet_id) then 'credit is not on the recipient wallet' end,
               case when credit_cents <> requested_amount_cents then 'credited amount differs from the requested amount' end
           )                                 as detail,
           'Wallet Reconciliation'           as proposed_owner
    from attempts
    where final_outcome = 'SUCCEEDED'
      and not (entry_count = 2
               and net_cents = 0
               and debit_count = 1
               and credit_count = 1
               and debit_wallet_id <=> sender_wallet_id
               and credit_wallet_id <=> recipient_wallet_id
               and credit_cents = requested_amount_cents)
),

posting_on_non_success as (
    select 'POSTING_ON_NON_SUCCESS'          as exception_type,
           'ATTEMPT'                         as entity_type,
           attempt_id                        as entity_id,
           payment_id,
           sender_wallet_id                  as wallet_id,
           cast(0 as bigint)                 as expected_cents,
           credit_cents                      as actual_cents,
           concat('attempt outcome is ', final_outcome, ' but ', cast(entry_count as string), ' ledger postings exist') as detail,
           'Payment Engineering'             as proposed_owner
    from attempts
    where final_outcome <> 'SUCCEEDED'
      and entry_count > 0
),

ledger_without_attempt as (
    select 'LEDGER_WITHOUT_ATTEMPT'          as exception_type,
           'LEDGER_ENTRY'                    as entity_type,
           le.entry_id                       as entity_id,
           le.payment_id,
           le.wallet_id,
           cast(0 as bigint)                 as expected_cents,
           le.signed_amount_cents            as actual_cents,
           'ledger entry references an attempt that does not exist' as detail,
           'Wallet Reconciliation'           as proposed_owner
    from {{ ref('ledger_entries') }} le
    left anti join {{ ref('payment_attempts') }} pa on pa.attempt_id = le.attempt_id
),

wallet_ledger_mismatch as (
    select 'WALLET_LEDGER_MISMATCH'          as exception_type,
           'WALLET'                          as entity_type,
           wallet_id                         as entity_id,
           cast(null as string)              as payment_id,
           wallet_id,
           expected_closing_ledger_cents     as expected_cents,
           closing_ledger_balance_cents      as actual_cents,
           'opening balance + ledger movements does not equal the closing ledger balance' as detail,
           'Wallet Reconciliation'           as proposed_owner
    from {{ ref('fct_wallet_balances') }}
    where not is_ledger_reconciled
),

wallet_balance_split_mismatch as (
    select 'WALLET_BALANCE_SPLIT_MISMATCH'   as exception_type,
           'WALLET'                          as entity_type,
           wallet_id                         as entity_id,
           cast(null as string)              as payment_id,
           wallet_id,
           closing_held_balance_cents + closing_available_balance_cents as expected_cents,
           closing_ledger_balance_cents      as actual_cents,
           'closing ledger balance does not equal held + available balance' as detail,
           'Wallet Reconciliation'           as proposed_owner
    from {{ ref('fct_wallet_balances') }}
    where not is_balance_split_reconciled
),

all_exceptions as (
    select * from success_posting_mismatch
    union all select * from posting_on_non_success
    union all select * from ledger_without_attempt
    union all select * from wallet_ledger_mismatch
    union all select * from wallet_balance_split_mismatch
)

select concat(exception_type, ':', entity_id)    as exception_id,
       *,
       actual_cents - expected_cents             as difference_cents,
       current_timestamp()                       as gold_processed_at_utc
from all_exceptions
