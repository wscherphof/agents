---
description: >-
  Use when running read-only PostgreSQL/PostGIS diagnostics in local
  development, including table counts and core data-model checks for
  geowep.tbl_* relations.
name: "Database Operations"
applyTo: "docker/**/*.sql, docker/**/*.sh, docker/gw"
---

# Database Operations

- During local development, PostgreSQL/PostGIS is normally running in
  `geowep-postgis` and can be queried for diagnostics.
- Prefer running `psql` inside `geowep-postgis` and use container environment
  variables for connection defaults instead of passing explicit parameters.
- Diagnostics must be read-only unless the user explicitly asks for writes.

- Common read-only probes:

```bash
# Verify DB/session context
docker exec geowep-postgis sh -lc 'psql -Atqc "select now(), current_database(), current_user;"'

# List core data-model tables (`geowep.tbl_*`)
docker exec geowep-postgis psql -Atqc "select table_name from information_schema.tables where table_schema = 'geowep' and table_type = 'BASE TABLE' and table_name like 'tbl\\_%' escape '\\' order by table_name;"

# Example count probe
docker exec geowep-postgis sh -lc 'psql -Atqc "select count(*) from geowep.tbl_onderzoek_base;"'
```

- Core data-model tables are the `geowep.tbl_*` base tables. Current set:
  - `geowep.tbl_aankoop`
  - `geowep.tbl_features`
  - `geowep.tbl_logboek`
  - `geowep.tbl_onderzoek_base`
  - `geowep.tbl_onderzoekstatus`
  - `geowep.tbl_plantekening`
  - `geowep.tbl_print`
  - `geowep.tbl_spatial_ref_sys`
  - `geowep.tbl_subproject`
  - `geowep.tbl_xymeting`
  - `geowep.tbl_zmeting`

- Refresh the table list with the information_schema query above whenever
  `geowep.tbl_*` tables are added or removed.
