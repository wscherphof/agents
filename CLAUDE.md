Per-project agent instructions for this settings branch live in
[conf/CLAUDE.md](conf/CLAUDE.md) and are imported here:

@conf/CLAUDE.md

# Two repos, two git workflows

**This file applies only when both of these hold:** `$CLAUDE_CODE_REMOTE` is
`'true'`, **and** the `AGENTS_GIT_REPO=` assignment in [conf/.env](conf/.env) is
non-empty (the `# e.g. …` example comments don't count). Concretely:

- **Locally** (`CLAUDE_CODE_REMOTE` unset): the session-start hook never runs,
  there is no [src/](src/) clone — treat this as an ordinary repo and ignore
  everything below.
- **On the template branch** (`main`), where `AGENTS_GIT_ACCOUNT`/
  `AGENTS_GIT_REPO` are blank: no project is configured, so the session is for
  evolving the agents scaffolding itself. The two-repos workflow below does not
  apply. **Whenever you push scaffolding commits to `main`, ask the dev whether
  to propagate them to all the per-project/component settings branches** (every
  local/remote branch other than `main` — e.g. `geowep`, `geowep-ng`). If they
  confirm, cherry-pick the new commits onto each branch and push both the local
  branch and its remote. Just ask once per push; don't propagate silently.
- **When `AGENTS_GIT_REPO` is set** (a per-project settings branch such as
  `geowep-ng`, run remotely): the hook clones the project into [src/](src/) and
  everything below is in effect.

In a remote session, a Claude Code Web session starts in **this** repo (the
`agents` repo, at the workspace root). The session-start hook clones the
**actual project repo** into [src/](src/) and mirrors its agent
settings/instructions back into this repo. Keep the two repos' git workflows
separate:

## Naming the session

The session name should be **prefixed with the project — `<project>` when no
component is configured, or `<project>-<component>` when one is** (e.g. `geowep`
or `geowep-ng`). This is exactly the agents repo branch we started from (the
project's settings branch), so you can read it off `git rev-parse --abbrev-ref
HEAD` at the workspace root — but the rule is the prefix **is** project or
project-component, full stop; don't drop the project or shorten it to just the
component. So a session whose auto-generated name is `settings merge in start
session hook` should become `geowep-ng: settings merge in start session hook`.
This makes it obvious at a glance, in the Recents list, which project (and
component) each session is working on.

**Note the contrast with the feature-branch prefix** (see "Starting fresh work"
below): the session prefix keeps the project name (`geowep-ng: …`), whereas the
feature branch under `claude/` drops it and keeps only the component (`claude/ng-…`).
Same component, different prefix — don't conflate the two.

**You cannot rename the session yourself** — there is no tool for it, and by the
time you read this the platform has already auto-named the session from the
first prompt. Only the user can rename it (the `/rename` command), so the prefix
won't appear unless you prompt them. Therefore, **this must be among the very
first things you do in a remote project session — emit the rename suggestion
before you start on the actual work**, so the session is properly named while it
runs (the user relies on the Recents list to tell running sessions apart). Don't
finish the task and then suggest it. Proactively emit, for the user to run, a
single ready-to-paste line of the form

```
/rename geowep-ng: <short description of this session's work>
```

i.e. the project prefix, then `: `, then a concise description. You don't have
access to the platform's auto-generated session name, so derive the description
from the first prompt / the work at hand (a handful of words); the user can keep
their own wording if they prefer. Do this once, near the start — don't nag on
later turns. If the first prompt shows the session name is already prefixed
(e.g. a resumed session), say nothing.

**When the initial prompt names a work item (Azure DevOps) or issue (GitHub)
number, follow that instead** of an invented description: after the project
prefix and `: `, put the work item type (`Bug`/`Task`/`Support`/…), the number,
and the work item / issue title, space-separated. So the line becomes

```
/rename geowep-ng: <work item type> <work item number> <work item title>
```

e.g. `/rename geowep-ng: Bug 1234 Fix login redirect loop`. Look up the type and
title from the tracker (`az boards work-item show --id <n>` on Azure DevOps, `gh
issue view <n>` on GitHub) rather than guessing them; fall back to a short
description of the work only if the number can't be resolved.

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
directory and run all project commands, searches, edits, and git operations from
there by default. Resolve the path by reading the values from
[conf/.env](conf/.env): `AGENTS_GIT_REPO` (mandatory) gives
`src/<AGENTS_GIT_REPO>`, and if `AGENTS_COMPONENT_DIR` is set non-empty, append
it. Don't rely on `$AGENTS_COMPONENT_DIR` being in the environment — the hook
exports it only inside a subshell, so it isn't visible to the session. For
example, with `AGENTS_GIT_REPO=GeoWEP` and
`AGENTS_COMPONENT_DIR=components/geowep-ng`, the effective directory is
`src/GeoWEP/components/geowep-ng`; with no component set, it's `src/GeoWEP`.

Switch back to the `agents` repo at the workspace root only for the agent
scaffolding and settings-branch git workflow described above; all other work
happens in the project directory.

Because the remote session runs in an ephemeral container that is discarded when
the session ends, **only pushed commits survive** — each session is a fresh
clone from the remote, so don't rely on a local commit persisting on its own.
Always push after committing. And commit **eagerly** — at each meaningful
checkpoint, not just at session end — then push: anything left uncommitted (or
committed but unpushed) is lost if the container is discarded mid-session, so
frequent commit-and-push is what keeps your work recoverable. (Claude Code Web
_may_ persist a session's commits at session end by pushing them to a
`claude/<session>` branch, but treat that as a backstop you don't control, not
the intended path — push deliberately to the branch you mean.)

There are two common routes:

- **Starting fresh work.** The edits must land on a **new branch, named after
  this Claude Code session** — never commit them directly to the branch the
  clone checked out (e.g. `master`/`main`). Open a PR from that branch as usual.
  **Always keep the `claude/` prefix at the very start of the branch name** — it
  marks the branch as agent-authored and keeps Claude Code Web's own
  `claude/<session>` backstop namespace consistent. Don't prefix the branch with
  the project name (the branch already lives in that repo), but after `claude/`
  **do** prefix it with the `<component>` when a component is configured (the
  same prefix the agents repo's settings branch uses, e.g. `ng`) so a monorepo
  component's feature branches are easy to spot amidst feature branches of other
  components. The branch name mirrors the session name (see "Naming the
  session"), joined with `-` rather than `: `/spaces — so when the initial
  prompt names a work item / issue:

  ```
  claude/ng-<work item type>-<work item number>-<work item title>
  ```

  e.g. `claude/ng-Bug-1234-fix-login-redirect-loop`; otherwise:

  ```
  claude/ng-<short description of this session's work>
  ```

  e.g. `claude/ng-add-login`. (Drop the component prefix — the `ng-` segment,
  not the `claude/` prefix — when no component is configured, e.g.
  `claude/add-login`.)

- **Continuing work on an existing feature branch.** Just as common: a new
  session is started to pick up an existing branch. In that case **check out
  that branch** (do not create a new one), and commit and push directly to it.
  There may already be a PR for the branch — if so, **never suggest creating a
  new PR**; a `git push` simply adds the new commits to the existing PR.

In **either** route, once implementation on the feature branch is done — and
committed and pushed — **a PR should exist**. If there isn't one yet, create it
(this is the normal end state for fresh work, and also covers an existing branch
that was never given a PR). If a PR already exists, don't create another; the
push you just did already updated it. So: finish the work, commit, push, then
ensure a PR is open for the branch.

**PR target branch.** Read `AGENTS_INTEGRATION_BRANCH` from
[conf/.env](conf/.env). If it is **blank**, target the PR at the checked-out
default branch (`main`/`master`) as usual. If it is **set**, and that branch
exists in the project repo, **target the PR at it** instead. Check with e.g.
`git -C src/<AGENTS_GIT_REPO> ls-remote --heads origin <branch>` (or `git branch
-a`); if it exists, pass it as the PR's target (`--base <branch>` on GitHub,
`--target-branch <branch>` on Azure DevOps). Otherwise (variable unset, or the
named branch doesn't exist) target the default branch.

### Linking to project source files

The harness's default guidance is to render file references as Markdown links
whose URL is a path **relative to the workspace root**. That is correct for
files in the `agents` repo itself (e.g. [conf/.env](conf/.env)), but **wrong for
project source files**: the workspace root is the `agents` repo, `/src/` is
gitignored there, so a relative link like `src/<repo>/foo.ts` resolves against
the `agents` repo and 404s in Claude Code Web — the file isn't part of that
repo.

The trap is that you are told to **operate as if launched from the project
directory** and to refer to project files by their working-dir-relative path
(e.g. `docker/ng/CODE-REVIEW.md`, not `src/GeoWEP/docker/ng/CODE-REVIEW.md`). So
when you mention such a file, the default kicks in and renders that bare path as
a link relative to the `agents` workspace root — a broken link. **Any time you
link a file you edited/created/read in the project repo, this rule applies**,
even though its path doesn't visibly start with `src/`.

**Use the `srclink` helper — don't hand-build the URL.** The session-start hook
puts it on PATH (it's [tools/srclink.sh](tools/srclink.sh)). Run it from the
project working dir and pass the same path you'd `cat`/`ls`; it derives the
host/account/repo/branch from the project repo's own checkout and prints a
ready-to-paste Markdown link (PAT stripped, path URL-encoded). (It also builds
issue/work-item/PR links — see "Linking to issues, work items, and PRs" below.)

```
srclink docker/ng/CODE-REVIEW.md                 # whole file
srclink src/app/foo.ts:42                         # one line
srclink src/app/foo.ts:42-50 "the bug"            # line range + custom text
```

It refuses paths that aren't under the cloned project repo, so an `agents`-repo
file (use a normal workspace-relative link for those) won't slip through.

If for some reason `srclink` isn't available, **override the default and emit a
full web URL into the project repo's remote** by hand instead of a
workspace-relative path. Build it from the values in [conf/.env](conf/.env):

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

### Linking to issues, work items, and PRs

The same workspace-root trap applies to **issue / work-item / pull-request
references**, and worse: a bare `#123` or `!123` auto-links against the
**workspace root — the `agents` repo**, so it points at (or 404s on) the wrong
repo entirely. These references belong to the **project repo**, so their links
must resolve on the project repo's host.

**Always render such references as clickable Markdown links** — never leave a
bare `#123` / `!123` in your output. Any time you mention an issue, work item,
or PR of the project, emit it as a link the user can click to open it.

**Use the same `srclink` helper** — it also does references (run it from the
project working dir). It uses the CLAUDE.md prefix convention: `#` = issue /
work item, `!` = pull request.

```
srclink '#123'                 # issue / work item link into the project repo
srclink '!456' "the PR"        # pull request link into the project repo
```

(Quote the argument so the shell doesn't treat `#` as a comment.) It derives the
host/account/repo from the project repo's own origin, so the links are correct
for GitHub **and** Azure DevOps automatically.

If `srclink` isn't available, build the URL by hand against the **project
repo's** remote (account/repo from [conf/.env](conf/.env), never the `agents`
repo, PAT never rendered):

- **GitHub:** issue → `https://github.com/<account>/<repo>/issues/<n>`; PR →
  `https://github.com/<account>/<repo>/pull/<n>` (GitHub cross-redirects the
  two, so either resolves).
- **Azure DevOps:** work item →
  `https://dev.azure.com/<org>/_workitems/edit/<n>` (work-item IDs are unique
  org-wide, so no project segment is needed); PR →
  `https://dev.azure.com/<account>/_git/<repo>/pullrequest/<n>` (`<account>` is
  the same `<org>`-or-`<org>/<project>` segment used for file links above).

### Azure DevOps PRs

When the repo lives on Azure DevOps (`AZURE_DEVOPS_EXT_PAT` is set), the
session-start hook installs the `az` CLI and its `azure-devops` extension **in
the background**, so they may not be ready yet early in the session. Use `az
repos pr create` to open the PR. If `az` is missing or the extension errors out,
the install is probably still running — wait a bit and retry; check
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
`#123` are different objects. When writing PR references, always use `!<number>`
— never `#<number>`, which renders a short link to a (possibly non-existent)
work item rather than the PR. When rendering either as a clickable link, use
`srclink '!<n>'` / `srclink '#<n>'` so it points at the project repo (see
"Linking to issues, work items, and PRs" above).

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
