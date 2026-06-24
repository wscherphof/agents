# GeoWEP Workspace Instructions

GeoWEP is a GIS application undergoing migration from AngularJS 1.x to modern
Angular. Always verify which codebase you're modifying before making changes.

Folder-specific implementation guidance lives in `.github/instructions/`.
Use those scoped instruction files for framework- or folder-specific rules
instead of expanding this file.

## Instruction Files

- `database-operations.instructions.md`: read-only PostgreSQL/PostGIS
  diagnostics, table counts, and `geowep.tbl_*` core data-model checks.
- `docker-operations.instructions.md`: `docker/gw` usage, required working
  directory, local container behavior, and docker4gis base path requirements.
- `legacy-angularjs.instructions.md`: AngularJS app guidance for `app/`.
- `modern-angular.instructions.md`: modern Angular guidance for `docker/ng`
  (lives in `docker/ng/.github/instructions/`). Angular-specific agents and
  instructions are only auto-discovered when `docker/ng` is a workspace root.
  If the user asks Angular questions and `docker/ng` is not a workspace root,
  suggest they add it: **File → Add Folder to Workspace…** and select
  `docker/ng`.
- `slickgrid.instructions.md`: SlickGrid/Angular-Slickgrid integration for
  `docker/ng` — bootstrap pattern, selection model, locale requirements, grid
  architecture, regression-sensitive behaviors, and upgrade guidance (lives in
  `docker/ng/.github/instructions/`).
- `postgis-migrations.instructions.md`: SQL migration structure and conventions
  under `docker/postgis/conf/ddl`.

## Architecture

### Two Parallel Codebases

- **Legacy (Production)**: `app/` - AngularJS 1.8.3 + Vite + OpenLayers 8
- **Modern (Migration)**: `docker/ng/` - Angular standalone components + signals
  + TypeScript

Key components: Map view (OpenLayers), grid views (SlickGrid), tab system, GIS
tools (selection, measurement, point editor).

## Build and Test

### Development

```bash
# AngularJS dev server (port 5173)
cd app && npm run dev

# Modern Angular dev server
cd docker/ng && npm start

# Lint and format
npm run lint
```

## Project Conventions

- Whenever a significant project change is made, update these Copilot
  instructions if the change affects architecture, MCP tools, framework
  versions, development workflow, or other guidance future agents should know.
- Wrap text at 80 characters in Copilot customization files such as
  `copilot-instructions.md`, `*.instructions.md`, and `*.agent.md`.

### Worktree Isolation (Copilot CLI Implementations)

- Scope: this policy applies to **Copilot CLI implementation runs**.
- For Copilot CLI implementations, default mode is **worktree isolation** for
  all non-trivial coding tasks.
- Before editing code, the agent should verify whether it is already in an
  isolated feature worktree.
- If not in an isolated worktree, the agent should create one from the target
  base branch and perform all implementation there.
- The agent should avoid implementing feature work directly on shared branches
  such as `main`, `master`, `develop`, or long-lived integration branches.
- If worktree creation is blocked by environment constraints, the agent must
  stop and ask the user whether to proceed in the current tree.
- Local in-editor agent tasks are **not** required to auto-create worktrees
  unless the user explicitly requests worktree isolation.
- **Do not automatically commit changes.** After implementation, leave the
  worktree with changes staged or unstaged (not committed) so the user can
  review them as git changes before deciding whether to commit.
- Exceptions are allowed for read-only tasks (analysis, diagnostics, code
  review) and for explicit user instructions to work in-place.

### Commit Messages

- Commit messages must follow **Conventional Commits 1.0.0**.
- Use a scope for changes in `docker/`, where the scope equals the direct
  subdirectory name under `docker/` (for example: `api`, `postgis`, `proxy`,
  `ng`, `geoserver`, `mapfish`, `mapproxy`, `qgis`, `cron`, `app`).
- Example format: `fix(api): handle login popup close behavior correctly`.

### Pull Requests

- This project is hosted on **Azure DevOps** (org `merkatordev`, project
  `GeoWEP`), not GitHub — there is no `gh` CLI.
- PRs go **from a branch on your fork to `master` in the main repo** (a
  cross-repo fork PR). Push the feature branch to your fork only; do **not**
  push feature branches to the main `GeoWEP` repo.
- `az repos pr create` does **not** support fork PRs. Create the fork PR via
  the REST API by POSTing to the main repo's `pullrequests` endpoint with
  `sourceRefName`/`targetRefName` and a `forkSource.repository.id` pointing at
  your fork. Then verify the created PR's `forkSource.repository` is the fork.

### Coordinate System

Default SRID: **28992** (Rijksdriehoekstelsel - Dutch national grid)

### Naming

- Dutch business terms: `onderzoeken`, `plantekeningen`, `notities`,
  `projectkaarten`

## Testing

No automated unit tests. Quality via linting only:

```bash
npm run pretest  # ESLint + Prettier check
```

## Critical Gotchas

- **Always stop the cron container after `./gw run`**: Use `docker container
  stop geowep-cron` every time you start containers. The cron service generates
  database log errors during development and should not run in local dev
  environments.
- Always check if editing `app/` (AngularJS) or `docker/ng/` (Angular) first
- Local container names follow `$DOCKER_USER-$DOCKER_REPO`, for example:
  `geowep-postgis`, `geowep-cron`, `geowep-api`.
- During local development, PostgreSQL/PostGIS is normally running in
  `geowep-postgis`; agents may run read-only SQL diagnostics there when
  investigating issues.
- For local DB diagnostics, run `psql` inside `geowep-postgis` and rely on
  container environment variables for connection defaults (do not require
  explicit `-h`, `-p`, `-U`, or `-d` flags unless needed).

## MCP And Browser Automation

- Custom agent available in `.github/agents/instructions-maintainer.agent.md`:
  use `Instructions Maintainer` when project changes should be reflected in
  shared guidance such as `copilot-instructions.md` or related customization
  files.
- Local MCP server source lives in `mcp/` and is named `geowep-local-tools`.
- Current local MCP tools:
  - `echo`: simple connectivity/smoke-test tool that returns the provided text.
- MCP runtime prerequisites for local tools:
  - `WORKSPACE_FOLDER` must be configured in `.vscode/mcp.json`.
- MCP tool shell/network calls should use explicit timeouts where possible; do
  not add new MCP commands that can block indefinitely.
- MCP tools should prepare state and return data (for example: start servers,
  resolve URLs, check environment), but they cannot directly control VS Code
  integrated browser tabs/windows.
- When investigation benefits from live database state, the Copilot agent may
  execute read-only SQL queries in `geowep-postgis` and report the results.
- When a flow requires browser actions (open/reuse tab, navigate, click, close),
  the Copilot agent must execute those actions using browser tools, instead of
  only returning instructions to the user.
- For local dev, enable VS Code setting `Workbench > Browser: Open Localhost
  Links` so localhost links from terminal/chat open in the integrated browser
  that can be shared with Copilot.
- Workspace skill `.github/skills/open-localhost-app/SKILL.md` provides a
  reusable flow to open `https://localhost:7443` in the integrated browser and
  return immediately without certificate interaction.
