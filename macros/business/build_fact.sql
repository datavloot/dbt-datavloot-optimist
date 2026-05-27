{#
    Generates a standard business-layer fact model.

    Reads the source and dimension relationships from an inline config dict (required
    for parse-time dependency discovery) and reads surrogate_key and columns from
    model.meta in _fct_configs.yml (populated at compile time). Any key present in
    the inline dict takes precedence over model.meta.

    ── Usage ─────────────────────────────────────────────────────────────────────

    In the model SQL file, pass only the source. The macro merges it with the
    config in _fct_configs.yml at compile time.

        -- fct_journey.sql
        {%- set fct_source -%}
        source_cte: journeys
        {%- endset -%}

        with
        ...
        journeys as (...)

        {{ optimist.build_fact(fromyaml(fct_source)) }}

        # _fct_configs.yml
        - name: fct_journey
          config:
            meta:
              surrogate_key:
                columns: [journey_id]
                alias: fct_journey_key
              dimensions:
                - dim: dim_vessel
                  fk: mmsi
                  key: dim_vessel_key
                - dim: dim_date
                  fk: departure_at
                  dim_fk: date_day
                  fk_cast: date
                  key: dim_date_key
                  alias: departure_date_key
              columns:
                - journey_id
                - duration_minutes

    ── Source options (one required — pass inline so dbt can discover the dependency) ──

        source_model   — ref() to a staged source-layer model
        source_seed    — ref() to a dbt seed file
        source_cte     — name of a CTE already defined earlier in this model file;
                         the macro continues the CTE chain instead of opening WITH

    ── Config keys (inline dict or model.meta in _fct_configs.yml) ───────────────

        source_model / source_seed / source_cte
                       (str,  exactly one required — pass inline)
        surrogate_key  (dict, required) — columns list + optional alias
        dimensions     (list, optional) — dim relationships; see below
        deduplicate    (dict, optional) — partition_by + optional order_by
        columns        (list, optional) — measure columns to include; omit to select all

    ── Dimension relationships ───────────────────────────────────────────────────

    Each entry in `dimensions` generates a LEFT JOIN and pulls the dim surrogate key.

        dimensions:
          - dim: dim_vessel           # model to join (ref())
            fk: vessel_id            # FK column in the source
            key: dim_vessel_key      # surrogate key to pull from dim
            alias: dim_vessel_key    # output alias (default: same as key)

          - dim: dim_date
            fk: departure_at         # FK in source (may need casting)
            dim_fk: date_day         # matching column in dim (default: same as fk)
            fk_cast: date            # cast fk before joining (optional)
            key: dim_date_key
            alias: departure_date_key

    The same dimension can appear multiple times (e.g. dim_date for departure and
    arrival) — each gets a unique join alias automatically.
#}

{%- macro build_fact(fct_config=none) -%}

    {#- Merge inline dict with model.meta; inline takes priority -#}
    {#- At parse time: model.meta is {} (YAML not yet merged), source comes from fct_config -#}
    {#- At compile time: model.meta is populated from _fct_configs.yml config.meta block -#}
    {%- if fct_config is none -%}
        {%- set fct_config = {} -%}
    {%- endif -%}
    {%- set _meta = model.meta | default({}) -%}

    {%- set source_model = fct_config.get('source_model') or _meta.get('source_model', none) -%}
    {%- set source_seed  = fct_config.get('source_seed')  or _meta.get('source_seed',  none) -%}
    {%- set source_cte   = fct_config.get('source_cte')   or _meta.get('source_cte',   none) -%}
    {%- set sk_config    = fct_config.get('surrogate_key') or _meta.get('surrogate_key', {}) -%}
    {%- set dimensions   = fct_config.get('dimensions')    or _meta.get('dimensions', []) -%}
    {%- set columns      = fct_config.get('columns')       or _meta.get('columns', []) -%}
    {%- set dedup        = fct_config.get('deduplicate')   or _meta.get('deduplicate', none) -%}

    {#- Validate: exactly one source option must be set -#}
    {%- set _sources = [] -%}
    {%- if source_model -%}{%- do _sources.append('source_model') -%}{%- endif -%}
    {%- if source_seed  -%}{%- do _sources.append('source_seed')  -%}{%- endif -%}
    {%- if source_cte   -%}{%- do _sources.append('source_cte')   -%}{%- endif -%}

    {%- if execute -%}
        {%- if _sources | length == 0 -%}
            {{ exceptions.raise_compiler_error(
                'build_fact: one of source_model, source_seed, or source_cte is required.'
            ) }}
        {%- elif _sources | length > 1 -%}
            {{ exceptions.raise_compiler_error(
                'build_fact: only one source option is allowed, got: ' ~ _sources | join(', ')
            ) }}
        {%- endif -%}
    {%- endif -%}

    {%- set sk_columns = sk_config.get('columns', []) -%}
    {%- set sk_alias   = sk_config.get('alias', this.identifier ~ '_key') -%}

    {%- set _staging_audit = ['_loaded_at', '_source_name', '_source_table'] -%}

    {#- Collect resolved dim key aliases up-front for use in * exclude list -#}
    {%- set _dim_key_aliases = [] -%}
    {%- for dim_rel in dimensions -%}
        {%- set _key   = dim_rel.get('key',   dim_rel['dim'] ~ '_key') -%}
        {%- set _alias = dim_rel.get('alias', _key) -%}
        {%- do _dim_key_aliases.append(_alias) -%}
    {%- endfor -%}

    {%- set _final_from = 'joined' if dimensions else 'base' -%}

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

{%- if dimensions %}

joined as (

    select

        base.*,
        {%- for dim_rel in dimensions %}
        {%- set _join_alias = '_dim_' ~ loop.index0 -%}
        {%- set _key        = dim_rel.get('key',   dim_rel['dim'] ~ '_key') -%}
        {%- set _alias      = dim_rel.get('alias', _key) -%}
        {{ _join_alias }}.{{ _key }}{% if _alias != _key %} as {{ _alias }}{% endif %}{% if not loop.last %},{% endif %}
        {%- endfor %}

    from base
    {%- for dim_rel in dimensions %}
    {%- set _join_alias = '_dim_' ~ loop.index0 -%}
    {%- set _fk         = dim_rel['fk'] -%}
    {%- set _dim_fk     = dim_rel.get('dim_fk', _fk) -%}
    {%- set _fk_cast    = dim_rel.get('fk_cast', none) -%}
    left join {{ ref(dim_rel['dim']) }} {{ _join_alias }}
        on {% if _fk_cast %}cast(base.{{ _fk }} as {{ _fk_cast }}){% else %}base.{{ _fk }}{% endif %} = {{ _join_alias }}.{{ _dim_fk }}
    {%- endfor %}

),

{%- endif %}

final as (

    select

        -- surrogate key
        {{ optimist.generate_surrogate_key(sk_columns) }} as {{ sk_alias }},

        -- dimension keys
        {%- for _alias in _dim_key_aliases %}
        {{ _alias }},
        {%- endfor %}

        -- measures
        {%- if columns %}
        {%- for col in columns %}
        {{ col }},
        {%- endfor %}
        {%- else %}
            {%- set _exclude = _dim_key_aliases + _staging_audit + (['_row_num'] if dedup else []) %}
        * exclude ({{ _exclude | join(', ') }}),
        {%- endif %}

        -- audit
        current_timestamp as _loaded_at

    from {{ _final_from }}

)

select * from final

{%- endmacro -%}
