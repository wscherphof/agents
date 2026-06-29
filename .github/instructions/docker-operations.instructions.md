---
description: >-
  Use when working on Docker operational files in docker/. Covers gw usage,
  required working directory, local development container behavior, and
  docker4gis base path requirements.
name: "Docker Operations"
applyTo: "docker/gw, docker/**/*.sh, docker/**/Dockerfile"
---

# Docker Operations

- Run `./gw` commands from the `docker/` directory.
- Container names follow `$DOCKER_USER-$DOCKER_REPO` (for example:
  `geowep-postgis`, `geowep-cron`, `geowep-api`).
- Common commands:

```bash
./gw build postgis
./gw run; docker container stop geowep-cron
./gw br postgis; docker container stop geowep-cron
./gw push postgis 2905
./gw stop
```

- Local development requires `$DOCKER_BASE` to point to `docker4gis/base`.
- Services include `postgis`, `api`, `app`, `ng`, `geoserver`, `proxy`,
	`mapfish`, `mapproxy`, and `qgis`.
- For local DB diagnostics and table-level checks, see
  `.github/instructions/database-operations.instructions.md`.
- Always stop the `geowep-cron` container after `./gw run` in local
	development to avoid noisy database log errors.
