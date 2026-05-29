{# /elementary/macros/utils/cross_db_utils/timeadd.sql #}
{# FIX: A Snowflake macro was set as default timestamp behavior #}
{% macro snowflake__edr_timeadd(date_part, number, timestamp_expression) %}
    dateadd({{ date_part }}, {{ elementary.edr_cast_as_int(number) }}, {{ elementary.edr_cast_as_timestamp(timestamp_expression) }})
{% endmacro %}

{# FIX: Postgres as default timestamp behavior #}
{% macro default__edr_timeadd(date_part, number, timestamp_expression) %}
    {{ elementary.edr_cast_as_timestamp(timestamp_expression) }} + {{ elementary.edr_cast_as_int(number) }} * INTERVAL '1 {{ date_part }}'
{% endmacro %}

{% macro duckdb__edr_timeadd(date_part, number, timestamp_expression) %}
    {{ elementary.edr_cast_as_timestamp(timestamp_expression) }} + {{ elementary.edr_cast_as_int(number) }} * INTERVAL '1 {{ date_part }}'
{% endmacro %}

{# elementary/macros/utils/table_operations/delete_and_insert.sql #}
{# FIX: Removed begin/end transaction behavior #}
{% macro duckdb__get_delete_and_insert_queries(relation, insert_relation, delete_relation, delete_column_key) %}
    {% set query %}
        {% if delete_relation %}
            delete from {{ relation }}
            where
            {{ delete_column_key }} is null
            or {{ delete_column_key }} in (select {{ delete_column_key }} from {{ delete_relation }});
        {% endif %}
        {% if insert_relation %}
            insert into {{ relation }} select * from {{ insert_relation }};
        {% endif %}
    {% endset %}
    {% do return([query]) %}
{% endmacro %}


{# elementary/macros/utils/cross_db_utils/generate_elementary_profile_args.sql #} 
{# FIX: Duckdb arguments #}
{% macro duckdb__generate_elementary_profile_args(method, elementary_database, elementary_schema) %}
  {% do return([
    _parameter("type", target.type),
    _parameter("path", target.path),
    _parameter("schema", elementary_schema),
    _parameter("threads", target.threads),
  ]) %}
{% endmacro %}


{# elementary/macros/utils/table_operations/insert_rows.sql #} 
{# FIX: Duckdb escape single quote #}
{%- macro duckdb__escape_special_chars(string_value) -%}
    {{- return(string_value | replace("\\", "\\\\") | replace("'", "''") | replace("\n", "\\n") | replace("\r", "\\r")) -}}
{%- endmacro -%}
