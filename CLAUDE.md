# Two repos, two git workflows

**This section applies only when `$CLAUDE_CODE_REMOTE` is `'true'`** — i.e. in a
Claude Code Web / remote session. In a local session (where `CLAUDE_CODE_REMOTE`
is unset) the session-start hook does not run, there is no [src/](src/) clone,
and this whole arrangement does not apply — treat this as an ordinary repo.

In a remote session, a Claude Code Web session starts in **this** repo (the
`agents` repo, at the workspace root). The session-start hook clones the
**actual project repo** into [src/](src/) and mirrors its agent
settings/instructions back into this repo. Keep the two repos' git workflows
separate:

## This repo (`agents`, workspace root)

Holds the agent scaffolding and the mirrored settings/instructions. The
session-start hook commits the auto-merged settings and pushes them to the
project's **settings branch** — a stable per-project branch derived from the
repo name (e.g. `geowep`, or `geowep/ng` for a monorepo component), overridable
via `AGENTS_SETTINGS_BRANCH` — so they are immediately available to future
Claude Code Web sessions for this project.

## The project repo (cloned under [src/](src/))

This is the codebase we are actually coding on. Make all project code edits
here. These edits must land on a **new branch, named after this Claude Code
session** — never commit them directly to the branch the clone checked out
(e.g. `master`/`main`). Open a PR from that branch as usual.

### Azure DevOps PRs

When the repo lives on Azure DevOps (`AZURE_DEVOPS_EXT_PAT` is set), the
session-start hook installs the `az` CLI and its `azure-devops` extension **in
the background**, so they may not be ready yet early in the session. Use
`az repos pr create` to open the PR. If `az` is missing or the extension errors
out, the install is probably still running — wait a bit and retry; check
[.claude/hooks/session-start/scripts/install-az-devops.log](.claude/hooks/session-start/scripts/install-az-devops.log)
for progress. `git push` itself does not depend on `az` (it authenticates via
the PAT in the remote URL), so push first, then create the PR once `az` is up.
<!-- BEGIN MERGED AGENT INSTRUCTIONS (auto-generated, do not edit) -->

## From merkatordev/GeoWEP (root)

# GeoWEP — Claude Code Instructions

Project guidance lives in [.github/](.github/) as GitHub Copilot customisations. Treat them as authoritative for this repo.

## Core instructions

See [.github/copilot-instructions.md](.github/copilot-instructions.md) for project overview and general coding rules.

## Domain-specific instructions

Apply these when working in the relevant area:

- [.github/instructions/database-operations.instructions.md](.github/instructions/database-operations.instructions.md) — read-only PostgreSQL/PostGIS diagnostics
- [.github/instructions/docker-operations.instructions.md](.github/instructions/docker-operations.instructions.md) — Docker operational files under `docker/`
- [.github/instructions/legacy-angularjs.instructions.md](.github/instructions/legacy-angularjs.instructions.md) — legacy AngularJS app under `app/`
- [.github/instructions/postgis-migrations.instructions.md](.github/instructions/postgis-migrations.instructions.md) — PostgreSQL/PostGIS migrations

## Agents

Reusable agents for specialised tasks:

- [.github/agents/instructions-maintainer.agent.md](.github/agents/instructions-maintainer.agent.md) — keeps instruction files up to date
- [.github/agents/postgres-postgis-advisor.agent.md](.github/agents/postgres-postgis-advisor.agent.md) — PostGIS schema and query advice

## Skills

- [.github/skills/open-localhost-app/SKILL.md](.github/skills/open-localhost-app/SKILL.md) — open the app at `https://localhost:7443`

<!-- END MERGED AGENT INSTRUCTIONS -->
