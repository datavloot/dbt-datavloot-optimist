# Workflow and conventions — optimist-toolkit

Single source of truth for all consuming projects. Referenced from each project's own `data-instructions.md`
via `dbt_packages/optimist/data-instructions.md` after `dbt deps`.

---

## Captain and crew

**Captain** — the human user who describes what they want to understand or measure.
**Crew** — AI agents (e.g. Claude) who translate that into working dbt models.

As crew, your job is to ask the right questions and then build exactly what the captain describes,
following the conventions in this file. Do not build speculatively — confirm understanding before
creating any files.

---

## Pre-departure: what to ask the captain first

Before writing any code, confirm:

1. What business process or data do they want to model?
2. What source system(s) does the data come from — database, schema, and table names?
3. What questions should the data answer? (This drives which dimensions and facts to build.)
4. What is the grain of each fact? (One row = one ___?)

---

## Workflow

Follow this order strictly. Each step depends on the previous.

### Step 1 — Define sources

Edit `models/source/_sources.yml`. Add one source block per source system, with one table
entry per raw table the captain wants to use.

Ask the captain: how recently should each source have received data? Configure `freshness`
and `loaded_at_field` accordingly (see Step 7 — Data quality).

Full template and freshness config options: `models/source/_sources.yml`

### Step 2 — Stage sources

For each raw table, create a staging model.

**`models/source/stg_<source>__<table>.sql`**:
```sql
{{ optimist.stage_source('<source>', '<table>') }}
```

Then add a model entry to `models/source/_schema.yml` with column descriptions and `data_tests`.

**Materialization** — configure by folder in `dbt_project.yml`, not in individual model files.
The default is `incremental`; alternatives for sources without a reliable update timestamp:

- `ephemeral` — the staging model is inlined as a CTE at compile time; use when an external
  tool (dlt, Fivetran) manages incrementality and you don't need the staging model to be
  independently queryable.
- `view` — always-fresh database view; use when dbt queries the source directly and you want
  data to be current on every run without incremental filtering.

**Incremental loading** — when using `incremental` materialization, every staging model needs:

1. A `unique_key` config so dbt upserts instead of appending:
   ```sql
   {{ config(unique_key='<natural_key>') }}
   {{ optimist.stage_source('<source>', '<table>', incremental_column='<updated_at_col>') }}
   ```
2. Ask the captain: which column marks when a row was last updated? (e.g. `updated_at`, `modified_at`, `ingested_at`)

**Deduplication** — ask the captain: does this source emit multiple versions of the same record
(e.g. a CDC feed or append-only log with updates)? If yes, add `deduplicate_by` with the natural
key column(s) and add a `unique` test on that column in `_schema.yml`:

```sql
{{ optimist.stage_source('<source>', '<table>', deduplicate_by=['<natural_key>'], order_by='<updated_at_col> desc') }}
```

```yaml
# models/source/_schema.yml
- name: <natural_key>
  description: ""
  data_tests:
    - not_null
    - unique     # enforces the deduplication guarantee
```

After creating each staging model, ask the captain about data quality expectations — see **Step 7**.

Reference: `dbt_packages/optimist/docs/source-layer.md`

### Step 3 — Add seed data (optional)

If the captain needs mapping tables, code lookups, or other small static reference data that
doesn't exist in any source system, add it as a seed before building dimensions.

1. Add a CSV file to `seeds/<seed_name>.csv`
2. Add an entry to `seeds/_seeds.yml` with descriptions and `data_tests`
3. Run `dbt seed` to load it into the warehouse

Seeds can then be used as a dimension source via `source_seed: <seed_name>` in the inline config block of a dimension SQL file.

Guidance on when seeds are appropriate: `seeds/how_to.md`

### Step 4 — Build dimensions

For each entity the captain cares about (person, product, location, vessel, etc.):

1. Create `models/business/dimensions/dim_<entity>.sql` declaring only the source inline
   (so dbt can discover the `ref()` dependency at parse time):
   ```sql
   {%- set dim_source -%}
   source_model: stg_<source>__<table>
   {%- endset -%}

   {{ optimist.build_dimension(fromyaml(dim_source)) }}
   ```
