{#
    Generates the standard audit columns to be appended to every source layer model.

    Usage — embed at the end of a SELECT (after a trailing comma on the last business column):

        select
            my_col,
            {{ optimist.add_audit_columns(source_name='my_source', table_name='my_table') }}
        from ...

    Produced columns:
        _loaded_at    — timestamp when this dbt model run executed
        _source_name  — the logical source name as declared in sources.yml
        _source_table — the table name as declared in sources.yml
#}

{%- macro add_audit_columns(source_name, table_name) -%}
    current_timestamp                    as _loaded_at,
    '{{ source_name }}'                  as _source_name,
    '{{ table_name }}'                   as _source_table
{%- endmacro -%}
