# Decision: keep the full settings mirror

**Date:** 2026-08-24 · **Status:** accepted · **Applies to:**
[`.claude/hooks/session-start/scripts/merge-agent-settings.sh`](../../.claude/hooks/session-start/scripts/merge-agent-settings.sh)

## Question

Could the mirroring in `merge-agent-settings.sh` be replaced by *instructions* —
telling the agent, in `CLAUDE.md`, to read the project's (and component's)
instructions, settings, skills, agents and MCP servers straight out of
[`src/`](../../src/) — so the script's copy/merge/commit/push machinery could go
away?

## Decision

**No. Keep the mirror as it is, including the commit and push to the
project/component settings branch.** Nothing in what it mirrors can be fully
replaced by instructions, and the parts that *could* be aren't worth splitting
out (see "Why not a partial cut" below).

## Why

The mirror runs from a `SessionStart` hook — i.e. **after** the harness has
already read `settings.json`, `.mcp.json`, `.claude/agents/`, `.claude/skills/`,
`.claude/commands/` and the `CLAUDE.md` chain for *this* session. So the mirror
never configures the session that produces it; its payoff is the push to the
settings branch, which makes **session N+1** boot already-configured.

Instructions and the mirror therefore act on different timelines: instructions
act at runtime in the current session (which the mirror can't help), the mirror
acts at process start of the next one (which instructions can't reach). The
question that actually decides it is **who consumes each mirrored thing — the
model, or the harness** — because only the model-consumed half is expressible as
instructions at all.

| Mirrored thing | Consumer | Instruction-replaceable? |
| --- | --- | --- |
| `CLAUDE.md` → `.claude/merged-agent-instructions.md` | model | Yes, with caveats |
| `.claude/skills/` | harness registry + model | Partly — degraded |
| `.github/`, `.agents/` | model, on demand | Yes, essentially free |
| `.claude/agents/` | harness registry | Approximable, unenforced |
| `.claude/commands/` | harness only (`/foo`) | **No** |
| `settings.json` hooks | harness executes them | **No** |
| `settings.json` permissions / `env` | harness gates the tool call | **No** |
| `.mcp.json` / `mcpServers` | harness spawns at startup | **No** |
| `statusLine`, `fileSuggestion` | harness | **No** |
| referenced command files (§5) | only makes mirrored settings' relative paths resolve | moot if settings go |

The blockers are hard for one reason: **the harness does those things, not the
agent.** No prose makes an MCP server exist, makes a `PostToolUse` formatter
fire, pre-approves a `Bash` pattern, or makes the user's `/deploy` resolve.
`mirror_mcp` exists precisely because MCP servers must sit in `.mcp.json` at
startup — that's the script acknowledging the constraint, not working around it.

The two soft cases still lose something real:

- **`CLAUDE.md`** is partly redundant already (Claude Code loads a
  subdirectory's `CLAUDE.md` on demand when files there are accessed). But the
  merge guarantees *component layering* — root + component both applying, in
  order — and *persistence*: an `@import` lives in the memory block and is
  re-injected, whereas a `cat`'d file is ordinary conversation content that can
  be evicted at compaction and lacks the "these OVERRIDE default behavior"
  weight. "On demand" also means "possibly after the agent already did the thing
  those instructions forbade".
- **Skills** look prose-shaped but aren't. The value isn't the `SKILL.md` body
  (that can be `cat`'d, and its relative `references/` paths still resolve) — it
  is the description list in the system prompt that makes the model self-trigger,
  plus `/name` invocation and the Skill tool refusing unregistered names.
  Auto-generating a substitute index is mirroring wearing a different hat.

## Why not a partial cut

Dropping just the model-consumed rows (`.github/`, `.agents/`, and the
`CLAUDE.md` merge) would retire `merge_claude_md`, the generated-file marker, two
`mirror_dir` calls and the root `CLAUDE.md` `@import`. It would keep every part
that is actually messy: scaffolding re-injection, the skills exclusion list with
its "keep in sync with `propagate.sh`" coupling, the commit/push/`reset --hard`
sequence, and the `apt`/`rsync`/`jq`/`python3` dependency. The complexity worth
deleting lives in the half that can't be replaced — so the cut buys little and
costs the component layering and `@import` persistence described above.

## If this is revisited

Two harness behaviours were not verified and would change specific rows if they
turn out to be dynamic rather than startup-only:

1. Whether Claude Code re-reads `settings.json` mid-session for anything beyond
   permissions (hooks are documented as needing a restart, which is what makes
   them a blocker).
2. Whether skills and commands are ever re-discovered after startup.

One idea worth keeping on the shelf regardless: the hook already emits a status
line into the session context, and could just as well emit project instructions
there as `additionalContext`. That would serve the prose subset **for the current
session** — something the mirror has never done — without any commit or push. It
is additive to the mirror, not a replacement for it.