2. Add an entry to `models/business/dimensions/_dim_configs.yml` with column descriptions,
   `data_tests`, and a `config.meta` block with the build config:
   ```yaml
   - name: dim_<entity>
     description: ""
     columns:
       - name: dim_<entity>_key
         description: "Surrogate key; MD5 hash of <natural_key>."
       - name: <natural_key>
         description: ""
     config:
       meta:
         surrogate_key:
           columns: [<natural_key>]
           alias: dim_<entity>_key
         columns:
           - <natural_key>
           - <attribute_column>
   ```

`dim_date` and `dim_time` ship with the toolkit — reference them with `ref('dim_date')` and
`ref('dim_time')` without creating new models.

After creating each dimension, ask the captain about data quality expectations — see **Step 7**.

Full config reference: `dbt_packages/optimist/macros/business/build_dimension.sql` (docstring)

### Step 5 — Build facts

For each event or transaction the captain wants to measure:

1. Create `models/business/facts/fct_<event>.sql` with the CTE chain. Declare the source inline
   (so dbt discovers the source dependency at parse time), and add `-- depends_on:` hints for
   each dimension so dbt can build the correct DAG:
   ```sql
   -- depends_on: {{ ref('dim_<entity>') }}
   -- depends_on: {{ ref('dim_date') }}

   {% set fct_source %}
   source_cte: <final_cte_name>
   {% endset %}

   with
   ...
   <final_cte_name> as (...)

   {{ optimist.build_fact(fromyaml(fct_source)) }}
   ```
2. Add an entry to `models/business/facts/_fct_configs.yml` with column descriptions,
   `data_tests`, and a `config.meta` block with the build config:
   ```yaml
   - name: fct_<event>
     description: ""
     columns:
       - name: fct_<event>_key
         description: "Surrogate key; MD5 hash of <grain_columns>."
     config:
       meta:
         surrogate_key:
           columns: [<grain_column>]
           alias: fct_<event>_key
         dimensions:
           - dim: dim_<entity>
             fk: <fk_column>
             key: dim_<entity>_key
           - dim: dim_date
             fk: <timestamp_column>
             dim_fk: date_day
             fk_cast: date
             key: dim_date_key
             alias: <event>_date_key
         columns:
           - <grain_column>
           - <measure_column>
   ```

After creating each fact, ask the captain about data quality expectations — see **Step 7**.

Full config reference: `dbt_packages/optimist/macros/business/build_fact.sql` (docstring)

### Step 6 — Document

Add `columns` entries with descriptions to every model in the relevant `_configs.yml` or
`_schema.yml`. Follow the pattern used in `dim_date` and `dim_time` inside
`dbt_packages/optimist/models/business/dimensions/_dim_configs.yml`.

### Step 7 — Data quality tests

After creating **each model**, ask the captain the following questions and configure tests
based on their answers. Do not skip this step — undocumented expectations become silent failures.

#### Questions to ask

| Topic | Question |
|---|---|
| Nulls | Which columns must always have a value? |
| Uniqueness | Which column (or combination) uniquely identifies a row? |
| Accepted values | Are there columns with a fixed set of valid values? (e.g. status, category, type) |
| Dates in the future | Are there date or timestamp columns that can never be ahead of today? |
| Dates in the past | Are there date columns that should never be before a certain cutoff? |
| Numeric ranges | Are there numeric columns with expected bounds? (e.g. amounts > 0, percentages 0–100) |
| Referential integrity | Should any FK column always resolve to a row in another model? |
| Freshness *(sources only)* | How long after an expected load is a missing update considered a warning? An error? |

#### Generic tests — in `_schema.yml`, `_dim_configs.yml`, or `_fct_configs.yml`

```yaml
columns:
  - name: order_id
    data_tests:
      - not_null
      - unique

  - name: status
    data_tests:
      - not_null
      - accepted_values:
          values: ['pending', 'confirmed', 'cancelled']

  - name: dim_customer_key
    data_tests:
      - not_null
      - relationships:
          to: ref('dim_customer')
          field: dim_customer_key
```

#### Singular tests — for custom logic, one SQL file per test in `tests/`

A singular test fails if it returns any rows. Name the file to make the assertion obvious.

```sql
-- tests/assert_fct_order_order_date_not_in_future.sql
select *
from {{ ref('fct_order') }}
where order_date > current_date
```

```sql
-- tests/assert_fct_order_amount_positive.sql
select *
from {{ ref('fct_order') }}
where amount <= 0
```

