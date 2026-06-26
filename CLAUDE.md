Per-project agent instructions for this settings branch live in
[conf/CLAUDE.md](conf/CLAUDE.md) and are imported here:

@conf/CLAUDE.md

# Two repos, two git workflows

**This file applies only when both of these hold:** `$CLAUDE_CODE_REMOTE` is
`'true'`, **and** the `AGENTS_GIT_REPO=` assignment in
[conf/.env](conf/.env) is non-empty (the `# e.g. …` example comments don't
count). Concretely:

- **Locally** (`CLAUDE_CODE_REMOTE` unset): the session-start hook never runs,
  there is no [src/](src/) clone — treat this as an ordinary repo and ignore
  everything below.
- **On the template branch** (`main`), where `AGENTS_GIT_ACCOUNT`/
  `AGENTS_GIT_REPO` are blank: no project is configured, so the session is for
  evolving the agents scaffolding itself. The two-repos workflow below does not
  apply.
- **When `AGENTS_GIT_REPO` is set** (a per-project settings branch such as
  `geowep/ng`, run remotely): the hook clones the project into [src/](src/) and
  everything below is in effect.

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
here.

**Operate as if the session had launched from the project directory.** Treat
`src/<AGENTS_GIT_REPO>/<AGENTS_COMPONENT_DIR>` as your effective working
directory and run all project commands, searches, edits, and git operations
from there by default. Resolve the path by reading the values from
[conf/.env](conf/.env): `AGENTS_GIT_REPO` (mandatory) gives
`src/<AGENTS_GIT_REPO>`, and if
`AGENTS_COMPONENT_DIR` is set non-empty, append it. Don't rely on
`$AGENTS_COMPONENT_DIR` being in the environment — the hook exports it only
inside a subshell, so it isn't visible to the session. For example, with
`AGENTS_GIT_REPO=GeoWEP` and `AGENTS_COMPONENT_DIR=components/geowep-ng`, the
effective directory is `src/GeoWEP/components/geowep-ng`; with no component set,
it's `src/GeoWEP`.

Switch back to the `agents` repo at the workspace root only for the agent
scaffolding and settings-branch git workflow described above; all other work
happens in the project directory.

Because the remote session runs in an ephemeral container that is discarded
when the session ends, **only pushed commits survive** — a local commit that is
never pushed is lost (Claude Code Web does not auto-push; each session is a
fresh clone from the remote). Always push after committing.

There are two common routes:

- **Starting fresh work.** The edits must land on a **new branch, named after
  this Claude Code session** — never commit them directly to the branch the
  clone checked out (e.g. `master`/`main`). Open a PR from that branch as usual.
- **Continuing work on an existing feature branch.** Just as common: a new
  session is started to pick up an existing branch. In that case **check out
  that branch** (do not create a new one), and commit and push directly to it.
  There may already be a PR for the branch — if so, **never suggest creating a
  new PR**; a `git push` simply adds the new commits to the existing PR.

### Azure DevOps PRs

When the repo lives on Azure DevOps (`AZURE_DEVOPS_EXT_PAT` is set), the
session-start hook installs the `az` CLI and its `azure-devops` extension **in
the background**, so they may not be ready yet early in the session. Use
`az repos pr create` to open the PR. If `az` is missing or the extension errors
out, the install is probably still running — wait a bit and retry; check
[.claude/hooks/session-start/scripts/install-az-devops.log](.claude/hooks/session-start/scripts/install-az-devops.log)
for progress. `git push` itself does not depend on `az` (it authenticates via
the PAT in the remote URL), so push first, then create the PR once `az` is up.

The project repo's own agent instructions, mirrored in by the session-start
hook, are imported here:

@.claude/merged-agent-instructions.md
