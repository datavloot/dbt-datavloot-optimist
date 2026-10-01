{#
    Time-of-day dimension — configurable granularity. Ships as a macro, not a model, so
    every project owns its own dim_time.sql and can pick the grain without forking the
    package. Call it from your own model file:

        -- models/business/dimensions/dim_time.sql
        {{ optimist.build_dim_time() }}

    time_key IS the surrogate key — seconds elapsed since midnight as a plain integer,
    not a hash. It's stable across grain (minute grain: multiples of 60; second grain:
    every value 0-86399), so it stays comparable/sortable regardless of which grain a
    project picks.

    Grain resolves as: argument, else the `dim_time_grain` var, else 'minute':

        {{ optimist.build_dim_time(grain='second') }}     -- 86 400 rows, one per second

        # dbt_project.yml
        vars:
          dim_time_grain: 'second'

    The column set is identical at either grain (`second` is always 0 at minute grain),
    so downstream models see a stable shape whichever grain a project picks.

    Arguments:
        grain (string, optional) — 'minute' (default) or 'second'
#}

{%- macro build_dim_time(grain=none) -%}

    {%- set grain = grain or var('dim_time_grain', 'minute') -%}

    {%- if grain == 'second' -%}
        {%- set _max_gs = 86399 -%}
        {%- set _hour_expr     = 'gs // 3600' -%}
        {%- set _minute_expr   = '(gs % 3600) // 60' -%}
        {%- set _second_expr   = 'gs % 60' -%}
        {%- set _time_key_expr = 'gs' -%}
    {%- elif grain == 'minute' -%}
        {%- set _max_gs = 1439 -%}
        {%- set _hour_expr     = 'gs // 60' -%}
        {%- set _minute_expr   = 'gs % 60' -%}
        {%- set _second_expr   = '0' -%}
        {%- set _time_key_expr = 'gs * 60' -%}
    {%- else -%}
        {{ exceptions.raise_compiler_error(
            "build_dim_time: grain must be 'minute' or 'second', got: " ~ grain
        ) }}
    {%- endif -%}

with time_spine as (

    select

        cast({{ _time_key_expr }} as integer)                           as time_key,
        make_time(
            cast({{ _hour_expr }} as integer),
            cast({{ _minute_expr }} as integer),
            cast({{ _second_expr }} as integer)
        )                                                                as time_of_day,

        cast({{ _hour_expr }} as integer)                                as hour,
        cast({{ _minute_expr }} as integer)                              as minute,
        cast({{ _second_expr }} as integer)                              as second,

        lpad(cast({{ _hour_expr }} as varchar), 2, '0') || ':' ||
        lpad(cast({{ _minute_expr }} as varchar), 2, '0') || ':' ||
        lpad(cast({{ _second_expr }} as varchar), 2, '0')                as time_hhmmss,

        case
            when ({{ _hour_expr }}) between  0 and  5 then 'night'
            when ({{ _hour_expr }}) between  6 and 11 then 'morning'
            when ({{ _hour_expr }}) between 12 and 16 then 'afternoon'
            when ({{ _hour_expr }}) between 17 and 20 then 'evening'
            else                                           'night'
        end                                                              as period_of_day,

        ({{ _hour_expr }}) between 9 and 17                              as is_business_hours

    from generate_series(0, {{ _max_gs }}) t(gs)

),

final as (

    select
        *,
        current_timestamp as _loaded_at
    from time_spine

)

select * from final

{%- endmacro -%}
