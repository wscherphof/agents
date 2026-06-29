# Design: `conf/CLAUDE.md` agent-workflow overlay

## Purpose

Add a `conf/CLAUDE.md` file: project/component-specific instructions for the
cloud-agent workflow that should **not** live in the project repo (e.g. cloud
build quirks, which branch to target, tooling notes). It is maintained in the
**agents** repo, per settings branch, alongside the other `conf/` files
(`conf/.env`, `conf/PROJECT.sh`, `conf/COMPONENT.sh`), and is always processed
by Claude.

This is an *overlay*, distinct from and in addition to the project repo's own
`CLAUDE.md` (which the session-start hook already mirrors into the
`<!-- BEGIN MERGED AGENT INSTRUCTIONS -->` block of the root `CLAUDE.md`).

## Mechanism: native `@import`

Two pieces:

1. **`conf/CLAUDE.md` — a committed template on `main`.** Like `conf/.env`, it
   ships on `main` with a comment header explaining its purpose and an otherwise
   empty body. It propagates to every project/component branch when branched or
   rebased from `main`; the user fills it in per branch.

2. **An `@conf/CLAUDE.md` import line** added near the top of the root
   `CLAUDE.md`, on its own plain line (not inside a code span or fenced block,
   so Claude Code's memory-import picks it up). Claude Code resolves the import
   when it reads the root `CLAUDE.md` at session start, so the content is
   processed **with no dependency on the session-start hook finishing**.

## How it fits the existing flow (no merge-script changes)

- The import line lives in the hand-maintained part of `CLAUDE.md`, *outside*
  the `<!-- BEGIN MERGED AGENT INSTRUCTIONS -->` block. `merge_claude_md` in
  `.claude/hooks/session-start/scripts/merge-agent-settings.sh` preserves
  everything outside that block as its `base`, so the import line survives every
  re-merge untouched.
- `conf/CLAUDE.md` is committed on the settings branch, so it is present at
  clone time and the import resolves immediately. The merge script's
  `git add -A` keeps it committed/pushed like the other `conf/` files.
- Because the template always exists on `main` (and therefore on every branch
  derived from it), the import never dangles — the design does not rely on
  missing-import tolerance.

## Scope

- The import is **unconditional**: the root `CLAUDE.md` is read in both local
  and remote sessions. On `main` and in local checkouts the file is just the
  empty template, so it is effectively a no-op there; it only carries content on
  the cloud settings branches where the user fills it in.
- Each monorepo component already gets its own settings branch (e.g.
  `geowep/ng`) with its own `conf/`, so **one `conf/CLAUDE.md` per branch**
  covers the component case. No separate project-level vs component-level files
  are needed.

## Files changed

- **New:** `conf/CLAUDE.md` — template with a commented header (purpose +
  lifecycle), empty body.
- **Edit:** `CLAUDE.md` (root) — add the `@conf/CLAUDE.md` import line near the
  top, with a one-line note that it pulls in per-project agent instructions.
- **Edit:** `README.md` — document `conf/CLAUDE.md` alongside the other `conf/`
  files (it is the per-project/component agent-instructions overlay).

## Out of scope

- No change to `merge-agent-settings.sh` (the import line is preserved
  automatically as `base`).
- No separate project- vs component-level overlay files.

## Verification

Manual (import resolution and hook timing are not unit-testable):

1. Put a sentinel instruction in `conf/CLAUDE.md` on a test branch; start a
   session and confirm Claude has the instruction in context.
2. Run `merge-agent-settings.sh` (or simulate `merge_claude_md`) against a
   `CLAUDE.md` containing the import line and confirm the line is preserved in
   the output, both with and without a generated managed block.
