{% test row_count_matches_bronze(model, bronze, allow_fewer=false, distinct_key=none) %}
with b as (
    select
        {% if distinct_key %}
        count(distinct get_json_object(record_json, '$.data.{{ distinct_key }}')) as n
        {% else %}
        count(*) as n
        {% endif %}
    from {{ bronze }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
),
s as (select count(*) as n from {{ model }})
select b.n as bronze_rows, s.n as silver_rows
from b cross join s
where {% if allow_fewer %} s.n > b.n {% else %} s.n <> b.n {% endif %}
{% endtest %}