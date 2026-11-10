-- Every extra attempt follows a confirmed failure, so:
-- failed attempts - failed payments must equal attempts - payments (the number of retries).
-- Returns a row (test fails) when the two fact tables stop reconciling.
with a as (
    select count_if(final_outcome = 'FAILED') as failed_attempts,
           count(*)                           as attempts
    from {{ ref('fct_payment_attempts') }}
),

p as (
    select count_if(final_outcome = 'FAILED') as failed_payments,
           count(*)                           as payments
    from {{ ref('fct_payments') }}
)

select *
from a
cross join p
where failed_attempts - failed_payments <> attempts - payments
