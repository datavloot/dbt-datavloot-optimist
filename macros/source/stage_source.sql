{#
    Generates a complete source-layer staging model for a given source table.

    Introspects the live relation to select ALL available columns, then appends the
    standard audit columns via add_audit_columns. This means the staged model stays
    in sync with schema changes in the source without manual updates.

    Arguments:
        source_name       (str)  — source name as declared in sources.yml
        table_name        (str)  — table name as declared in sources.yml
        exclude_columns   (list) — optional list of column names to omit (case-insensitive).
                                   Audit column names (_loaded_at, _source_name, _source_table)
                                   are always excluded to prevent duplicates.

    Usage — the entire model file can be a single line:

        {{ optimist.stage_source('my_source', 'my_table') }}

    Or with explicit exclusions:

        {{ optimist.stage_source('my_source', 'my_table', exclude_columns=['ssn', 'password_hash']) }}
#}

{%- macro stage_source(source_name, table_name, exclude_columns=[]) -%}

    {%- set relation = source(source_name, table_name) -%}
    {%- set source_columns = adapter.get_columns_in_relation(relation) -%}

    {#- Build a lowercase set of names to exclude, always including audit column names -#}
    {%- set _audit_cols = ['_loaded_at', '_source_name', '_source_table'] -%}
    {%- set exclude_lower = (exclude_columns + _audit_cols) | map('lower') | list -%}

    {%- set selected_columns = [] -%}
    {%- for col in source_columns -%}
        {%- if col.name | lower not in exclude_lower -%}
            {%- do selected_columns.append(col.name) -%}
        {%- endif -%}
    {%- endfor -%}

with source as (

    select * from {{ relation }}

),

staged as (

    select

        {#- Source columns -#}
        {%- for col_name in selected_columns %}
        {{ col_name }},
        {%- endfor %}

        {#- Audit columns -#}
        {{ optimist.add_audit_columns(source_name, table_name) }}

    from source

)

select * from staged

{%- endmacro -%}
