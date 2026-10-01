{#
    Derives the conventional surrogate key column name for a dimension: strip a leading
    "dim_" off the model name and append "_key" (dim_employee -> employee_key).

    This is the single source of truth behind the toolkit's naming convention: a dimension's
    own surrogate key, and every column that references it from a fact or another dimension,
    default to this same name. That's what lets BI tools and AI agents join fact-to-dim (or
    dim-to-dim) by matching column names, without being told which side is which.

    Used internally by build_dimension() (for its own default surrogate_key.alias) and by
    resolve_dimension_joins() (for the default key/alias of each dimension relation). Not
    normally called directly, but nothing stops a model from using it.

    Usage:
        {{ optimist.dim_key_name('dim_employee') }}   -> employee_key
        {{ optimist.dim_key_name('dim_date') }}       -> date_key

    Arguments:
        dim_model_name (string) — a dimension model name, conventionally prefixed "dim_".
                                   Names without that prefix just get "_key" appended.
#}

{%- macro dim_key_name(dim_model_name) -%}
    {%- if dim_model_name.startswith('dim_') -%}
        {{ return(dim_model_name[4:] ~ '_key') }}
    {%- else -%}
        {{ return(dim_model_name ~ '_key') }}
    {%- endif -%}
{%- endmacro -%}
