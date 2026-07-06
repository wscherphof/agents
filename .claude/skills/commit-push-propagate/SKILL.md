---
name: commit-push-propagate
description: >-
  Commit the working changes on the agents-repo template branch (main), push
  them, then propagate them to every per-project/component settings branch by
  cherry-pick. Use when the user says "commit, push, propagate" (or similar)
  while evolving the agents scaffolding itself. ONLY applies on the `main`
  template branch of the agents repo (blank AGENTS_GIT_REPO) — not in a project
  session and not on a settings branch.
---

# Commit, push, propagate scaffolding changes

Encodes the template-branch workflow from the agents-repo `CLAUDE.md` ("Two
repos, two git workflows"): a scaffolding change is committed on `main`, pushed,
and then replayed onto each per-project/component settings branch so every
project picks it up.

## 1. Guard: are we in the scaffolding context?

This skill only applies when **evolving the agents scaffolding itself** — i.e.
on the `main` template branch of the *agents* repo, at the workspace root.
Verify before doing anything:

```bash
git rev-parse --abbrev-ref HEAD                 # must be main (or master)
grep -E '^AGENTS_GIT_REPO=' conf/.env           # must be blank (no project configured)
```

If the current branch is **not** `main`/`master`, or `AGENTS_GIT_REPO` is
**set** (a project is configured — this is a project session, see `CLAUDE.md`),
**stop** and tell the user this skill is only for scaffolding changes on the
template branch. Propagation does not apply to project work.

## 2. Commit the working changes

If there's nothing to commit and `origin/main..HEAD` is also empty, stop —
there's nothing to push or propagate.

Otherwise stage and commit whatever is pending. Write a conventional-commit
message (`docs:`/`feat:`/`fix:`/… matching the repo's style — see `git log`),
derived from the actual diff, and end it with the co-author trailer this repo
uses:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

If the user already committed and only wants the push+propagate, skip the commit
and proceed. Multiple pending commits are fine — the whole
`origin/main..HEAD` range gets propagated.

## 3. Push main

Capture the range to propagate **before** pushing, then push:

```bash
RANGE=$(git rev-list --reverse origin/main..HEAD)   # oldest-first SHAs, the new commits
git push origin main
```

`$RANGE` is exactly the set of new commits to replay onto each settings branch,
oldest first (order matters for clean cherry-picks).

## 4. Determine the settings branches

Propagate to **every per-project/component settings branch** — every branch on
`origin` **except** `main`/`master`, `origin/HEAD`, and the `claude/*` session
backstop branches (those aren't settings branches):

```bash
git fetch origin --prune
git for-each-ref --format='%(refname:short)' refs/remotes/origin \
  | sed 's#^origin/##' \
  | grep -vE '^(HEAD|main|master)$' \
  | grep -vE '^claude/'
```

This yields e.g. `geowep`, `geowep-ng`. If it's empty, there are no settings
branches yet — report that main was pushed and there's nothing to propagate.

## 5. Cherry-pick onto each branch and push

For each settings branch: check it out (creating a local tracking branch if it
only exists on `origin`), cherry-pick the range, and push. Do them one at a
time so a conflict on one branch doesn't obscure the others.

```bash
for b in <branches>; do
  echo "=== $b ==="
  git checkout "$b" 2>/dev/null || git checkout -b "$b" "origin/$b"
  git cherry-pick $RANGE          # $RANGE unquoted: multiple SHAs → multiple picks
  git push origin "$b"
done
git checkout main                 # always return to main when done
```

**On a cherry-pick conflict**, don't force it. Stop, `git cherry-pick --abort`
on that branch, return to `main`, and tell the user which branch conflicted and
on which file — a scaffolding change may need hand-merging there (the settings
branch likely customized the same file). Report which branches did propagate
cleanly so the user knows the partial state.

## 6. Report

Summarize: the `main` SHA pushed, and each settings branch with its cherry-pick
SHA and push result. Note any branch that was skipped or conflicted. Confirm the
working tree is back on `main`.
