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
  `geowep-ng`, run remotely): the hook clones the project into [src/](src/) and
  everything below is in effect.

In a remote session, a Claude Code Web session starts in **this** repo (the
`agents` repo, at the workspace root). The session-start hook clones the
**actual project repo** into [src/](src/) and mirrors its agent
settings/instructions back into this repo. Keep the two repos' git workflows
separate:

## Naming the session

Prefix this Claude Code session's name with the **agents repo branch we started
from** — the project's settings branch, which is `<repo>` or `<repo>-<component>`
(get it with `git rev-parse --abbrev-ref HEAD` at the workspace root; e.g.
`geowep` or `geowep-ng`). So a session about merging settings becomes
`geowep-ng: settings merge in start session hook`. This makes it obvious at a
glance, in the Recents list, which project (and component) each session is
working on.

## This repo (`agents`, workspace root)

Holds the agent scaffolding and the mirrored settings/instructions. The
session-start hook commits the auto-merged settings and pushes them to the
project's **settings branch** — a stable per-project branch derived from the
repo name (e.g. `geowep`, or `geowep-ng` for a monorepo component), overridable
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
when the session ends, **only pushed commits survive** — each session is a fresh
clone from the remote, so don't rely on a local commit persisting on its own.
Always push after committing. And commit **eagerly** — at each meaningful
checkpoint, not just at session end — then push: anything left uncommitted (or
committed but unpushed) is lost if the container is discarded mid-session, so
frequent commit-and-push is what keeps your work recoverable. (Claude Code Web
*may* persist a session's commits at session end by pushing them to a
`claude/<session>` branch, but treat that as a backstop you don't control, not
the intended path — push deliberately to the branch you mean.)

There are two common routes:

- **Starting fresh work.** The edits must land on a **new branch, named after
  this Claude Code session** — never commit them directly to the branch the
  clone checked out (e.g. `master`/`main`). Open a PR from that branch as usual.
  Don't prefix the branch with the project name (the branch already lives in
  that repo), but **do** prefix it with the `<component>` when a component is
  configured (the same `-<component>` suffix the settings branch uses, e.g.
  `geowep-ng-add-login`) so a monorepo component's branches are easy to spot.
- **Continuing work on an existing feature branch.** Just as common: a new
  session is started to pick up an existing branch. In that case **check out
  that branch** (do not create a new one), and commit and push directly to it.
  There may already be a PR for the branch — if so, **never suggest creating a
  new PR**; a `git push` simply adds the new commits to the existing PR.

### Linking to project source files

The harness's default guidance is to render file references as Markdown links
whose URL is a path **relative to the workspace root**. That is correct for
files in the `agents` repo itself (e.g. [conf/.env](conf/.env)), but **wrong for
project source files**: the workspace root is the `agents` repo, `/src/` is
gitignored there, so a relative link like `src/<repo>/foo.ts` resolves against
the `agents` repo and 404s in Claude Code Web — the file isn't part of that
repo.

So for any file under `src/<AGENTS_GIT_REPO>/…` (the cloned project repo),
**override the default and emit a full web URL into the project repo's remote**
instead of a workspace-relative path. Build it from the values in
[conf/.env](conf/.env):

- **Branch (`<branch>`):** the branch currently checked out in the project repo
  — `git -C src/<AGENTS_GIT_REPO> rev-parse --abbrev-ref HEAD`. (The link only
  resolves on the remote once that branch — and the file — has been pushed; a
  file you just created links cleanly only after the push.)
- **Repo-relative path (`<path>`):** the file path with the
  `src/<AGENTS_GIT_REPO>/` prefix stripped (so a component dir stays in the
  path). URL-encode it (spaces → `%20`); leave the `/` separators as-is.
- Never put the PAT in a rendered URL.

URL format depends on the host:

- **Azure DevOps** (`AZURE_DEVOPS_EXT_PAT` set):
  `https://dev.azure.com/<AGENTS_GIT_ACCOUNT>/_git/<AGENTS_GIT_REPO>?path=/<path>&version=GB<branch>`
  — append `&line=<n>&lineEnd=<n>&lineStartColumn=1&lineEndColumn=1` to anchor a
  line (`GB` = git branch; the leading `/` on `path` is required).
- **GitHub** (`GITHUB_PERSONAL_ACCESS_TOKEN` set):
  `https://github.com/<AGENTS_GIT_ACCOUNT>/<AGENTS_GIT_REPO>/blob/<branch>/<path>`
  — append `#L<n>` (or `#L<n>-L<m>`) to anchor lines.

Example, with `AGENTS_GIT_ACCOUNT=merkatordev`, `AGENTS_GIT_REPO=GeoWEP`,
`AGENTS_COMPONENT_DIR=components/geowep-ng`, the branch `my-session-branch`
checked out, referencing line 42 of `src/GeoWEP/components/geowep-ng/app.ts` on
Azure DevOps:
`https://dev.azure.com/merkatordev/_git/GeoWEP?path=/components/geowep-ng/app.ts&version=GBmy-session-branch&line=42&lineEnd=42&lineStartColumn=1&lineEndColumn=1`

### Azure DevOps PRs

When the repo lives on Azure DevOps (`AZURE_DEVOPS_EXT_PAT` is set), the
session-start hook installs the `az` CLI and its `azure-devops` extension **in
the background**, so they may not be ready yet early in the session. Use
`az repos pr create` to open the PR. If `az` is missing or the extension errors
out, the install is probably still running — wait a bit and retry; check
[.claude/hooks/session-start/scripts/install-az-devops.log](.claude/hooks/session-start/scripts/install-az-devops.log)
for progress. `git push` itself does not depend on `az` (it authenticates via
the PAT in the remote URL), so push first, then create the PR once `az` is up.

When the session prompt mentions a specific work item (e.g. `#123`) and you
create a PR, **link that work item to the PR automatically** — pass
`--work-items <id>` to `az repos pr create` (or run `az repos pr work-item add
--id <pr-id> --work-items <id>` on an already-created PR). Just mention that
you've linked it; don't ask whether the link is wanted.

On Azure DevOps, **pull requests are referenced with a `!`-prefix** (e.g.
`!123`), while **work items** (issues, features, bugs, tasks) use a `#`-prefix
(e.g. `#123`) as on GitHub. These are separate number spaces, so `!123` and
`#123` are different objects. When writing PR references, always use
`!<number>` — never `#<number>`, which renders a short link to a (possibly
non-existent) work item rather than the PR.

### Docker

When `AGENTS_START_DOCKER=true` in [conf/.env](conf/.env), the session-start
hook starts the Docker daemon **in the background** (the container image must
already have Docker installed). Like the Azure CLI install, it may not be ready
the instant the session begins — if a `docker` command reports the daemon isn't
running, wait a moment and retry, and check
[.claude/hooks/session-start/scripts/start-docker.log](.claude/hooks/session-start/scripts/start-docker.log)
for progress.

The project repo's own agent instructions, mirrored in by the session-start
hook, are imported here:

@.claude/merged-agent-instructions.md