```sql
-- tests/assert_dim_date_no_gaps.sql
-- Fails if any consecutive pair of dates is more than 1 day apart.
select date_day
from {{ ref('dim_date') }}
where date_day - lag(date_day) over (order by date_day) > interval '1 day'
```

#### Source freshness — in `models/source/_sources.yml`

```yaml
sources:
  - name: harbor
    loaded_at_field: ingested_at      # column dbt checks to evaluate freshness
    freshness:
      warn_after:  {count: 12, period: hour}
      error_after: {count: 24, period: hour}
    tables:
      - name: vessels
        # Override freshness per table if this table updates less frequently:
        # freshness:
        #   warn_after:  {count: 7, period: day}
        #   error_after: {count: 14, period: day}
```

Run `dbt source freshness` to check all configured sources.

---

## Modelling conventions

### Kimball dimensional modelling

Facts contain **measures** (quantitative values) and **foreign keys** to dimensions. All descriptive
context belongs in dimension tables. Do not add attribute columns to a fact unless they are a
genuine measure or a degenerate dimension.

**Degenerate dimensions** are natural-key or categorical columns kept on the fact because they do
not warrant their own dimension table (e.g. a transaction number, a sparse status code). Always add
a comment on the column explaining why no dimension table was built:

```sql
-- degenerate dimension: status codes are sparse and operator-entered;
-- a full dim_status table would add noise without analytical value.
status,
```

### CTE structure in fact SQL

All upstream model references (`ref(...)`) must appear as named import CTEs at the top of the
file, before any transformation logic. Transformation CTEs reference only other CTEs — never
`ref()` directly inside a transformation CTE.

```sql
with

-- imports
orders_raw as (
    select * from {{ ref('stg_orders') }}
),

customers_raw as (
    select * from {{ ref('dim_customer') }}
),

-- transform
orders as (
    select
        order_id,
        customer_id,
        cast(order_ts as timestamp) as order_time
    from orders_raw
),

...
```

### Single source of truth for lookup thresholds

Classification thresholds (e.g. wind speed bands, price tiers) are defined once in a seed.
Facts use a range join (`>= min AND < max`) to resolve the category. Do not duplicate thresholds
in a CASE statement inside the fact SQL.

```sql
-- in the fact: range-join on the seed, not a CASE statement
left join sea_state_categories s
    on  w.wind_speed_10m_kn >= s.min_wind_speed_kn
    and w.wind_speed_10m_kn <  s.max_wind_speed_kn
```

---

## Naming conventions

| Layer | Pattern | Example |
|---|---|---|
| Staging | `stg_<source>__<table>` | `stg_harbor__vessels` |
| Dimension | `dim_<entity>` | `dim_vessel` |
| Fact | `fct_<event>` | `fct_journey` |
| Surrogate key | `<model>_key` | `dim_vessel_key`, `fct_journey_key` |

- Double underscore (`__`) separates the source name from the table name in staging models.
- Dimension entities are singular nouns (`dim_vessel`, not `dim_vessels`).
- Fact events are noun phrases (`fct_orders`, `fct_port_calls`).
- All config lives in `_configs.yml` files — no logic in SQL files.

---

## File map

```
seeds/
├── _seeds.yml                        # seed descriptions and data_tests — edit here
├── how_to.md                         # guidance on when to use seeds
└── <seed_name>.csv                   # one file per seed
models/
├── source/
│   ├── _sources.yml                  # raw source definitions + freshness — edit here
│   ├── _schema.yml                   # staging model docs and tests — edit here
│   └── stg_<source>__<table>.sql     # one file per source table
└── business/
    ├── dimensions/
    │   ├── _dim_configs.yml          # all dimension configs and tests — edit here
    │   └── dim_<entity>.sql          # one file per dimension
    └── facts/
        ├── _fct_configs.yml          # all fact configs and tests — edit here
        └── fct_<event>.sql           # one file per fact
tests/
└── assert_<model>_<description>.sql  # one file per custom singular test
```

If multiple source systems have different materialization requirements, split `models/source/`
into subfolders (e.g. `source/ais/`, `source/open_meteo/`) and configure each folder separately
in `dbt_project.yml`.

---

## When to pause and ask the captain

- Before creating any model: confirm the grain (one row = one ___?)
- Before joining a dimension to a fact: confirm which column maps to which
- When a source column name is ambiguous: ask, don't assume
- When a business rule could go multiple ways: surface the options, let the captain decide
