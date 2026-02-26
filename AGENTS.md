# AGENTS.md

All project instructions, conventions, and development guidelines are maintained in [CLAUDE.md](CLAUDE.md).

Strictly follow the rules defined there.

## Project Tooling

Subagent definitions, skills, and orchestration scripts live in [`.claude/`](.claude/):

- `.claude/agents/` - Specialized subagent definitions for the Task tool
- `.claude/skills/` - User-invocable skills (slash commands)
- `.claude/scripts/` - Orchestration scripts that chain multiple Claude CLI calls
