with reasons as (
    select reason_code, reason_class, system_component, description,
           retry_after_confirmed_failure
    from {{ ref('reason_codes') }}
),

-- a failure we know happened (a retry exists) but whose reason event never arrived
unknown_member as (
    select 'UNKNOWN'                as reason_code,
           'FAILURE'                as reason_class,
           cast(null as string)     as system_component,
           'Confirmed failure inferred from a later retry; the FAILED event with the reason is missing' as description,
           'YES'                    as retry_after_confirmed_failure
),

all_reasons as (
    select * from reasons
    union all
    select * from unknown_member
)

select reason_code,
       reason_class,
       system_component,
       description,
       retry_after_confirmed_failure = 'YES'  as is_retry_eligible,
       reason_class = 'FAILURE'               as counts_as_confirmed_failure,
       case
           when reason_code = 'UNKNOWN'                then 'UNKNOWN_REASON'
           when reason_class = 'UNCERTAINTY'           then 'UNCERTAINTY'
           when retry_after_confirmed_failure = 'YES'  then 'TECHNICAL_FAILURE'
           else                                             'VALID_REJECTION'
       end                                    as failure_category,
       current_timestamp()                    as gold_processed_at_utc
from all_reasons