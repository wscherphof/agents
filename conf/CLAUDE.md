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
