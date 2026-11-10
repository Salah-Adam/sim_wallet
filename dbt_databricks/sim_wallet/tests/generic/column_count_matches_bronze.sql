{% test column_count_matches_bronze(model, bronze, extra_columns=4) %}
with s as (
    select count(*) - {{ extra_columns }} as n
    from {{ model.database }}.information_schema.columns
    where table_schema = '{{ model.schema }}' and table_name = '{{ model.identifier }}'
),
b as (
    select max(size(json_object_keys(get_json_object(record_json, '$.data')))) as n
    from {{ bronze }}
    where get_json_object(record_json, '$.snapshot_id') = '{{ var("snapshot_id") }}'
)
select s.n as silver_columns, b.n as bronze_keys
from s cross join b
where s.n <> b.n
{% endtest %}