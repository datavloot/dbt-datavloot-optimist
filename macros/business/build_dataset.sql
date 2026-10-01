{#
    Generates a flat, denormalized dataset (one-big-table) model — not dimensional.
    Unlike build_fact()/build_dimension(), there's no surrogate key and no dimension
    joins: it selects an explicit, required list of columns from a source you've
    already prepared (typically a source_cte joining source-layer models yourself,
    or a single staged model). Use it for a governed, documented output on top of
    work you've already done, not to do that work for you.

    Reads source from an inline config dict (required for parse-time dependency
    discovery) and reads everything else from model.meta in _dataset_configs.yml
    (populated at compile time). Any key present in the inline dict takes
    precedence over model.meta.

    ── Usage ─────────────────────────────────────────────────────────────────────

        -- dataset_vessel_activity.sql
        {%- set dataset_source -%}
        source_cte: joined
        {%- endset -%}

        with joined as (

            select
                j.journey_id,
                j.departure_at,
                j.distance_nm,
                v.name as vessel_name,
                v.vessel_type
            from {{ ref('stg_harbor__journeys') }} j
            left join {{ ref('stg_harbor__vessels') }} v using (vessel_id)

        )

        {{ optimist.build_dataset(fromyaml(dataset_source)) }}

        # _dataset_configs.yml
        - name: dataset_vessel_activity
          config:
            meta:
              columns:
                - journey_id
                - departure_at
                - distance_nm
                - vessel_name
                - vessel_type

    ── Source options (one required — pass inline so dbt can discover the dependency) ──

        source_model   — ref() to a staged source-layer model
        source_seed    — ref() to a dbt seed file
        source_cte     — name of a CTE already defined earlier in this model file;
                         the macro continues the CTE chain instead of opening WITH

    ── Config keys (inline dict or model.meta in _dataset_configs.yml) ───────────

        source_model / source_seed / source_cte
                       (str,  exactly one required — pass inline)
        columns        (list, required) — output columns, selected as-is from the
                       source. Unlike build_fact/build_dimension this is not
                       optional: a dataset is meant to be a deliberately curated,
                       documented output, not a "select everything" default. If a
                       listed column doesn't exist in the source, the warehouse
                       raises an ordinary SQL error when this compiles.
        deduplicate    (dict, optional) — partition_by + optional order_by
#}

{%- macro build_dataset(dataset_config=none) -%}

    {#- Merge inline dict with model.meta; inline takes priority -#}
    {#- At parse time: model.meta is {} (YAML not yet merged), source comes from dataset_config -#}
    {#- At compile time: model.meta is populated from _dataset_configs.yml config.meta block -#}
    {%- if dataset_config is none -%}
        {%- set dataset_config = {} -%}
    {%- endif -%}
    {%- set _meta = model.meta | default({}) -%}

    {%- set source_model = dataset_config.get('source_model') or _meta.get('source_model', none) -%}
    {%- set source_seed  = dataset_config.get('source_seed')  or _meta.get('source_seed',  none) -%}
    {%- set source_cte   = dataset_config.get('source_cte')   or _meta.get('source_cte',   none) -%}
    {%- set columns      = dataset_config.get('columns')      or _meta.get('columns', []) -%}
    {%- set dedup        = dataset_config.get('deduplicate')  or _meta.get('deduplicate', none) -%}

    {#- Validate: exactly one source option must be set, and columns is required -#}
    {%- set _sources = [] -%}
    {%- if source_model -%}{%- do _sources.append('source_model') -%}{%- endif -%}
    {%- if source_seed  -%}{%- do _sources.append('source_seed')  -%}{%- endif -%}
    {%- if source_cte   -%}{%- do _sources.append('source_cte')   -%}{%- endif -%}

    {%- if execute -%}
        {%- if _sources | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                'build_dataset: one of source_model, source_seed, or source_cte is required.'
            ) }}
        {%- elif _sources | length > 1 -%}
            {{ exceptions.raise_compiler_error(
                'build_dataset: only one source option is allowed, got: ' ~ _sources | join(', ')
            ) }}
        {%- endif -%}
        {%- if columns | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                'build_dataset: columns is required — list the columns this dataset exposes.'
            ) }}
        {%- endif -%}
    {%- endif -%}

{#- source_cte continues an existing WITH chain; all other options open one -#}
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

        {%- for col in columns %}
        {{ col }},
        {%- endfor %}

        current_timestamp as _loaded_at

    from base

)

select * from final

{%- endmacro -%}
