# dev-skills

A collection of useful Agent Skills we use at [Catena](https://catenalabs.com).

## Install

Install every skill in the repo:

```bash
npx skills add catena-labs/dev-skills
```

Or install a specific skill:

```bash
npx skills add catena-labs/dev-skills --skill optimize-agents-md
```

## Skills

| Skill                                             | Description                                                                                                                                         |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [optimize-agents-md](./skills/optimize-agents-md) | Optimize your AGENTS.md (and CLAUDE.md) files according to best practices. Works with monorepos, too                                                |
| [panel-plan](./skills/panel-plan)                 | Run a single independent panel review of a written plan — fan it out to local CLI agents, synthesize findings + open questions. Read-only, one pass |
| [panel-plan-loop](./skills/panel-plan-loop)       | Harden a plan by iterating panel-plan to convergence — auto-fix the clear stuff, raise judgment calls to you, edit the plan, re-review, loop        |
| [panel-review](./skills/panel-review)             | Fan a code review out to multiple local CLI agents (codex, claude, opencode) in parallel and synthesize their findings                              |
| [triage-pr-comments](./skills/triage-pr-comments) | Triage every review comment on a PR — verdict per comment, then fix, push, and reply on GitHub                                                      |

## License

MIT
