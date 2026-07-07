---
name: commit-push-propagate
description: >-
  Commit the working changes on the current agents-repo branch, push them, then
  propagate them to the downstream settings branches by cherry-pick. Two modes:
  on the `main` template branch it propagates to every per-project/component
  settings branch; on a project settings branch (e.g. `geowep`) it propagates to
  that project's component settings branches (e.g. `geowep-ng`). Use when the
  user says "commit, push, propagate" (or similar) while evolving the agents
  scaffolding itself. ONLY applies in a local agents-repo session — not in a
  remote/ephemeral `claude/*` session.
---

# Commit, push, propagate scaffolding changes

Encodes the propagation workflow from the agents-repo `CLAUDE.md` ("Two repos,
two git workflows"): a change is committed on the current branch, pushed, and
then replayed onto each downstream settings branch so those branches pick it up.

There are **two modes**, decided by the branch you're on:

- **Template mode** — on the `main`/`master` template branch (blank
  `AGENTS_GIT_REPO`). Propagate to **every** per-project/component settings
  branch, so every project picks the change up.
- **Project mode** — on a project settings branch such as `geowep`
  (`AGENTS_GIT_REPO` set). Propagate to **that project's component settings
  branches** — the branches named `<current>-*` (e.g. `geowep-ng`) — and to
  nothing else.

Both modes share the same mechanics; only the source branch and the set of
target branches differ.

## 1. Guard: which mode are we in?

Determine the source branch, then classify:

```bash
SRC=$(git rev-parse --abbrev-ref HEAD)
grep -E '^AGENTS_GIT_REPO=' conf/.env           # blank on main; set on a project branch
```

- **Refuse** if this is a remote/ephemeral session — `CLAUDE_CODE_REMOTE` is
  `true`, or `SRC` matches `claude/*`. There the settings-branch workflow is the
  session-start hook's job, and the checked-out branch is ephemeral. Tell the
  user this skill is only for local agents-repo scaffolding work and stop.
- If `SRC` is `main`/`master` → **template mode** (source = `main`, targets =
  all settings branches).
- Otherwise `SRC` is a project settings branch → **project mode** (source =
  `SRC`, targets = the `<SRC>-*` component branches).

If in doubt whether the current non-`main` branch really is a project settings
branch, sanity-check that `AGENTS_GIT_REPO` in `conf/.env` is set and its
lowercased value matches `SRC` (or `SRC` starts with it). If it doesn't look
like a settings branch at all (a random feature branch), stop and ask.

## 2. Commit the working changes

If there's nothing to commit and `origin/$SRC..HEAD` is also empty, stop —
there's nothing to push or propagate.

Otherwise stage and commit whatever is pending. Write a conventional-commit
message (`docs:`/`feat:`/`fix:`/… matching the repo's style — see `git log`),
derived from the actual diff, and end it with the co-author trailer this repo
uses:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

If the user already committed and only wants the push+propagate, skip the commit
and proceed. Multiple pending commits are fine — the whole `origin/$SRC..HEAD`
range gets propagated.

## 3. Push the source branch

Capture the range to propagate **before** pushing, then push:

```bash
RANGE=$(git rev-list --reverse origin/"$SRC"..HEAD)   # oldest-first SHAs, the new commits
git push origin "$SRC"
```

`$RANGE` is exactly the set of new commits to replay onto each target branch,
oldest first (order matters for clean cherry-picks).

## 4. Determine the target branches

```bash
git fetch origin --prune
```

**Template mode** — every branch on `origin` **except** `main`/`master`,
`origin/HEAD`, and the `claude/*` session backstop branches (those aren't
settings branches):

```bash
git for-each-ref --format='%(refname:short)' refs/remotes/origin \
  | sed 's#^origin/##' \
  | grep -vE '^(HEAD|origin|main|master)$' \
  | grep -vE '^claude/'
```

(`origin/HEAD` shortens to `origin`, not `HEAD` — hence the extra `origin` in
the exclusion; a real branch literally named `origin` doesn't exist in
practice.) This yields e.g. `geowep`, `geowep-ng`.

**Project mode** — only that project's component branches, i.e. those whose name
is `<SRC>-<something>` (the `<SRC>-` hyphen boundary keeps a sibling project like
`geowepx` from matching), and never `claude/*`:

```bash
git for-each-ref --format='%(refname:short)' refs/remotes/origin \
  | sed 's#^origin/##' \
  | grep -E "^${SRC}-" \
  | grep -vE '^claude/'
```

On `geowep` this yields e.g. `geowep-ng`. If the list is empty, there are no
downstream branches yet — report that `$SRC` was pushed and there's nothing to
propagate.

## 5. Cherry-pick onto each branch and push

For each target branch: check it out (creating a local tracking branch if it
only exists on `origin`), cherry-pick the range, and push. Do them one at a
time so a conflict on one branch doesn't obscure the others.

```bash
for b in <branches>; do
  echo "=== $b ==="
  git checkout "$b" 2>/dev/null || git checkout -b "$b" "origin/$b"
  git cherry-pick $RANGE          # $RANGE unquoted: multiple SHAs → multiple picks
  git push origin "$b"
done
git checkout "$SRC"               # always return to the source branch when done
```

**On a cherry-pick conflict**, don't force it. Stop, `git cherry-pick --abort`
on that branch, return to `$SRC`, and tell the user which branch conflicted and
on which file — the change may need hand-merging there (the target branch likely
customized the same file). Report which branches did propagate cleanly so the
user knows the partial state.

## 6. Report

Summarize: the `$SRC` SHA pushed, and each target branch with its cherry-pick
SHA and push result. Note any branch that was skipped or conflicted. Confirm the
working tree is back on `$SRC`.
