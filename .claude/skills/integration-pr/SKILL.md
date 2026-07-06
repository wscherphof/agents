---
name: integration-pr
description: >-
  Open a pull request that merges the project's integration branch into
  main/master, with a description that rolls up and links each earlier PR the
  integration branch comprises. Use when the user wants to create the
  integration / release PR (e.g. "PR to merge develop into main", "open the
  integration PR"). Only applies in a remote project session where
  AGENTS_INTEGRATION_BRANCH is configured.
---

# Create the integration PR

Open a single PR that merges the **integration branch** into the project's
**default branch** (main/master). Its description explains that the PR rolls up
several feature PRs already reviewed and merged into the integration branch, and
lists each of them as a link. Finish by outputting the new PR's URL so the user
can click to open it.

Do everything in the **cloned project repo** (`src/<AGENTS_GIT_REPO>[/…]`), not
the agents workspace. This skill only makes sense in a remote project session
(see the agents-repo `CLAUDE.md`, "Two repos, two git workflows").

## 1. Resolve the branches and project dir

Read from [conf/.env](conf/.env):

- `AGENTS_GIT_REPO` (+ `AGENTS_COMPONENT_DIR` if set) → project dir
  `src/<AGENTS_GIT_REPO>[/<AGENTS_COMPONENT_DIR>]`. Note the **repo root** is
  `src/<AGENTS_GIT_REPO>` even when a component dir is set — git operations run
  at the repo root.
- `AGENTS_INTEGRATION_BRANCH` → the integration branch to merge **from**.

**If `AGENTS_INTEGRATION_BRANCH` is blank, stop** and tell the user: there is no
integration branch configured for this project, so there is nothing to roll up —
regular feature PRs already target the default branch.

Resolve the **target** (default) branch of the project repo:

```bash
PROJ=src/<AGENTS_GIT_REPO>
git -C "$PROJ" fetch origin --prune
git -C "$PROJ" remote set-head origin -a >/dev/null 2>&1 || true
TARGET=$(git -C "$PROJ" symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')
INTEGRATION=<AGENTS_INTEGRATION_BRANCH>
```

Sanity-check that `origin/$INTEGRATION` is actually ahead of `origin/$TARGET`:

```bash
git -C "$PROJ" rev-list --count "origin/$TARGET..origin/$INTEGRATION"
```

If that count is `0`, the integration branch has nothing beyond the target —
stop and report it (nothing to merge).

## 2. Bring the target branch into the integration branch

Before opening the PR, make sure the integration branch already contains
everything on the target. Then the PR's diff is exactly the integration work,
and any conflicts get resolved as a visible commit **on the branch** (where a
reviewer sees them) rather than surfacing when someone clicks "merge".

Check whether the target is ahead of the integration branch:

```bash
git -C "$PROJ" rev-list --count "origin/$INTEGRATION..origin/$TARGET"
```

If that count is `0`, the integration branch already contains all of the target
— skip to the next step. Otherwise merge the target in and push it (the PR
merges `origin/$INTEGRATION`, so the sync only counts once it's pushed):

```bash
git -C "$PROJ" checkout "$INTEGRATION"
git -C "$PROJ" pull --ff-only origin "$INTEGRATION"
git -C "$PROJ" merge --no-edit "origin/$TARGET"
git -C "$PROJ" push origin "$INTEGRATION"
git -C "$PROJ" fetch origin --prune        # refresh origin/* for the steps below
```

**If the merge reports conflicts, stop.** Don't resolve them blind or force the
PR through. Run `git -C "$PROJ" merge --abort`, tell the user which files
conflict, and let them resolve the sync merge (or do it together) before
re-running the skill. The PR must merge cleanly.

The sync merge commit carries no PR reference, so it won't be mistaken for a
constituent PR in the next step.

## 3. Collect the constituent PRs

Run the helper (it detects the host and emits host-prefixed refs, oldest first):

```bash
"$CLAUDE_PROJECT_DIR/.claude/skills/integration-pr/list-constituent-prs.sh" \
  "$PROJ" "$TARGET" "$INTEGRATION"
```

It prints one ref per line — `#123` on GitHub, `!123` on Azure DevOps — derived
from the merge/squash commit messages in `origin/$TARGET..origin/$INTEGRATION`.
Keep the order; it is chronological and makes the description read as a story.

**Fallback if it prints nothing** (unusual merge messages, or commits landed
without PRs): don't guess. List PRs the platform records as merged into the
integration branch and keep those whose merge commit is in range.

- GitHub: `gh pr list --repo <account>/<repo> --base "$INTEGRATION" --state merged --json number,title,mergedAt --limit 200`
- Azure DevOps: `az repos pr list --repository <repo> --target-branch "$INTEGRATION" --status completed --output json`

Cross-check each against `git -C "$PROJ" log origin/$TARGET..origin/$INTEGRATION`
so you only include PRs not already in the target. If you still can't determine
the list, say so plainly in the description rather than inventing numbers.

## 4. Don't create a duplicate

An integration PR from `$INTEGRATION` → `$TARGET` may already be open. Check
first; if one exists, **update its description** (below) instead of opening a
second, and output its URL.

- GitHub: `gh pr list --repo <account>/<repo> --base "$TARGET" --head "$INTEGRATION" --state open --json number,url`
- Azure DevOps: `az repos pr list --repository <repo> --source-branch "$INTEGRATION" --target-branch "$TARGET" --status active --output json`

## 5. Build the description

Reference each constituent PR by its **bare ref** (`#123` / `!123`) — the host
renders it as a full link including the PR's type and title, so you don't hand-
build titles. On Azure DevOps use `!` for PRs (never `#`, which points at a work
item). Template:

```markdown
Merges the `<INTEGRATION>` integration branch into `<TARGET>`.

It rolls up the following PRs, each already reviewed and merged into
`<INTEGRATION>`:

- !123
- !124
- !125
```

(Use `#123` etc. on GitHub.) Write the body to a temp file in the scratchpad so
you can pass it with `--body-file` / `--description`.

## 6. Create (or update) the PR

The integration branch already exists on the remote, so no feature branch or
push is needed — create the PR directly.

- **GitHub:**
  ```bash
  gh pr create --repo <account>/<repo> \
    --base "$TARGET" --head "$INTEGRATION" \
    --title "Merge $INTEGRATION into $TARGET" \
    --body-file <scratchpad>/integration-pr-body.md
  ```
  `gh pr create` prints the PR URL on stdout. To update an existing one:
  `gh pr edit <number> --repo <account>/<repo> --body-file <file>`.

- **Azure DevOps** (needs the `az` CLI + `azure-devops` extension the hook
  installs in the background — if `az` errors, wait and retry; see
  [.claude/hooks/session-start/scripts/install-az-devops.log](.claude/hooks/session-start/scripts/install-az-devops.log)):
  ```bash
  az repos pr create --repository <repo> \
    --source-branch "$INTEGRATION" --target-branch "$TARGET" \
    --title "Merge $INTEGRATION into $TARGET" \
    --description @<scratchpad>/integration-pr-body.md
  ```
  To update an existing one: `az repos pr update --id <pr-id> --description @<file>`.

Keep the title short but meaningful; adapt it if the user gave a release name or
similar.

## 7. Output the PR URL

End by giving the user a **clickable link to the integration PR** so they can
open it in the browser. Use `srclink` with the new PR's number (it's on PATH and
builds a correct GitHub/ADO URL from the project repo's origin — run it from the
project dir):

```bash
( cd "$PROJ" && srclink '!<new-pr-id>' "the integration PR" )   # ADO
( cd "$PROJ" && srclink '#<new-pr-id>' "the integration PR" )   # GitHub
```

Present that link as the final result. If `srclink` is unavailable, fall back to
the raw URL that `gh pr create` printed (GitHub) or build the ADO URL by hand per
the agents-repo `CLAUDE.md` ("Linking to issues, work items, and PRs").
