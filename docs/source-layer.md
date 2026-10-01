# Source layer

The source layer contains thin staging models that sit directly on top of raw source tables.
Each model selects all available columns from the source and appends standard audit columns.
No business logic lives here — that belongs in the business layer.

**Guideline, not a hard rule** — this toolkit is used across different teams with different
ways of working, so treat this as advice rather than something to enforce mechanically. The
reasoning behind it: keep a staged model's shape as close as possible to its one source table,
so you can always compare it back to the source system and trust that a mismatch points at
ingestion, not at something a transformation changed along the way. Concretely:

- No joins between tables in a source model — combine tables in the business layer instead.
- No aggregations (`group by`, window functions used to summarize) — aggregate in the business
  layer instead.
- Renaming, casting, deduplicating within the one source table, and adding audit columns are
  fine here — none of those change the model's relationship to its source table.

If you need to combine or summarize across sources, that belongs in a dimension or fact model
(or an intermediate model, if your project has one) — see the [business layer](business-layer.md).

---

## Naming convention

Source models follow the dbt standard double-underscore convention:

```
stg_<source_name>__<table_name>.sql
```

Examples: `stg_harbor__vessels.sql`, `stg_harbor__journeys.sql`

---

## Quickstart

**1. Define your source in `models/source/_sources.yml`**

```yaml
version: 2

sources:
  - name: harbor
    database: lakehouse
    schema: raw_harbor
    freshness:
      warn_after: {count: 12, period: hour}
      error_after: {count: 24, period: hour}
    loaded_at_field: ingested_at

    tables:
      - name: vessels
        description: "Raw vessel registry from the harbor management system."
        columns:
          - name: vessel_id
            description: "Unique vessel identifier."
          - name: name
            description: "Vessel name."
          - name: vessel_type
            description: "Type of vessel (e.g. sailboat, catamaran, motorboat)."
```

**2. Create the staging model**

Create `models/source/stg_harbor__vessels.sql` — the entire file is one line:

```sql
{{ optimist.stage_source('harbor', 'vessels') }}
```

This generates:

```sql
with source as (

    select * from lakehouse.raw_harbor.vessels

),

staged as (

    select
        vessel_id,
        name,
        vessel_type,
        ...,                                      -- all other columns in the source table
        current_timestamp        as _loaded_at,
        'harbor'                 as _source_name,
        'vessels'                as _source_table

    from source

)

select * from staged
```

**3. Document the staged model in `models/source/_schema.yml`**

```yaml
version: 2

models:
  - name: stg_harbor__vessels
    description: "Staged vessel registry from the harbor source."

    columns:
      - name: vessel_id
        description: "Unique vessel identifier."
        data_tests:
          - not_null
          - unique

      - name: _loaded_at
        description: "Timestamp of the dbt run that staged this record."
      - name: _source_name
        description: "Logical source name as declared in sources.yml."
      - name: _source_table
        description: "Table name as declared in sources.yml."
```

---

## Macro reference

### `optimist.stage_source`

Generates a complete staging SELECT for a source table. Introspects the live relation
so it always includes all columns, even if `sources.yml` is not fully documented.

```
optimist.stage_source(source_name, table_name, exclude_columns=[], deduplicate_by=[], order_by='_loaded_at desc', incremental_column=none)
```

| Argument | Type | Required | Description |
|---|---|---|---|
| `source_name` | string | yes | Source name as declared in `sources.yml` |
| `table_name` | string | yes | Table name as declared in `sources.yml` |
| `exclude_columns` | list | no | Column names to omit (case-insensitive). Audit columns are always excluded automatically. |
| `deduplicate_by` | list | no | Columns to partition by when deduplicating. Keeps one row per unique combination. |
| `order_by` | string | no | Row to keep within each partition. Defaults to `_loaded_at desc`. Prefer a source timestamp when available. |
| `incremental_column` | string | no | Timestamp column used to filter new rows on incremental runs. Has no effect on full-refresh runs. Pair with `{{ config(unique_key=...) }}` in the model file. |

**Excluding columns** — useful for PII or columns handled differently downstream:

```sql
{{ optimist.stage_source('harbor', 'crew', exclude_columns=['passport_number', 'date_of_birth']) }}
```

**Incremental loading** — for large tables where processing all rows on every run is too slow.
Only rows newer than the current max of `incremental_column` in the target table are loaded.
Pair with `unique_key` so dbt upserts rather than appends:

```sql
{{ config(unique_key='vessel_id') }}
{{ optimist.stage_source('harbor', 'vessels', incremental_column='updated_at') }}
```

On full-refresh runs (`dbt run --full-refresh`) the filter is skipped and all rows are loaded.

**Deduplicating** — use when the source emits multiple versions of the same record (CDC feeds,
append-only logs with updates). Keep the most recently updated row per natural key:

```sql
{{ optimist.stage_source('harbor', 'vessels', deduplicate_by=['vessel_id'], order_by='updated_at desc') }}
```

This generates an additional `ranked` and `deduped` CTE between `staged` and `final`:

```sql
ranked as (
    select
        *,
        row_number() over (
            partition by vessel_id
            order by updated_at desc
        ) as _row_num
    from staged
),

deduped as (
    select * exclude (_row_num)
    from ranked
    where _row_num = 1
),
```

---

### `optimist.add_audit_columns`

Emits the three standard audit columns as a SQL fragment. Used internally by
`stage_source`, but also available for custom models that don't use `stage_source`.

```
optimist.add_audit_columns(source_name, table_name)
```

The snippet must follow a trailing comma from the last business column:

```sql
select
    vessel_id,
    name,
    {{ optimist.add_audit_columns('harbor', 'vessels') }}
from {{ source('harbor', 'vessels') }}
```

**Produced columns:**

| Column | Type | Description |
|---|---|---|
| `_loaded_at` | timestamp | Timestamp of the dbt run |
| `_source_name` | string | Logical source name from `sources.yml` |
| `_source_table` | string | Table name from `sources.yml` |

---

## Config templates

Blank templates are included in every project created with `optimist new` from [datavloot-toolkit](https://github.com/datavloot/datavloot-toolkit):

- `models/source/_sources.yml` — source definition template
- `models/source/_schema.yml` — staged model documentation template
