-- One row per local business date (Africa/Mogadishu) in the observation window.
with bounds as (
    select to_date(from_utc_timestamp(observation_start_utc, 'Africa/Mogadishu'))              as first_date,
           date_sub(to_date(from_utc_timestamp(observation_cutoff_utc, 'Africa/Mogadishu')), 1) as last_date
    from {{ ref('dataset_metadata') }}
),

dates as (
    select explode(sequence(first_date, last_date, interval 1 day)) as date_local
    from bounds
)

select d.date_local,
       year(d.date_local)                       as year,
       month(d.date_local)                      as month_number,
       date_format(d.date_local, 'MMMM')        as month_name,
       date_format(d.date_local, 'yyyy-MM')     as year_month,
       weekofyear(d.date_local)                 as iso_week_number,
       dayofweek(d.date_local)                  as day_of_week_number,   -- 1 = Sunday ... 7 = Saturday
       date_format(d.date_local, 'EEEE')        as weekday_name,
       datediff(d.date_local, b.first_date) + 1 as observation_day_number,
       current_timestamp()                      as gold_processed_at_utc
from dates d
cross join bounds b
