# optimist (datavloot)

dbt macros for building a Kimball-style warehouse in two layers:

- **source layer**: `stage_source`, `add_audit_columns`
- **business layer**: `build_dimension`, `build_fact`, `build_dataset`, `build_dim_date`, `build_dim_time`, plus key helpers (`generate_surrogate_key`, `generate_date_key`, `dim_key_name`)

The modelling conventions are in [data-instructions.md](data-instructions.md). After `dbt deps`, consuming projects can read them at `dbt_packages/optimist/data-instructions.md`.

## Installation

```yaml
packages:
  - git: "https://github.com/datavloot/dbt-datavloot-optimist.git"
    revision: 0.1.0
```

Then run `dbt deps`. Requires dbt-core 1.8 or later.

## Usage

```sql
-- models/source/stg_crm__customers.sql
{{ optimist.stage_source('crm', 'customers') }}
```

The docstring at the top of each macro in [macros/](macros/) documents its arguments.

## Variables

Set these in your own `dbt_project.yml`:

| var | default | used by |
|---|---|---|
| `dim_date_start` | `2015-01-01` | `build_dim_date` |
| `dim_date_end` | `2035-12-31` | `build_dim_date` |
| `dim_time_grain` | `minute` | `build_dim_time` |

## License

See [LICENSE](LICENSE).
