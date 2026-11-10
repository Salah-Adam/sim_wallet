-- One row per recorded service incident. 'ALL' in affected_city / affected_channel means every city / channel.
with incidents as (
    select *,
           from_utc_timestamp(started_at_utc, 'Africa/Mogadishu') as started_at_local,
           from_utc_timestamp(ended_at_utc,   'Africa/Mogadishu') as ended_at_local
    from {{ ref('system_incidents') }}
)

select incident_id,
       incident_type,
       affected_city,
       affected_channel,
       affected_city = 'ALL'                                                      as affects_all_cities,
       affected_channel = 'ALL'                                                   as affects_all_channels,
       started_at_utc,
       ended_at_utc,
       started_at_local,
       ended_at_local,
       to_date(started_at_local)                                                  as incident_date_local,
       date_format(started_at_local, 'EEEE')                                      as incident_weekday_local,
       cast((unix_timestamp(ended_at_utc) - unix_timestamp(started_at_utc)) / 60 as int) as duration_minutes,
       recorded_by,
       current_timestamp()                                                        as gold_processed_at_utc
from incidents
