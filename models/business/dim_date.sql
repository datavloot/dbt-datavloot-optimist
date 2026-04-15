{#
    Date dimension — one row per calendar day.
    Config lives in _dim_configs.yml under this model's meta block.

    Date range is configurable via dbt variables (defaults: 2015-01-01 → 2035-12-31):
        dbt run --vars '{"dim_date_start": "2018-01-01", "dim_date_end": "2040-12-31"}'
#}

{%- set start_date = var('dim_date_start', '2015-01-01') -%}
{%- set end_date   = var('dim_date_end',   '2035-12-31') -%}

with date_spine as (

    select

        cast(gs as date)                                                as date_day,
        cast(strftime(cast(gs as date), '%Y%m%d') as integer)           as date_key,

        year(cast(gs as date))                                          as year,
        quarter(cast(gs as date))                                       as quarter,
        month(cast(gs as date))                                         as month_num,
        monthname(cast(gs as date))                                     as month_name,
        date_trunc('quarter', cast(gs as date))::date                   as quarter_start_date,
        date_trunc('month', cast(gs as date))::date                     as month_start_date,

        week(cast(gs as date))                                          as week_of_year,
        date_trunc('week', cast(gs as date))::date                      as week_start_date,

        dayofyear(cast(gs as date))                                     as day_of_year,
        day(cast(gs as date))                                           as day_of_month,
        dayofweek(cast(gs as date))                                     as day_of_week,
        dayname(cast(gs as date))                                       as day_name,

        dayofweek(cast(gs as date)) in (0, 6)                           as is_weekend,
        dayofweek(cast(gs as date)) not in (0, 6)                       as is_weekday

    from generate_series(
        timestamp '{{ start_date }}',
        timestamp '{{ end_date }}',
        interval '1 day'
    ) t(gs)

)

{{ optimist.build_dimension() }}
