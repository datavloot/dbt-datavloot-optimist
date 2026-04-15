{#
    Generates a surrogate key by hashing a list of columns into a single MD5 string.

    NULL values are coalesced to an empty string before hashing so a single NULL
    column does not nullify the entire key. Columns are separated by '||' to reduce
    the chance of collisions between adjacent values.

    Usage:
        {{ optimist.generate_surrogate_key(['order_id', 'line_id']) }} as order_line_key

    Arguments:
        columns (list) — column names to include in the hash
#}

{%- macro generate_surrogate_key(columns) -%}
    md5(
        concat_ws(
            '||',
            {%- for col in columns %}
            coalesce(cast({{ col }} as varchar), ''){% if not loop.last %},{% endif %}
            {%- endfor %}
        )
    )
{%- endmacro -%}
