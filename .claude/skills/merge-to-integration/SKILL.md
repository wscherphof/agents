---
name: merge-to-integration
description:
  Use when asked to merge, land, or push the current local changes into
  the remote `integration` branch. The `integration` branch has a branch policy
  that forbids direct pushes, so this routes the changes through a temporary
  branch and a policy-gated Azure DevOps pull request. Trigger on "merge to
  integration", "push my changes to integration", "get this onto integration".
---

# Merge local changes into `integration`

This is an Azure DevOps repo (`dev.azure.com/merkatordev/GeoWEP`). The
`integration` branch rejects direct pushes because of a branch policy. To land
local changes you push a **temporary branch**, open a **PR into `integration`**,
let it **auto-complete once the policy passes**, then clean up and pull.

Use the `az repos` CLI (the `azure-devops` extension is installed; org/project
auto-detect from the git remote). Do **not** try to `git push origin integration`
— the policy will reject it.

## Workflow

Run these from the repo root. Announce each step's result to the user.

### 1. Make sure the changes are committed

```bash
git status --short
```

The changes to land must be **commits**, not just working-tree edits. If there
are uncommitted changes, commit them first (ask the user for a message if
unclear). Note the current branch and the commit(s) you intend to merge.

### 2. Create and push a temporary branch

```bash
TEMP_BRANCH="claude/integration-merge-$(date +%Y%m%d-%H%M%S)"
git switch -c "$TEMP_BRANCH"
git push -u origin "$TEMP_BRANCH"
```

The temp branch points at the current HEAD, so it carries exactly the commits
you want to land. Keep `$TEMP_BRANCH` in a shell variable for later steps (or
just remember the name).

### 3. Open a PR into `integration`, set to auto-complete

```bash
az repos pr create \
  --source-branch "$TEMP_BRANCH" \
  --target-branch integration \
  --title "Merge $TEMP_BRANCH into integration" \
  --auto-complete true \
  --delete-source-branch true \
  --output json
```

- `--auto-complete true` — the PR completes itself the moment all required
  policies pass and the branch is mergeable. This is what respects the policy.
- `--delete-source-branch true` — Azure DevOps deletes the **remote** temp
  branch automatically on completion (you still delete the local one in step 5).
- Capture the PR id from the JSON output (`.pullRequestId`) — you need it to
  poll status.

Do **not** pass `--bypass-policy` — the whole point is to let the policy run.
Only add `--squash true` if the user asks for a squash merge; otherwise use the
repo's default merge strategy.

### 4. Wait for the policy to pass and the PR to complete

Poll the PR status until it leaves `active`:

```bash
PR_ID=<id from step 3>
while true; do
  STATUS=$(az repos pr show --id "$PR_ID" --query status -o tsv)
  echo "PR $PR_ID status: $STATUS"
  [ "$STATUS" != "active" ] && break
  sleep 15
done
```

- `completed` → the policy passed and the changes merged. Continue.
- `abandoned` or still failing → the policy blocked the merge. Report why to the
  user (`az repos pr show --id "$PR_ID"` for details / failing checks) and stop.
  Do not force it.

A build/validation policy can take several minutes; keep polling.

### 5. Delete the local temporary branch

The remote temp branch is already gone (step 3's `--delete-source-branch`).
Switch off the temp branch and delete it locally:

```bash
git switch integration
git branch -D "$TEMP_BRANCH"
```

If a stale remote-tracking ref lingers: `git fetch --prune origin`.

### 6. Pull the merged changes into local `integration`

```bash
git pull origin integration
```

Local `integration` now contains the merged changes. Confirm with `git log
--oneline -5` and report completion to the user.

## Quick reference

| Step               | Command                                                                                                        |
| ------------------ | -------------------------------------------------------------------------------------------------------------- |
| Temp branch        | `git switch -c claude/integration-merge-$(date +%Y%m%d-%H%M%S)`                                                |
| Push               | `git push -u origin "$TEMP_BRANCH"`                                                                            |
| PR + auto-complete | `az repos pr create -s "$TEMP_BRANCH" -t integration --auto-complete true --delete-source-branch true -o json` |
| Poll               | `az repos pr show --id "$PR_ID" --query status -o tsv`                                                         |
| Local cleanup      | `git switch integration && git branch -D "$TEMP_BRANCH"`                                                       |
| Pull               | `git pull origin integration`                                                                                  |

## Common mistakes

- **Pushing to `integration` directly** — rejected by policy. Always route
  through a temp branch + PR.
- **Bypassing the policy** (`--bypass-policy`) — defeats the purpose; the user
  wants the policy to gate the merge.
- **Not waiting for completion** — deleting branches or pulling before the PR
  reaches `completed` loses the changes or races the merge. Poll first.
- **Merging uncommitted work** — the temp branch only carries commits; commit
  before branching.
- **Deleting the remote temp branch by hand** — `--delete-source-branch true`
  already does it on completion.
