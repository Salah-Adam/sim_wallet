-- Q9 (summary): one row per reconciliation check, so passing checks are visible too.
with exceptions as (
    select exception_type, count(*) as exception_count
    from {{ ref('rpt_reconciliation_exceptions') }}
    group by exception_type
),

attempt_counts as (
    select count_if(final_outcome = 'SUCCEEDED')  as succeeded_attempts,
           count_if(final_outcome <> 'SUCCEEDED') as other_attempts
    from {{ ref('fct_payment_attempts') }}
),

wallet_totals as (
    select count(*)                          as wallets,
           sum(opening_balance_cents)        as opening_cents,
           sum(closing_ledger_balance_cents) as closing_ledger_cents
    from {{ ref('fct_wallet_balances') }}
),

ledger_totals as (
    select count(*)                                                                      as ledger_entries,
           sum(case when entry_type = 'TRANSFER_OUT' then -signed_amount_cents else 0 end) as debit_side_cents
    from {{ ref('ledger_entries') }}
),

payment_totals as (
    select sum(successful_amount_cents) as successful_volume_cents
    from {{ ref('fct_payments') }}
),

checks as (
    select 1 as check_order,
           'Each successful attempt has one balanced debit and credit for the requested amount' as check_name,
           a.succeeded_attempts                     as records_checked,
           coalesce(e.exception_count, 0)           as exception_count,
           cast(null as bigint)                     as expected_cents,
           cast(null as bigint)                     as actual_cents
    from attempt_counts a
    left join exceptions e on e.exception_type = 'SUCCESS_POSTING_MISMATCH'

    union all
    select 2, 'No ledger postings exist for attempts that did not succeed',
           a.other_attempts, coalesce(e.exception_count, 0), null, null
    from attempt_counts a
    left join exceptions e on e.exception_type = 'POSTING_ON_NON_SUCCESS'

    union all
    select 3, 'Every ledger entry belongs to a known attempt',
           l.ledger_entries, coalesce(e.exception_count, 0), null, null
    from ledger_totals l
    left join exceptions e on e.exception_type = 'LEDGER_WITHOUT_ATTEMPT'

    union all
    select 4, 'Opening balance + ledger movements = closing ledger balance (per wallet)',
           w.wallets, coalesce(e.exception_count, 0), null, null
    from wallet_totals w
    left join exceptions e on e.exception_type = 'WALLET_LEDGER_MISMATCH'

    union all
    select 5, 'Closing ledger balance = held + available balance (per wallet)',
           w.wallets, coalesce(e.exception_count, 0), null, null
    from wallet_totals w
    left join exceptions e on e.exception_type = 'WALLET_BALANCE_SPLIT_MISMATCH'

    union all
    select 6, 'Confirmed successful payment volume = debit side of the ledger',
           null,
           case when p.successful_volume_cents = l.debit_side_cents then 0 else 1 end,
           p.successful_volume_cents, l.debit_side_cents
    from payment_totals p
    cross join ledger_totals l

    union all
    select 7, 'Money is conserved: total opening balances = total closing ledger balances',
           w.wallets,
           case when w.opening_cents = w.closing_ledger_cents then 0 else 1 end,
           w.opening_cents, w.closing_ledger_cents
    from wallet_totals w
)

select check_order,
       check_name,
       records_checked,
       exception_count,
       expected_cents,
       actual_cents,
       actual_cents - expected_cents                                as difference_cents,
       case when exception_count = 0 then 'PASS' else 'EXCEPTION' end as status,
       current_timestamp()                                          as gold_processed_at_utc
from checks
