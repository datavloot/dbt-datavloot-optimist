{#
    Generates the same YYYYMMDD integer key dim_date uses, from an arbitrary date or
    timestamp expression. Used internally by build_dim_date(), and available standalone
    for fact models that need a matching date key of their own — e.g. a degenerate date
    column, a partitioning key, or to join dim_date by integer key instead of casting a
    timestamp to date and matching dim_date.date_day.

    Using this instead of hand-rolling the cast/format logic guarantees the value always
    matches dim_date.date_key for the same calendar date.

    Usage:
        {{ optimist.generate_date_key('departure_at') }} as departure_date_key

    Arguments:
        date_expr (string) — a date or timestamp column/expression, unquoted
#}

{%- macro generate_date_key(date_expr) -%}
    cast(strftime(cast({{ date_expr }} as date), '%Y%m%d') as integer)
{%- endmacro -%}
