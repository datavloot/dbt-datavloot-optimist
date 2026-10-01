# Business layer

The business layer contains analytics-ready models built on top of the source layer.
Models here apply business logic, generate surrogate keys, and deduplicate where needed.
No raw source references (`source()`) belong here — always read from `ref()` or from
an inline CTE.

This is also where joins across source-layer models and aggregations belong. The
[source layer](source-layer.md) intentionally stays one model per source table, so any logic
that combines or summarizes across tables has exactly one place to live: here.

---

## Naming convention

| Model type | Pattern | Example |
|---|---|---|
| Dimension | `dim_<entity>` | `dim_vessel`, `dim_port`, `dim_date` |
| Fact | `fct_<event>` | `fct_journey`, `fct_port_call` |
| Dataset | `dataset_<name>` | `dataset_vessel_activity` |

---

## How dimension keys are named

A dimension's surrogate key column is always named `<entity>_key` — the model name with a
leading `dim_` stripped off (`dim_vessel` → `vessel_key`, `dim_employee` → `employee_key`).
This is computed by a small helper macro, `optimist.dim_key_name`:

```sql
{{ optimist.dim_key_name('dim_employee') }}   -- employee_key
```

`build_dimension()` uses it for a dimension's own default `surrogate_key.alias`, and
`build_fact()` uses it for the default `key`/`alias` when pulling a dimension's key into a
fact. The result: a dimension's key column and every fact column that references it are named
identically by default, so BI tools and AI agents can join fact-to-dim by matching column
names, without being told which side is which. You only need to override the default (via
`surrogate_key.alias` on the dim, or `key`/`alias` on the fact side) when a dimension is joined
more than once and the outputs would otherwise collide (see [Dimension relationships](#dimension-relationships)).

You won't normally call `dim_key_name` directly — it's documented here because it's the
single source of truth behind this convention, not because you need it day to day.

---

## Quickstart

Dimension configs live in a single file in your project — `models/business/_dim_configs.yml`.
The model SQL file only needs the data source and a bare macro call.

**Step 1 — add an entry to `_dim_configs.yml`:**

```yaml
models:
  - name: dim_vessel
    description: "Vessel dimension."
    meta:
      source_model: stg_harbor__vessels
      surrogate_key:
        columns: [vessel_id]
        # alias omitted -> defaults to vessel_key
      columns:
        - vessel_id
        - name
        - vessel_type
        - flag_country
        - length_m
```

**Step 2 — create the model SQL file:**

```sql
-- models/business/dim_vessel.sql
{{ optimist.build_dimension() }}
```

The macro reads `model.meta` at compile time — no config needed in the SQL file.

---

## `build_dimension` — source options

Exactly one source option must be set in the `_dim_configs.yml` meta block.

### Option 1 — `source_model`: staged source

Reads from a source-layer model via `ref()`. The standard path for entity dimensions.

```yaml
# _dim_configs.yml
- name: dim_vessel
  meta:
    source_model: stg_harbor__vessels
    surrogate_key:
      columns: [vessel_id]
    columns: [vessel_id, name, vessel_type, flag_country, length_m]
```

```sql
-- dim_vessel.sql
{{ optimist.build_dimension() }}
```

---

### Option 2 — `source_seed`: seed file

Reads from a dbt seed via `ref()`. Ideal for small static lookup tables in `seeds/`.

```yaml
# _dim_configs.yml
- name: dim_country
  meta:
    source_seed: country_codes
    surrogate_key:
      columns: [iso_code]
    columns: [iso_code, country_name, region]
```

```sql
-- dim_country.sql
{{ optimist.build_dimension() }}
```

---

### Option 3 — `source_cte`: CTE in this file

References a CTE defined earlier in the model SQL file. The macro **continues the
existing CTE chain** instead of opening a new `WITH` block.

Use this for dimensions requiring multi-step preparation before the dimension logic
(`build_dim_date`/`build_dim_time` — see below — use this same pattern internally, but ship
as their own macros rather than a `source_cte` you write yourself).

```yaml
# _dim_configs.yml
- name: dim_vessel
  meta:
    source_cte: enriched_vessels
    surrogate_key:
      columns: [vessel_id]
    columns: [vessel_id, name, vessel_type, flag_country, length_m, journey_count]
```

```sql
-- dim_vessel.sql
with enriched_vessels as (

    select
        v.*,
        count(j.journey_id) as journey_count
    from {{ ref('stg_harbor__vessels') }} v
    left join {{ ref('stg_harbor__journeys') }} j using (vessel_id)
    group by all

)

{{ optimist.build_dimension() }}
```

---

### Composite (multi-column) natural keys

`surrogate_key.columns` isn't limited to one column — pass a list to hash them together when
no single column uniquely identifies a row. For example, a vessel that's only unique per
`[name, type]` rather than by a single natural key:

```yaml
# _dim_configs.yml
- name: dim_vessel_model
  meta:
    source_model: stg_manufacturer__vessel_models
    surrogate_key:
      columns: [name, type]
      # alias omitted -> defaults to vessel_model_key
    columns: [name, type, manufacturer, capacity]
```

A fact joining to a dimension keyed this way matches on the same columns via `build_fact`'s
`fk`/`dim_fk` as lists — see [Dimension relationships](#dimension-relationships) below.

---

## `build_dimension` — full config reference

```yaml
# In _dim_configs.yml, under the model's meta: block.
# Exactly one of these:
source_model: <model_name>
source_seed:  <seed_name>
source_cte:   <cte_name>

# Required
surrogate_key:
  columns: [<col>, ...]         # one or more columns to hash into the key
  alias: <dim_key_name(model)>  # optional; defaults to optimist.dim_key_name(<model name>)

# Optional — remove if source is already unique per natural key
deduplicate:
  partition_by: [<col>, ...]
  order_by: _loaded_at desc   # defaults to _loaded_at desc if omitted

# Optional — remove to select all columns
# When using source_model or source_seed, staging audit columns
# (_loaded_at, _source_name, _source_table) are always excluded automatically.
columns:
  - <col>
  - <col>
```

---

## `build_fact`

Fact models represent events at a defined grain (one row per journey, port call, etc.).
`build_fact` mirrors `build_dimension` in structure — same source options, same
`model.meta` config, same surrogate key and deduplication handling — and adds
`dimensions` to resolve foreign keys to surrogate keys via LEFT JOINs.

### Quickstart

**Step 1 — add an entry to `_fct_configs.yml`:**

```yaml
models:
  - name: fct_journey
    description: "One row per completed sailing journey."
    meta:
      source_model: stg_harbor__journeys
      surrogate_key:
        columns: [journey_id]
        alias: fct_journey_key
      dimensions:
        - dim: dim_vessel
          fk: vessel_id
          # key/alias omitted -> defaults to vessel_key
        - dim: dim_date
          fk: departure_at
          dim_fk: date_day
          fk_cast: date
          alias: departure_date_key
        - dim: dim_date
          fk: arrival_at
          dim_fk: date_day
          fk_cast: date
          alias: arrival_date_key
      columns:
        - journey_id
        - vessel_id
        - distance_nm
        - crew_count
        - duration_hours
```

**Step 2 — create the model SQL file:**

```sql
-- models/business/fct_journey.sql
{{ optimist.build_fact() }}
```

This generates:

```sql
with source as (
    select * from stg_harbor__journeys
),
base as (
    select * from source
),
joined as (
    select
        base.*,
        _dim_0.vessel_key,
        _dim_1.date_key as departure_date_key,
        _dim_2.date_key as arrival_date_key
    from base
    left join dim_vessel _dim_0
        on base.vessel_id = _dim_0.vessel_id
    left join dim_date _dim_1
        on cast(base.departure_at as date) = _dim_1.date_day
    left join dim_date _dim_2
        on cast(base.arrival_at as date) = _dim_2.date_day
),
final as (
    select
        md5(...)              as fct_journey_key,
        vessel_key,
        departure_date_key,
        arrival_date_key,
        journey_id,
        vessel_id,
        distance_nm,
        crew_count,
        duration_hours,
        current_timestamp     as _loaded_at
    from joined
)
select * from final
```

Note the two `dim_date` joins both needed an explicit `alias` — without one, both would default
to `date_key` and collide. `build_fact` raises a compiler error naming the collision if you
forget, rather than emitting broken SQL.

---

### Source options

Same three options as `build_dimension` — `source_model`, `source_seed`, `source_cte`.
Use `source_cte` when the source needs preparation before joining (e.g. casting
timestamps, pre-aggregating):

```sql
-- fct_journey.sql
with prepared as (

    select
        *,
        date_diff('hour', departure_at, arrival_at) as duration_hours
    from {{ ref('stg_harbor__journeys') }}

)

{{ optimist.build_fact() }}
```

```yaml
# _fct_configs.yml
- name: fct_journey
  meta:
    source_cte: prepared
    ...
```

---

### Dimension relationships

Each entry in `dimensions` generates one LEFT JOIN and pulls the dim's surrogate key
into the fact. The same dimension can appear multiple times — each gets a unique
internal join alias automatically, but you must give each occurrence an explicit `alias`
in that case, since the default would otherwise collide across the two joins.

| Key | Required | Default | Description |
|---|---|---|---|
| `dim` | yes | — | Dimension model name (used in `ref()`) |
| `fk` | yes | — | FK column in the source, or a list of columns for a composite key |
| `dim_fk` | no | same as `fk` | Matching column(s) in the dim (when names differ) |
| `fk_cast` | no | none | SQL type to cast `fk` to before joining — one type applied to every column, or a list to cast each individually |
| `key` | no | `optimist.dim_key_name(dim)` | Surrogate key column to pull from the dim |
| `alias` | no | same as `key` | Output column name in the fact |

#### Composite (multi-column) keys

`fk`, `dim_fk`, and `fk_cast` each accept a list instead of a single column, for joining to a
dimension whose natural key spans multiple columns (see `build_dimension`'s
[composite natural keys](#composite-multi-column-natural-keys) above):

```yaml
dimensions:
  - dim: dim_vessel_model
    fk: [vessel_name, vessel_type]      # columns in this fact's source
    dim_fk: [name, type]                # matching columns in dim_vessel_model
    # key/alias omitted -> defaults to vessel_model_key
```

`fk` and `dim_fk` must resolve to the same number of columns — `build_fact` raises a compiler
error naming the mismatch if they don't.

---

### `build_fact` — full config reference

```yaml
# In _fct_configs.yml, under the model's meta: block.
# Exactly one of these:
source_model: <model_name>
source_seed:  <seed_name>
source_cte:   <cte_name>

# Required — defines the grain
surrogate_key:
  columns: [<col>, ...]
  alias: <model_name>_key     # optional; defaults to <model_name>_key

# Optional — one entry per dimension join
dimensions:
  - dim: <dim_model>
    fk: <fk_column>                       # or [<col>, ...] for a composite key
    dim_fk: <dim_column>                  # default: same as fk
    fk_cast: <sql_type>                   # default: no cast
    key: <dim_surrogate_key>              # default: optimist.dim_key_name(dim)
    alias: <output_name>                  # default: same as key

# Optional — remove if source is already unique per grain
deduplicate:
  partition_by: [<col>, ...]
  order_by: _loaded_at desc

# Optional but recommended — explicit measure columns
# Omitting selects all source columns (dim keys and staging audit columns excluded).
columns:
  - <grain_column>
  - <measure_column>
```

**A note on `columns`**: the top-level `columns:` block (with `name`/`description`) documents
every column for dbt docs and tests. `meta.columns` is a *separate*, optional selection list —
omit it and every source column is selected already (minus dim keys and staging audit columns),
so in the common case you don't need to repeat the doc column list here at all. Only set
`meta.columns` when you want to explicitly restrict the output to fewer columns than the source
has. (We deliberately don't auto-derive the selection from the documented columns above it —
that would silently drop any column whose docs aren't filled in yet, which is worse than a
little repetition when it does happen.)

---

## `generate_surrogate_key`

Used internally by `build_dimension`/`build_fact` (and `build_dim_date`/`build_dim_time`, for
dims that don't use it — see below), but also available standalone for custom models. Hashes a
list of columns into a single MD5 string. NULLs coalesce to empty string.

```sql
select
    {{ optimist.generate_surrogate_key(['journey_id', 'waypoint_id']) }} as journey_waypoint_key,
    ...
from my_table
```

Dispatched via `adapter.dispatch`, so a project can override the key generation strategy
entirely — e.g. to avoid hashes altogether — by defining its own `optimist__generate_surrogate_key`
macro. No need to fork the package.

---

## `generate_date_key`

Generates the same YYYYMMDD integer key `dim_date` uses, from any date or timestamp expression:

```sql
select
    {{ optimist.generate_date_key('departure_at') }} as departure_date_key,
    ...
from my_table
```

Use this when a fact needs its own date-key column that's guaranteed to match `dim_date.date_key`
for the same calendar date — e.g. a degenerate date attribute, a partitioning key, or joining
`dim_date` by integer key instead of `fk_cast: date` against `date_day`. It's what `build_dim_date`
uses internally to compute `date_key`, so there's no risk of the two drifting apart.

---

## `build_dim_date` / `build_dim_time`

Unlike every other model in this layer, these two ship as **macros**, not models — call them
from a model file your own project owns, so the date range and time grain are configurable
without forking the package:

```sql
-- models/business/dimensions/dim_date.sql
{{ optimist.build_dim_date() }}
```

```sql
-- models/business/dimensions/dim_time.sql
{{ optimist.build_dim_time() }}
```

Both dimensions key themselves with a plain integer — **not** `generate_surrogate_key`'s hash —
since a calendar date or a time of day already has a natural, sortable integer representation.

| Macro | Default rows | Key column | Configuration |
|---|---|---|---|
| `build_dim_date(start_date=none, end_date=none)` | ~7 600 (2015–2035) | `date_key` — YYYYMMDD integer, via `generate_date_key` | Argument, else `dim_date_start`/`dim_date_end` vars, else the built-in default range |
| `build_dim_time(grain=none)` | 1 440 (`minute`) or 86 400 (`second`) | `time_key` — seconds since midnight, integer | Argument, else the `dim_time_grain` var, else `minute` |

`dim_time`'s column set (`hour`, `minute`, `second`, `time_of_day`, `time_hhmmss`,
`period_of_day`, `is_business_hours`) is identical regardless of grain — `second` is always `0`
at minute grain — so downstream models see a stable shape whichever grain a project picks.

```yaml
# dbt_project.yml — override either default project-wide
vars:
  dim_date_start:  '2018-01-01'
  dim_date_end:    '2040-12-31'
  dim_time_grain:  'second'
```

Reference them like any other dimension: `ref('dim_date')`, `ref('dim_time')`.

---

## `build_dataset`

Not dimensional, unlike everything else in this layer — a flat, denormalized table with an
explicit, required column list drawn from a source you've already prepared. No surrogate key,
no dimension joins. Use it for a governed, documented output on top of work you've already
done (typically a `source_cte` joining source-layer models yourself), not to do that joining
for you.

```yaml
# _dataset_configs.yml
- name: dataset_vessel_activity
  description: "Vessel activity, denormalized for [target tool]."
  meta:
    columns:
      - journey_id
      - departure_at
      - distance_nm
      - vessel_name
      - vessel_type
```

```sql
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
```

`columns` is **required** — unlike `build_fact`/`build_dimension`'s optional-with-select-all
default, a dataset is meant to be a deliberately curated output, not "select everything."
If a listed column doesn't exist in the source, the warehouse raises an ordinary SQL error
when this compiles — no special validation needed.

```yaml
# In _dataset_configs.yml, under the model's meta: block.
# Exactly one of these:
source_model: <model_name>
source_seed:  <seed_name>
source_cte:   <cte_name>

columns:                        # required
  - <col>
  - <col>

# Optional — remove if source is already unique per row
deduplicate:
  partition_by: [<col>, ...]
  order_by: _loaded_at desc
```
