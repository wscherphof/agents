---
description: >-
    Use when writing or reviewing PostgreSQL or PostGIS migrations under
    docker/postgis/conf/ddl. Covers sequential migration numbering, shell
    wrapper structure, SQL formatting expectations, and when to use the
    Postgres PostGIS Advisor agent.
name: "PostGIS Migrations"
applyTo: "docker/postgis/conf/ddl/**/*.sql, docker/postgis/conf/ddl/**/*.sh"
---

# PostGIS Migrations

- GeoWEP database migrations live in `docker/postgis/conf/ddl/` and must run
    in sequential numerical order.
- Shell wrappers for migrations follow this pattern:

```bash
#!/bin/bash
pushd schema/"$(basename "$0" .sh)" &&
    psql --set ON_ERROR_STOP=on -1 -f migration.sql &&
    popd || exit
```

- Keep PostgreSQL 16 / PostGIS 3.4 compatibility in mind when making schema
    or function changes.
- For query structure guidance, function-call help, or index suggestions,
    prefer the `Postgres PostGIS Advisor` agent.
