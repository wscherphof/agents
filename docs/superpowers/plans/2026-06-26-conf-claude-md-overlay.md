# `conf/CLAUDE.md` Agent-Workflow Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-project/component `conf/CLAUDE.md` overlay that Claude always processes, wired in via a native `@import` in the root `CLAUDE.md`.

**Architecture:** Ship `conf/CLAUDE.md` as a committed (intentionally empty) template on `main`, alongside the other `conf/` files. Add a bare `@conf/CLAUDE.md` import line near the top of the root `CLAUDE.md`; Claude Code's memory-import resolves it at session start, independent of the session-start hook. The import line lives outside the `<!-- BEGIN MERGED AGENT INSTRUCTIONS -->` block, so `merge_claude_md` preserves it automatically — no merge-script changes.

**Tech Stack:** Markdown (CLAUDE.md memory + imports), Bash/Python (existing merge script — read-only here for verification), Git.

## Global Constraints

- The overlay's editable guidance must be a **no-op on `main` and in local checkouts**: the template body carries no instructions; all explanatory text lives in an HTML comment (`<!-- ... -->`).
- The import token must be a **bare `@conf/CLAUDE.md` on its own line** (not a Markdown link, not inside a code span/fence), or Claude Code will not import it.
- **No changes** to `.claude/hooks/session-start/scripts/merge-agent-settings.sh` — the import line is preserved as `base`.
- One `conf/CLAUDE.md` per settings branch covers both the project and component cases (each component has its own settings branch).

---

### Task 1: Add the `conf/CLAUDE.md` template and wire up the import

**Files:**
- Create: `conf/CLAUDE.md`
- Modify: `CLAUDE.md` (root, prepend before line 1 `# Two repos, two git workflows`)

**Interfaces:**
- Consumes: nothing.
- Produces: a `conf/CLAUDE.md` file at the repo-relative path `conf/CLAUDE.md`, imported by the root `CLAUDE.md` via the literal token `@conf/CLAUDE.md`.

- [ ] **Step 1: Create the `conf/CLAUDE.md` template**

Create `conf/CLAUDE.md` with exactly this content (all guidance inside an HTML comment so the file is a no-op until filled in):

```markdown
<!--
Project-specific agent instructions for this settings branch.

This is the agent-workflow OVERLAY: guidance for the cloud Claude Code sessions
that should NOT live in the project repo — cloud build quirks, which branch to
target, tooling notes, and the like. It is committed per project/component
settings branch (alongside conf/.env, conf/PROJECT.sh, conf/COMPONENT.sh) and is
imported by the root CLAUDE.md, so Claude always processes it.

It is SEPARATE from the project repo's own CLAUDE.md, which the session-start
hook already mirrors into the "MERGED AGENT INSTRUCTIONS" block of the root
CLAUDE.md.

On the `main` template branch this file is intentionally empty. Fill it in on
each project/component branch. Write plain Markdown instructions directly below
this comment.
-->
```

- [ ] **Step 2: Add the import line to the root `CLAUDE.md`**

The root `CLAUDE.md` currently begins at line 1 with `# Two repos, two git workflows`. Insert the following block *above* that line, so the file now starts with it (note the blank line separating it from the existing heading):

```markdown
Per-project agent instructions for this settings branch live in
[conf/CLAUDE.md](conf/CLAUDE.md) and are imported here:

@conf/CLAUDE.md

```

After the edit, the top of `CLAUDE.md` reads:

```markdown
Per-project agent instructions for this settings branch live in
[conf/CLAUDE.md](conf/CLAUDE.md) and are imported here:

@conf/CLAUDE.md

# Two repos, two git workflows
```

- [ ] **Step 3: Verify the import token is bare and on its own line**

Run: `grep -nx '@conf/CLAUDE.md' CLAUDE.md`
Expected: one matching line (the `-x` flag confirms the token is alone on its line — no link brackets, no code fence, no surrounding text).

- [ ] **Step 4: Verify the template exists and is comment-only**

Run: `grep -c '^[^<!-].*[A-Za-z]' conf/CLAUDE.md` (counts non-comment, non-blank instruction lines)
Expected: `0` (the template body carries no instructions).

- [ ] **Step 5: Commit**

```bash
git add conf/CLAUDE.md CLAUDE.md
git commit -m "feat: add conf/CLAUDE.md agent-workflow overlay imported by root CLAUDE.md"
```

---

### Task 2: Confirm `merge_claude_md` preserves the import line

This task adds no source changes; it verifies the Global Constraint that the import survives a re-merge. `merge_claude_md` keeps everything *outside* the `<!-- BEGIN MERGED AGENT INSTRUCTIONS -->` / `<!-- END MERGED AGENT INSTRUCTIONS -->` block as its `base`. The check below reproduces that exact strip logic against a sample and asserts the import line is retained.

