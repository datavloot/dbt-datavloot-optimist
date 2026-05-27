{#
    Generates a standard business-layer dimension model.

    Reads source from an inline config dict (required for parse-time dependency
    discovery) and reads everything else from model.meta in _dim_configs.yml
    (populated at compile time). Any key present in the inline dict takes
    precedence over model.meta.

    ── Usage ─────────────────────────────────────────────────────────────────────

    In the model SQL file, pass only the source. The macro merges it with the
    config in _dim_configs.yml at compile time.

        -- dim_vessel.sql
        {%- set dim_source -%}
        source_model: stg_harbor__vessels
        {%- endset -%}

        {{ optimist.build_dimension(fromyaml(dim_source)) }}

        # _dim_configs.yml
        - name: dim_vessel
          config:
            meta:
              surrogate_key:
                columns: [mmsi]
                alias: dim_vessel_key
              columns:
                - mmsi
                - vessel_name

    For dimensions that open a CTE chain themselves (e.g. dim_date, dim_time):

        -- dim_date.sql
        {%- set dim_source -%}
        source_cte: date_spine
        {%- endset -%}

        with date_spine as (...)

        {{ optimist.build_dimension(fromyaml(dim_source)) }}

    ── Source options (one required — pass inline so dbt can discover the dependency) ──

        source_model   — ref() to a staged source-layer model
        source_seed    — ref() to a dbt seed file
        source_cte     — name of a CTE already defined earlier in this model file;
                         the macro continues the CTE chain instead of opening WITH

    ── Config keys (inline dict or model.meta in _dim_configs.yml) ───────────────

        source_model / source_seed / source_cte
                       (str,  exactly one required — pass inline)
        surrogate_key  (dict, required) — columns list + optional alias
        deduplicate    (dict, optional) — partition_by + optional order_by
        columns        (list, optional) — explicit output columns; omit to select all

    See models/business/_dim_config_template.yml for the annotated full template.
#}

{%- macro build_dimension(dim_config=none) -%}

    {#- Merge inline dict with model.meta; inline takes priority -#}
    {#- At parse time: model.meta is {} (YAML not yet merged), source comes from dim_config -#}
    {#- At compile time: model.meta is populated from _dim_configs.yml config.meta block -#}
    {%- if dim_config is none -%}
        {%- set dim_config = {} -%}
    {%- endif -%}
    {%- set _meta = model.meta | default({}) -%}

    {%- set source_model = dim_config.get('source_model') or _meta.get('source_model', none) -%}
    {%- set source_seed  = dim_config.get('source_seed')  or _meta.get('source_seed',  none) -%}
    {%- set source_cte   = dim_config.get('source_cte')   or _meta.get('source_cte',   none) -%}
    {%- set sk_config    = dim_config.get('surrogate_key') or _meta.get('surrogate_key', {}) -%}
    {%- set columns      = dim_config.get('columns')       or _meta.get('columns', []) -%}
    {%- set dedup        = dim_config.get('deduplicate')   or _meta.get('deduplicate', none) -%}

    {#- Validate: exactly one source option must be set -#}
    {%- set _sources = [] -%}
    {%- if source_model -%}{%- do _sources.append('source_model') -%}{%- endif -%}
    {%- if source_seed  -%}{%- do _sources.append('source_seed')  -%}{%- endif -%}
    {%- if source_cte   -%}{%- do _sources.append('source_cte')   -%}{%- endif -%}

    {#- Only validate when executing — at parse time source may resolve via model.meta later -#}
    {%- if execute -%}
        {%- if _sources | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                'build_dimension: one of source_model, source_seed, or source_cte is required.'
            ) }}
        {%- elif _sources | length > 1 -%}
            {{ exceptions.raise_compiler_error(
                'build_dimension: only one source option is allowed, got: ' ~ _sources | join(', ')
            ) }}
        {%- endif -%}
    {%- endif -%}

    {%- set sk_columns = sk_config.get('columns', []) -%}
    {%- set sk_alias   = sk_config.get('alias', this.identifier ~ '_key') -%}

    {#- Staging audit columns to exclude when selecting * from a staged source -#}
    {%- set _staging_audit = ['_loaded_at', '_source_name', '_source_table'] -%}

{#- source_cte continues an existing WITH chain; all other options start one -#}
{%- if source_cte %}

, source as (

    select * from {{ source_cte }}

),

{%- elif source_model or source_seed %}

with source as (

    {%- if source_model %}
    select * from {{ ref(source_model) }}
    {%- elif source_seed %}
    select * from {{ ref(source_seed) }}
    {%- endif %}

),

{%- else %}

with source as (select 1 as _stub),

{%- endif %}

{%- if dedup %}

    {%- set partition_by = dedup['partition_by'] | join(', ') -%}
    {%- set order_by     = dedup.get('order_by', '_loaded_at desc') %}

ranked as (

    select
        *,
        row_number() over (
            partition by {{ partition_by }}
            order by {{ order_by }}
        ) as _row_num

    from source

),

base as (

    select * from ranked where _row_num = 1

),

{%- else %}

base as (

    select * from source

),

{%- endif %}

final as (

    select

        -- surrogate key
        {{ optimist.generate_surrogate_key(sk_columns) }} as {{ sk_alias }},

        -- business columns
        {%- if columns %}
        {%- for col in columns %}
        {{ col }},
        {%- endfor %}
        {%- else %}
            {%- set _exclude = _staging_audit + (['_row_num'] if dedup else []) %}
        * exclude ({{ _exclude | join(', ') }}),
        {%- endif %}

        -- audit
        current_timestamp as _loaded_at

    from base

)

select * from final

{%- endmacro -%}
