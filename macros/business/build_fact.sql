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
                - dim: dim_date
                  fk: departure_at
                  dim_fk: date_day
                  fk_cast: date
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

    Each entry in `dimensions` generates a LEFT JOIN and pulls the dim's surrogate key.
    `key` defaults to optimist.dim_key_name(dim) — e.g. dim: dim_vessel defaults to
    vessel_key — which is also the name build_dimension() gives that column by default
    on the dim side, so in the common case you don't need to specify `key` at all.

        dimensions:
          - dim: dim_vessel           # model to join (ref())
            fk: vessel_id             # FK column in the source
            # key/alias omitted -> defaults to vessel_key

          - dim: dim_date
            fk: departure_at          # FK in source (may need casting)
            dim_fk: date_day          # matching column in dim (default: same as fk)
            fk_cast: date             # cast fk before joining (optional)
            alias: departure_date_key # output alias (default: same as key)

    The same dimension can appear multiple times (e.g. dim_date for departure and
    arrival) — each gets a unique join alias automatically, but you must give each
    occurrence an explicit `alias` in that case: build_fact raises a compiler error
    if two dimension relations would otherwise produce the same output column.

    ── Composite (multi-column) keys ─────────────────────────────────────────────

    `fk`, `dim_fk`, and `fk_cast` each accept a list instead of a single column, for
    joining to a dimension whose natural key spans multiple columns (build_dimension's
    surrogate_key.columns already supports this on the dim side — see its docstring):

        - dim: dim_vessel_model      # unique per [name, type] on the dim side
          fk: [vessel_name, vessel_type]
          dim_fk: [name, type]       # defaults to same list as fk if omitted
          # key/alias omitted -> defaults to vessel_model_key

    `fk` and `dim_fk` must resolve to the same number of columns. `fk_cast`, if given
    as a list, must match that length too (one cast per column); given as a single
    string, it applies to every column.
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

    {#- Normalize each dimension relation up front: fk/dim_fk/fk_cast to equal-length lists,
        key/alias to their resolved names. Used both for the * exclude list and the joined CTE. -#}
    {%- set _dim_rels = [] -%}
    {%- set _dim_key_aliases = [] -%}
    {%- for dim_rel in dimensions -%}
        {%- set _fk      = dim_rel['fk'] -%}
        {%- set _fk_list = [_fk] if _fk is string else _fk -%}
        {%- set _dim_fk      = dim_rel.get('dim_fk', _fk) -%}
        {%- set _dim_fk_list = [_dim_fk] if _dim_fk is string else _dim_fk -%}
        {%- set _fk_cast_raw = dim_rel.get('fk_cast', none) -%}

        {%- if execute -%}
            {%- if (_fk_list | length) != (_dim_fk_list | length) -%}
                {{ exceptions.raise_compiler_error(
                    'build_fact: fk and dim_fk must have the same number of columns for dim `' ~ dim_rel['dim'] ~
                    '` (got ' ~ (_fk_list | length) ~ ' and ' ~ (_dim_fk_list | length) ~ ').'
                ) }}
            {%- endif -%}
            {%- if _fk_cast_raw is not none and _fk_cast_raw is not string and (_fk_cast_raw | length) != (_fk_list | length) -%}
                {{ exceptions.raise_compiler_error(
                    'build_fact: fk_cast list must be the same length as fk for dim `' ~ dim_rel['dim'] ~ '`.'
                ) }}
            {%- endif -%}
        {%- endif -%}

        {%- if _fk_cast_raw is none -%}
            {%- set _fk_cast_list = [none] * (_fk_list | length) -%}
        {%- elif _fk_cast_raw is string -%}
            {%- set _fk_cast_list = [_fk_cast_raw] * (_fk_list | length) -%}
        {%- else -%}
            {%- set _fk_cast_list = _fk_cast_raw -%}
        {%- endif -%}

        {%- set _key   = dim_rel.get('key', optimist.dim_key_name(dim_rel['dim'])) -%}
        {%- set _alias = dim_rel.get('alias', _key) -%}
        {%- do _dim_key_aliases.append(_alias) -%}

        {%- do _dim_rels.append({
            'dim': dim_rel['dim'],
            'fk_list': _fk_list,
            'dim_fk_list': _dim_fk_list,
            'fk_cast_list': _fk_cast_list,
            'key': _key,
            'alias': _alias,
        }) -%}
    {%- endfor -%}

    {#- A collision here would otherwise emit two columns with the same name -#}
    {%- set _seen = [] -%}
    {%- set _dupes = [] -%}
    {%- for a in _dim_key_aliases -%}
        {%- if a in _seen and a not in _dupes -%}
            {%- do _dupes.append(a) -%}
        {%- endif -%}
        {%- do _seen.append(a) -%}
    {%- endfor -%}
    {%- if execute and (_dupes | length) > 0 -%}
        {{ exceptions.raise_compiler_error(
            'build_fact: duplicate output column(s) ' ~ (_dupes | join(', ')) ~
            ' from multiple dimension joins — add an explicit `alias:` to each to disambiguate.'
        ) }}
    {%- endif -%}

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
        {% for r in _dim_rels %}
        {%- set _join_alias = '_dim_' ~ loop.index0 -%}
        {{ _join_alias }}.{{ r.key }}{% if r.alias != r.key %} as {{ r.alias }}{% endif %}{% if not loop.last %},{% endif %}
        {% endfor %}

    from base
    {% for r in _dim_rels %}
    {%- set _join_alias = '_dim_' ~ loop.index0 -%}
    {%- set _on_parts = [] -%}
    {%- for i in range(r.fk_list | length) -%}
        {%- set _cast = r.fk_cast_list[i] -%}
        {%- set _base_expr = ('cast(base.' ~ r.fk_list[i] ~ ' as ' ~ _cast ~ ')') if _cast else ('base.' ~ r.fk_list[i]) -%}
        {%- do _on_parts.append(_base_expr ~ ' = ' ~ _join_alias ~ '.' ~ r.dim_fk_list[i]) -%}
    {%- endfor -%}
    left join {{ ref(r.dim) }} {{ _join_alias }}
        on {{ _on_parts | join(' and ') }}
    {% endfor %}

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
