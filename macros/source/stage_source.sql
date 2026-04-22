{#
    Generates a complete source-layer staging model for a given source table.

    Introspects the live relation to select ALL available columns, then appends the
    standard audit columns via add_audit_columns. This means the staged model stays
    in sync with schema changes in the source without manual updates.

    Arguments:
        source_name         (str)  — source name as declared in sources.yml
        table_name          (str)  — table name as declared in sources.yml
        exclude_columns     (list) — optional list of column names to omit (case-insensitive).
                                     Audit column names (_loaded_at, _source_name, _source_table)
                                     are always excluded to prevent duplicates.
        deduplicate_by      (list) — optional list of columns to partition by when deduplicating.
                                     When set, keeps one row per unique combination of these columns.
                                     Use for sources that emit multiple versions of the same record
                                     (e.g. CDC feeds, append-only logs with updates).
        order_by            (str)  — row to keep within each partition when deduplicating.
                                     Defaults to '_loaded_at desc' (last-loaded row wins).
                                     Prefer a source timestamp column when one is available,
                                     e.g. 'updated_at desc'.
        incremental_column  (str)  — optional timestamp column used to filter new rows when the
                                     model is materialized as incremental. On incremental runs,
                                     only rows where this column exceeds the current max in the
                                     target table are loaded. Has no effect on full-refresh runs
                                     or when the model is not materialized as incremental.
                                     Pair with {{ config(unique_key='...') }} in the model file
                                     to enable upserts instead of plain appends.

    Usage — the entire model file can be a single line:

        {{ optimist.stage_source('my_source', 'my_table') }}

    With explicit exclusions:

        {{ optimist.stage_source('my_source', 'my_table', exclude_columns=['ssn', 'password_hash']) }}

    With deduplication — keep the most recently updated row per natural key:

        {{ optimist.stage_source('my_source', 'my_table', deduplicate_by=['record_id'], order_by='updated_at desc') }}

    With incremental loading — only process rows newer than what is already staged:

        {{ config(unique_key='record_id') }}
        {{ optimist.stage_source('my_source', 'my_table', incremental_column='updated_at') }}
#}

{%- macro stage_source(source_name, table_name, exclude_columns=[], deduplicate_by=[], order_by='_loaded_at desc', incremental_column=none) -%}

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

    {%- set _dedup = deduplicate_by | length > 0 -%}

with source as (

    select * from {{ relation }}
    {%- if is_incremental() and incremental_column %}
    where {{ incremental_column }} > (select max({{ incremental_column }}) from {{ this }})
    {%- endif %}

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

),

{%- if _dedup %}

ranked as (

    select
        *,
        row_number() over (
            partition by {{ deduplicate_by | join(', ') }}
            order by {{ order_by }}
        ) as _row_num
    from staged

),

deduped as (

    select * exclude (_row_num)
    from ranked
    where _row_num = 1

),

{%- endif %}

final as (

    select * from {{ 'deduped' if _dedup else 'staged' }}

)

select * from final

{%- endmacro -%}
