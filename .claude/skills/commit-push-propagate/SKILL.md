---
name: commit-push-propagate
description: >-
  Commit the working changes on the current agents-repo branch, push them, then
  propagate them to the downstream settings branches by cherry-pick. Also brings
  settings branches that have fallen behind up to date even when the source
  branch itself has no new commits. Two modes: on the `main` template branch it
  propagates to every per-project/component settings branch; on a project
  settings branch (e.g. `geowep`) it propagates to that project's component
  settings branches (e.g. `geowep-ng`). Use when the user says "commit, push,
  propagate" (or similar) while evolving the agents scaffolding itself. ONLY
  applies in a local agents-repo session — not in a remote/ephemeral `claude/*`
  session.
---

# Commit, push, propagate scaffolding changes

Encodes the propagation workflow from the agents-repo `CLAUDE.md` ("Two repos,
two git workflows"): a change is committed on the current branch, pushed, and
then replayed onto each downstream settings branch so those branches pick it up.

Propagation is driven by **what each target is actually missing**, not just by
the commits this run adds. So it also catches up a settings branch that fell
behind in an earlier session — replaying commits that were already pushed to the
source but never reached that branch — **even when the source branch itself has
no new commits to commit or push**. The per-target set is computed by patch
identity (`git cherry`), so commits a branch already has under a different SHA
(from a previous cherry-pick) are skipped rather than re-applied.

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

**Do not stop just because the source branch has no new commits.** Even with a
clean tree and nothing unpushed, targets may be behind on already-pushed commits
— that case is exactly what this skill now catches up (see step 5). The only
"nothing to do" outcome is discovered at the end, once step 5 finds every target
already up to date; don't short-circuit here.

If there **are** pending working changes, stage and commit them. Write a
conventional-commit message (`docs:`/`feat:`/`fix:`/… matching the repo's style
— see `git log`), derived from the actual diff, and end it with the co-author
trailer this repo uses:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

If the tree is clean (nothing to commit), or the user already committed and only
wants the push+propagate, skip the commit and proceed. Multiple pending commits
are fine — step 5 propagates whatever each target is missing.

## 3. Push the source branch

Push the source branch so `origin/$SRC` is current — the target catch-up in step
5 is computed against `origin/$SRC`, so it must be up to date first. If there's
nothing to push (`HEAD` already equals `origin/$SRC`), skip the push and carry on
— there may still be behind targets to catch up.

```bash
if [ -n "$(git rev-list origin/"$SRC"..HEAD)" ]; then
  git push origin "$SRC"
else
  echo "source $SRC already up to date on origin — nothing to push"
fi
```

There is no single global range to capture here: unlike before, step 5 computes
what to replay **per target branch** (each may be missing a different set), so
the range is derived there, not once up front.

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
downstream branches yet — report the source state (pushed, or already current)
and that there's nothing to propagate.

## 5. Cherry-pick onto each branch and push

For each target branch, compute the commits it is **missing** relative to the
source, then cherry-pick exactly those and push. Do the branches one at a time so
a conflict on one doesn't obscure the others.

The missing set is computed with **`git cherry`**, not `origin/$SRC..HEAD`:

```bash
git cherry "origin/$b" "$SRC" | awk '/^\+/ {print $2}'
```

`git cherry <upstream> <head>` lists the commits on `<head>` (the source) that
are **not yet on** `<upstream>` (the target), comparing by **patch identity**,
and prints them **oldest-first** (the order cherry-pick needs). Lines prefixed
`+` are missing and must be replayed; lines prefixed `-` are already present
under some SHA (e.g. a previous cherry-pick) and are skipped. This is what makes
the skill catch up a behind branch: it replays every source commit the target
lacks — whether just-pushed or pushed long ago — while never re-applying one it
already has.

**Do not batch the picks** (`git cherry-pick $all_of_them`). Settings branches
customize files like `conf/.env`, `README.md` and `conf/COMPONENT.sh`, so a
scaffolding commit that touches one of those **conflicts as a matter of course**
— and a batch pick that hits a conflict mid-way leaves the index dirty (blocking
every later branch in a loop) and rolls back the clean picks that preceded it on
`--abort`. Replay **one commit at a time** instead, so each clean pick banks on
its own and only the genuinely-contested commit stops the branch.

Handle each missing commit by its outcome:

| Outcome of the single `git cherry-pick` | What it means | Action |
|---|---|---|
| **applies cleanly** | real new content, on files the branch doesn't customize | keep it |
| **conflicts on shared scaffolding** | the conflicted file is agents-repo scaffolding the branch must not customize (`.claude/hooks/**`, `.claude/skills/**`, `tools/**`) — a branch carrying an **earlier iteration** of the change (different patch-id, so `git cherry` still lists it) | resolve toward **theirs** (the source is authoritative) and **commit** — this syncs the stale branch up instead of mistaking it for superseded |
| **conflicts, superseded** | the branch already has this change via a different commit (patch-id differs, so `git cherry` still lists it); keeping the branch's version of the conflicted **customized** files leaves **no net change** | `--skip` it — don't create an empty commit |
| **conflicts, genuine** | a **customized** file diverged and keeping the branch's version still leaves a net change: the commit also brings content the branch lacks | **don't guess** — `--abort`, stop the branch, report it for a human hand-merge |

Keeping the branch's own version of a conflicted **customized** file is the safe
default. Shared scaffolding is the exception — the hooks, skills, and tools that
must be identical on every branch (none of it is mirrored from the project) — so
there the **source wins**, and an older iteration on a branch is synced up rather
than mistaken for a superseded change and left stale. The script auto-resolves in
exactly those two directions (keep-ours-when-no-net-change, take-theirs-for-shared)
and defers to a human otherwise. A branch stopped at a genuine conflict keeps (and
pushes) the commits banked before it; the rest flow on a re-run once the blocker is
hand-merged.

This logic lives in the helper **[`propagate.sh`](propagate.sh)** in this skill's
directory. Run it from the agents-repo root with the source branch and the target
list from step 4:

```bash
.claude/skills/commit-push-propagate/propagate.sh "$SRC" <branch> [<branch> ...]
```

It aligns each local branch to `origin/$b` (`git checkout -B`), replays the
missing commits per the table above, pushes each branch that got any, returns to
`$SRC`, prints a per-branch summary, and exits non-zero if any branch is blocked
on a genuine conflict. It is idempotent: re-running after a clean pass applies
nothing (already-present commits re-register as superseded skips).

**On a genuine conflict** (a branch reported `BLOCKED`), don't force it. Tell the
user which branch stopped at which commit and on which file — the branch likely
customized the same file and the change needs hand-merging there (see the
worked-through hand-merge in step 5a). Report which branches propagated cleanly
so the user knows the partial state.

### 5a. Hand-merging a genuine conflict

When a branch is `BLOCKED`, resolve that one commit by hand, then re-run
`propagate.sh` to let the remaining commits flow. The usual cause is that the
branch already carries a **more advanced** version of the change (e.g. a real
`AGENTS_INTEGRATION_BRANCH=` value where the source commit only adds the blank
template default). In that case keep the branch's version of the customized file:

```bash
git checkout -B "$b" "origin/$b"
git cherry-pick <sha>                       # conflicts
git checkout --ours -- <customized-file>    # keep the branch's superseding version
# ...edit any file that needs a true merge of both sides...
git add -A
git -c core.editor=true cherry-pick --continue   # or --skip if it nets to nothing
git push origin "$b"
```

Before committing a keep-ours resolution, **confirm the source commit's delta is
actually already present** on the branch (not silently dropped) — inspect the
commit (`git show <sha>`) and check the branch already contains those additions.
If the branch genuinely needs both sides merged, do that merge rather than
blindly keeping ours.

## 6. Report

Summarize from `propagate.sh`'s per-branch output: the source state (the `$SRC`
SHA pushed, or "already current — nothing to push"), and for each target branch
how many commits were applied, how many were skipped as superseded, and whether
it is `BLOCKED` on a genuine conflict (which commit, which file — needs the step
5a hand-merge). If nothing needed doing anywhere — no commit, no push, and every
target already current or only superseded skips — say so plainly. Confirm the
working tree is back on `$SRC`.
