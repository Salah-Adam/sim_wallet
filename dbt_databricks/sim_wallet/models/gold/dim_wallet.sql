-- One row per wallet, with the owning customer folded in (wallets and customers are 1:1).
select w.wallet_id,
       w.customer_id,
       c.full_name                 as customer_name,
       c.home_city                 as customer_home_city,
       c.registered_at_utc         as customer_registered_at_utc,
       w.status                    as wallet_status,
       w.status = 'ACTIVE'         as is_active,
       w.currency,
       w.opening_balance_cents,
       w.snapshot_at_utc           as opening_snapshot_at_utc,
       current_timestamp()         as gold_processed_at_utc
from {{ ref('wallet_opening') }} w
left join {{ ref('customers') }} c on c.customer_id = w.customer_id
