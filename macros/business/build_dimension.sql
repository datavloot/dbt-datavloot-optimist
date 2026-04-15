{#
    Generates a standard business-layer dimension model from a YAML config dict.

    Prepends a surrogate key, selects business columns, appends an audit timestamp,
    and optionally deduplicates. Exactly one source option must be provided.

    ── Preferred usage: config in _dim_configs.yml ───────────────────────────────

    Define the dimension config once in models/business/_dim_configs.yml under the
    model's `meta:` block. The model file then just calls the macro with no arguments
    and the config is read automatically from model.meta at compile time.

        -- dim_vessel.sql
        {{ optimist.build_dimension() }}

    ── Inline config (alternative) ──────────────────────────────────────────────

    Pass a parsed YAML dict explicitly when you need to override or when the model
    is not registered in _dim_configs.yml:

        {%- set dim_config -%}
        source_model: stg_harbor__vessels
        surrogate_key:
          columns: [vessel_id]
        {%- endset -%}

        {{ optimist.build_dimension(dim_config | fromyaml) }}

    ── Source options (set exactly one in config) ────────────────────────────────

        source_model   — ref() to a staged source-layer model
        source_seed    — ref() to a dbt seed file
        source_cte     — name of a CTE already defined earlier in this model file;
                         the macro continues the CTE chain instead of opening WITH

    ── Config keys ───────────────────────────────────────────────────────────────

        source_model / source_seed / source_cte
                       (str,  exactly one required)
        surrogate_key  (dict, required) — columns list + optional alias
        deduplicate    (dict, optional) — partition_by + optional order_by
        columns        (list, optional) — explicit output columns; omit to select all

    See models/business/_dim_config_template.yml for the annotated full template.
#}

{%- macro build_dimension(config=none) -%}

    {#- Read config from model.meta when not passed explicitly -#}
    {%- if config is none -%}
        {%- set config = model.meta -%}
    {%- endif -%}

    {%- set source_model = config.get('source_model', none) -%}
    {%- set source_seed  = config.get('source_seed',  none) -%}
    {%- set source_cte   = config.get('source_cte',   none) -%}

    {#- Validate: exactly one source option must be set -#}
    {%- set _sources = [] -%}
    {%- if source_model -%}{%- do _sources.append('source_model') -%}{%- endif -%}
    {%- if source_seed  -%}{%- do _sources.append('source_seed')  -%}{%- endif -%}
    {%- if source_cte   -%}{%- do _sources.append('source_cte')   -%}{%- endif -%}

    {%- if _sources | length == 0 -%}
        {{ exceptions.raise_compiler_error(
            'build_dimension: one of source_model, source_seed, or source_cte is required in config.'
        ) }}
    {%- elif _sources | length > 1 -%}
        {{ exceptions.raise_compiler_error(
            'build_dimension: only one source option is allowed, got: ' ~ _sources | join(', ')
        ) }}
    {%- endif -%}

    {%- set sk_config  = config['surrogate_key'] -%}
    {%- set sk_columns = sk_config['columns'] -%}
    {%- set sk_alias   = sk_config.get('alias', this.identifier ~ '_key') -%}
    {%- set columns    = config.get('columns', []) -%}
    {%- set dedup      = config.get('deduplicate', none) -%}

    {#- Staging audit columns to exclude when selecting * from a staged source -#}
    {%- set _staging_audit = ['_loaded_at', '_source_name', '_source_table'] -%}

{#- source_cte continues an existing WITH chain; all other options start one -#}
{%- if source_cte %}

, source as (

    select * from {{ source_cte }}

),

{%- else %}

with source as (

    {%- if source_model %}
    select * from {{ ref(source_model) }}
    {%- elif source_seed %}
    select * from {{ ref(source_seed) }}
    {%- endif %}

),

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
