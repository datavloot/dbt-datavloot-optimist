{#
    Time dimension — one row per minute of the day (1 440 rows total).
#}

{%- set dim_source -%}
source_cte: time_spine
{%- endset -%}

with time_spine as (

    select

        gs                                                              as minute_of_day,
        make_time(gs // 60, gs % 60, 0)                                 as time_of_day,
        lpad(cast(gs // 60 as varchar), 2, '0')
            || ':' || lpad(cast(gs % 60 as varchar), 2, '0')           as time_hhmm,

        gs // 60                                                        as hour,
        gs % 60                                                         as minute,

        case
            when gs // 60 between  0 and  5 then 'night'
            when gs // 60 between  6 and 11 then 'morning'
            when gs // 60 between 12 and 16 then 'afternoon'
            when gs // 60 between 17 and 20 then 'evening'
            else                                 'night'
        end                                                             as period_of_day,

        gs // 60 between 9 and 17                                       as is_business_hours

    from generate_series(0, 1439) t(gs)

)

{{ optimist.build_dimension(fromyaml(dim_source)) }}
