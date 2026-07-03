<!--
Project-specific agent instructions for this settings branch.

This is the agent-workflow OVERLAY: guidance for the cloud Claude Code sessions
that should NOT live in the project repo — cloud build quirks, which branch to
target, tooling notes, and the like. It is committed per project/component
settings branch (alongside conf/.env, conf/PROJECT.sh, conf/COMPONENT.sh) and is
imported by the root CLAUDE.md, so Claude always processes it.

It is SEPARATE from the project repo's own CLAUDE.md, which the session-start
hook mirrors into .claude/merged-agent-instructions.md (imported by the root
CLAUDE.md).

On the `main` template branch this file is intentionally empty. Fill it in on
each project/component branch. Write plain Markdown instructions directly below
this comment.
-->

If the prompt mentions a work item on Azure DevOps, and that work item is
currently in state To Do, start off with moving that work item to state Doing.
Never make any further state transitions.
