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

| Skill                                             | Description                                                                                                            |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| [optimize-agents-md](./skills/optimize-agents-md) | Optimize your AGENTS.md (and CLAUDE.md) files according to best practices. Works with monorepos, too                   |
| [panel-review](./skills/panel-review)             | Fan a code review out to multiple local CLI agents (codex, claude, opencode) in parallel and synthesize their findings |
| [panel-review-loop](./skills/panel-review-loop)   | Autonomously loop panel-review — fix what's worth fixing, re-review, repeat until clean, then report                   |
| [triage-pr-comments](./skills/triage-pr-comments) | Triage every review comment on a PR — verdict per comment, then fix, push, and reply on GitHub                         |

## License

MIT
