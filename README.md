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
| [babysit-prs](./skills/babysit-prs)               | Sweep all your open non-draft PRs on a `/loop` — keep them mergeable, CI green, and review comments triaged, acting only on the PRs that need it    |
| [commandments](./skills/commandments)             | Audit a branch, PR, or uncommitted changes against your project's COMMANDMENTS.md — worked checklist with file:line findings and concrete fixes     |
| [optimize-agents-md](./skills/optimize-agents-md) | Optimize your AGENTS.md (and CLAUDE.md) files according to best practices. Works with monorepos, too                                                |
| [panel-plan](./skills/panel-plan)                 | Run a single independent panel review of a written plan — fan it out to local CLI agents, synthesize findings + open questions. Read-only, one pass |
| [panel-plan-loop](./skills/panel-plan-loop)       | Harden a plan by iterating panel-plan to convergence — auto-fix the clear stuff, raise judgment calls to you, edit the plan, re-review, loop        |
| [panel-review](./skills/panel-review)             | Fan a code review out to multiple local CLI agents (codex, claude, opencode) in parallel and synthesize their findings                              |
| [panel-review-loop](./skills/panel-review-loop)   | Autonomously loop panel-review — fix what's worth fixing, re-review, repeat until clean, then report                                                |
| [triage-pr-comments](./skills/triage-pr-comments) | Triage every review comment on a PR — verdict per comment, then fix, push, and reply on GitHub                                                      |
| [walkmethrough](./skills/walkmethrough)           | Interactive manual-QA of the current branch — the agent watches dev-server logs and the local DB while you run each test step                       |

## License

MIT
