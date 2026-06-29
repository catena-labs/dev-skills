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

| Skill                                                   | Description                                                                                                                                         |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [babysit](./skills/babysit)                             | Babysit the single PR you're on — keep it mergeable, CI green, and review comments triaged on a `/loop`, acting only when it needs it               |
| [babysit-prs](./skills/babysit-prs)                     | Sweep all your open non-draft PRs on a `/loop` — keep them mergeable, CI green, and review comments triaged, acting only on the PRs that need it    |
| [bot-panel-review-loop](./skills/bot-panel-review-loop) | Sweep a repo's open PRs — one fresh agent per PR runs a gather-only panel review and posts advisory findings to GitHub. Read-only; built for /loop  |
| [commandments](./skills/commandments)                   | Audit a branch, PR, or uncommitted changes against your project's COMMANDMENTS.md — worked checklist with file:line findings and concrete fixes     |
| [optimize-agents-md](./skills/optimize-agents-md)       | Optimize your AGENTS.md (and CLAUDE.md) files according to best practices. Works with monorepos, too                                                |
| [panel-plan](./skills/panel-plan)                       | Run a single independent panel review of a written plan — fan it out to local CLI agents, synthesize findings + open questions. Read-only, one pass |
| [panel-plan-loop](./skills/panel-plan-loop)             | Harden a plan by iterating panel-plan to convergence — auto-fix the clear stuff, raise judgment calls to you, edit the plan, re-review, loop        |
| [panel-review](./skills/panel-review)                   | Fan a code review out to multiple local CLI agents (codex, claude, opencode) in parallel and synthesize their findings                              |
| [panel-review-loop](./skills/panel-review-loop)         | Autonomously loop panel-review — fix what's worth fixing, re-review, repeat until clean, then report                                                |
| [triage-pr-comments](./skills/triage-pr-comments)       | Triage every review comment on a PR — verdict per comment, then fix, push, and reply on GitHub                                                      |
| [walkmethrough](./skills/walkmethrough)                 | Interactive manual-QA of the current branch — the agent watches dev-server logs and the local DB while you run each test step                       |

## Quiet `/loop` notifications (cmux)

[`babysit`](./skills/babysit) and [`babysit-prs`](./skills/babysit-prs) start a
tick's status line with a `[QUIET]` marker when the tick needed no human
attention (they only report or do self-contained auto-fixes). A tick that needs
you — a stop-and-ask, a reply awaiting approval, a change worth a look — is left
unmarked. On its own the marker is just text; pair it with a notification filter
so your terminal only pings you for the ticks that matter.

If you run your loops in [cmux](https://cmux.com), add a notification hook that
mutes any notification whose body starts with the marker, while letting
needs-input / permission / error notifications through loud. It keys on the
notification body, so it works for any agent (Claude, Codex, …) whose loop emits
the marker.

1. Save this as `~/.config/cmux/notify-filter.sh` and `chmod +x` it:

   ```bash
   #!/usr/bin/env bash
   # Mute cmux notifications whose body starts with [QUIET] (also [SILENT]/[NO-OP]) —
   # the marker babysit/babysit-prs put on no-op /loop ticks. Everything else
   # (needs-input, permission, errors, unmarked completions) stays loud.
   # Fail-safe: echoes stdin unchanged on any error or if jq is missing.
   set -uo pipefail
   input="$(cat)"
   command -v jq >/dev/null 2>&1 || { printf '%s' "$input"; exit 0; }
   mute="$(printf '%s' "$input" | jq -r '
     (.notification.body // "" | ascii_downcase)
     | if test("^[[:space:]>*_`-]*\\[(quiet|silent|no-?op)\\]") then "1" else "0" end
   ' 2>/dev/null || echo 0)"
   if [ "$mute" = "1" ]; then
     printf '%s' "$input" | jq -c '.effects.desktop=false|.effects.sound=false|.effects.paneFlash=false|.effects.reorderWorkspace=false|.effects.markUnread=false' 2>/dev/null || printf '%s' "$input"
   else
     printf '%s' "$input"
   fi
   ```

2. Register the hook in `~/.config/cmux/cmux.json` (use the script's absolute
   path):

   ```jsonc
   {
     "notifications": {
       "hooks": [
         {
           "id": "loop-quiet-filter",
           "command": "/Users/you/.config/cmux/notify-filter.sh",
           "timeoutSeconds": 10,
         },
       ],
     },
   }
   ```

3. Apply it: `cmux reload-config`.

Now no-op loop ticks land silently in cmux's notification history (the filter
leaves `record` on) while anything that needs you still rings. To confirm, run a
loop and watch: a `[QUIET]` tick stays quiet, a stop-and-ask pings.

## License

MIT