**Files:**
- Create: `scratchpad/verify-merge-preserves-import.sh` (throwaway; not committed)

- [ ] **Step 1: Write the verification script**

Create the script (the embedded Python mirrors the block-stripping logic in `merge_claude_md`):

```bash
#!/usr/bin/env bash
set -euo pipefail

BEGIN='<!-- BEGIN MERGED AGENT INSTRUCTIONS (auto-generated, do not edit) -->'
END='<!-- END MERGED AGENT INSTRUCTIONS -->'

sample="$(mktemp)"
cat >"$sample" <<EOF
Per-project agent instructions for this settings branch live in
[conf/CLAUDE.md](conf/CLAUDE.md) and are imported here:

@conf/CLAUDE.md

# Two repos, two git workflows

Some hand-maintained body text.

$BEGIN

## From acct/repo (root)
mirrored project instructions
$END
EOF

base="$(BEGIN="$BEGIN" END="$END" python3 - "$sample" <<'PY'
import os, sys
begin, end = os.environ["BEGIN"], os.environ["END"]
text = open(sys.argv[1], encoding="utf-8").read()
i = text.find(begin)
if i != -1:
    j = text.find(end, i)
    if j != -1:
        pre = text[:i].rstrip("\n")
        post = text[j + len(end):].lstrip("\n")
        text = pre + ("\n" + post if post else "")
sys.stdout.write(text)
PY
)"

echo "$base" | grep -qx '@conf/CLAUDE.md' \
  && echo "PASS: import line preserved after managed-block strip" \
  || { echo "FAIL: import line lost"; exit 1; }

# Also confirm the managed block itself was removed
echo "$base" | grep -q 'mirrored project instructions' \
  && { echo "FAIL: managed block not stripped"; exit 1; } \
  || echo "PASS: managed block stripped"

rm -f "$sample"
```

- [ ] **Step 2: Run the verification script**

Run: `bash scratchpad/verify-merge-preserves-import.sh`
Expected:
```
PASS: import line preserved after managed-block strip
PASS: managed block stripped
```

- [ ] **Step 3: No commit**

The script is a throwaway check in the scratchpad and is not committed. Delete it once it passes: `rm -f scratchpad/verify-merge-preserves-import.sh`.

---

### Task 3: Document `conf/CLAUDE.md` in the README

**Files:**
- Modify: `README.md` (insert a paragraph after the numbered hook-steps list, before the `### Variables for your setup scripts` heading at line 58)

**Interfaces:**
- Consumes: the `conf/CLAUDE.md` file from Task 1.
- Produces: nothing (docs only).

- [ ] **Step 1: Insert the documentation paragraph**

In `README.md`, immediately after the numbered list item 5 (which ends `...A run with no changes produces no commit.` around line 56) and the following blank line, before `### Variables for your setup scripts`, insert:

```markdown
Alongside the setup scripts, [conf/CLAUDE.md](conf/CLAUDE.md) holds
**per-project/component agent instructions** — the agent-workflow overlay for
guidance that should not live in the project repo (cloud build quirks, which
branch to target, tooling notes). It is committed per settings branch like the
other `conf/` files and is imported by the root [CLAUDE.md](CLAUDE.md), so the
cloud session always processes it. It is separate from, and layered on top of,
the project repo's own `CLAUDE.md` that step 5 mirrors in. On the `main`
template branch it is intentionally empty.

```

- [ ] **Step 2: Verify the link and placement**

Run: `grep -n 'conf/CLAUDE.md' README.md`
Expected: at least one line referencing `conf/CLAUDE.md`, located before the `### Variables for your setup scripts` heading.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document conf/CLAUDE.md agent-workflow overlay"
```

---

## Self-Review

**Spec coverage:**
- Spec "conf/CLAUDE.md template on main" → Task 1, Step 1. ✓
- Spec "@conf/CLAUDE.md import line in root CLAUDE.md" → Task 1, Step 2. ✓
- Spec "no merge-script changes; import preserved as base" → Task 2 verifies. ✓
- Spec "scope: no-op on main/local; one file per branch" → Global Constraints + Task 1 comment-only template. ✓
- Spec "document in README" → Task 3. ✓
- Spec "verification (sentinel + merge preservation)" → Task 2 covers merge preservation programmatically; sentinel-in-session check is inherently manual and noted in the spec.

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code/content step shows exact content. ✓

**Type/name consistency:** The literal token `@conf/CLAUDE.md` and the path `conf/CLAUDE.md` are used identically across Tasks 1–3 and the verification script. The managed-block markers match those in `merge-agent-settings.sh` verbatim. ✓
