{#
    Date dimension — one row per calendar day. Ships as a macro, not a model, so every
    project owns its own dim_date.sql and can configure the date range without forking
    the package. Call it from your own model file:

        -- models/business/dimensions/dim_date.sql
        {{ optimist.build_dim_date() }}

    date_key IS the surrogate key — a plain YYYYMMDD integer, not a hash. It's produced
    by generate_date_key() (see that macro's docstring), so any fact computing its own
    date key the same way is guaranteed to match this dimension's key for the same date.

    Date range is configurable via arguments or dbt vars (an argument wins if given):

        {{ optimist.build_dim_date(start_date='2018-01-01', end_date='2040-12-31') }}

        # dbt_project.yml
        vars:
          dim_date_start: '2018-01-01'
          dim_date_end:   '2040-12-31'

    Falls back to 2015-01-01 -> 2035-12-31 if neither an argument nor a var is set.

    Arguments:
        start_date (string, optional) — first date in the range (YYYY-MM-DD)
        end_date   (string, optional) — last date in the range (YYYY-MM-DD)
#}

{%- macro build_dim_date(start_date=none, end_date=none) -%}

    {%- set start_date = start_date or var('dim_date_start', '2015-01-01') -%}
    {%- set end_date   = end_date   or var('dim_date_end',   '2035-12-31') -%}

with date_spine as (

    select

        {{ optimist.generate_date_key('gs') }}                          as date_key,
        cast(gs as date)                                                as date_day,

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

),

final as (

    select
        *,
        current_timestamp as _loaded_at
    from date_spine

)

select * from final

{%- endmacro -%}
