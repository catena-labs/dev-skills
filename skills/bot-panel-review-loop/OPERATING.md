# Bot Panel Review Loop — Operating Runbook

How to pick up and run the automated PR-review loop. This is the _operating
model_ (cadence, concurrency, panel composition, gotchas); for the mechanics of
a single sweep see `SKILL.md` in this directory.

## What it is

`/bot-panel-review-loop` runs **one fleet-wide sweep** of the repo's open PRs:
it selects the actionable ones and dispatches **one fresh review sub-agent per
PR**. Each sub-agent runs a multi-model `panel-review` (three panelists:
claude + codex standard, plus a second claude on `decompose`), posts advisory
inline comments plus one summary comment, and settles a GitHub reaction. The
loop **never changes code** — its only side effects are GitHub comments and
reactions.

It is driven by a **local cron** (the primary entrypoint) or, interactively, by
`/loop`:

```
# primary: a launchd/crontab job runs one self-draining sweep every ~5 min
claude -p "/bot-panel-review-loop"
# fallback: interactive, dynamic self-pacing
/loop /bot-panel-review-loop
```

Either way, one invocation is one sweep. The concurrency cap and the in-flight
set live in a durable SQLite lease table (`reserve.sh`), not in conversation
memory — so a sweep survives a context compaction or a fresh-context cron run
alike. See "Reservations" and "Cron setup" below.

## Operating model (the policy a driver must follow)

1. **Cadence.** Under cron, each fire is one self-draining sweep that runs to
   completion and exits; a `sweep-lock` makes overlapping 5-min fires no-ops.
   Under `/loop`, wake ~every 5 min (`270s`) on every tick; a sub-agent
   completion also wakes the loop and frees a slot.
2. **Concurrency: a durable cap of 3, enforced by `reserve.sh`** — not by
   counting in your head. Before dispatch, `reserve <pr> <head>`: `ok` →
   dispatch, `full` → stop this tick, `held` → skip (already in flight). Never
   kill or interrupt an in-flight review.
3. **In-flight is the lease table, not memory.** `select-prs.sh` cannot tell you
   what is mid-review (a PR being reviewed still shows NEW/UPDATED until its new
   `head=` marker is posted), but `reserve` returns `held` for it — so the
   driver carries no `{PR -> agent}` map and the cap survives a compaction or
   restart.
4. **Release on return; reconcile each tick.** `release <pr>` whenever a
   sub-agent returns (approve/do-not-approve/skip/defer) or a dispatch fails to
   start. At the top of each sweep, reconcile: for any lease whose PR the
   prefilter now reports SEEN-at-head, `release` it (its summary marker landed).
   The TTL (default 30 min) is only a crash backstop.

## Reservations (the lease table)

`reserve.sh` (bundled, beside `select-prs.sh`/`pr-actions.sh`) is the durable
cap and in-flight set. The **driver** calls it; the per-PR sub-agent never does.

- **State:** a SQLite DB at `$RESERVE_DB` (default
  `${XDG_STATE_HOME:-$HOME/.local/state}/bot-panel-review-loop/reservations.db`),
  **outside** the skill dir so a deployed-copy re-sync can't clobber it. Leases
  are scoped by a `repo` column, so concurrent sweeps of different repos each
  get their own cap. WAL mode leaves `-wal`/`-shm` sidecars; wipe all three
  together.
- **Knobs:** `RESERVE_CAP` (default 3), `RESERVE_TTL` seconds (default 1800),
  `RESERVE_DB`; or `--cap`/`--ttl`/`--repo` flags.
- **Verbs:** `reserve <pr> <head>` → `ok`/`full`/`held` (one atomic
  `BEGIN IMMEDIATE` txn, so the cap holds under concurrent callers);
  `release <pr>`; `renew <pr>`; `list` (TSV: pr, head, age, expires_in);
  `slots`; `gc`; and the cron singleton `sweep-lock <ttl>` / `sweep-renew <ttl>`
  / `sweep-unlock`. Run `bash <skill-dir>/reserve.sh --help` for the full list.
- **Inspect / unstick:** `reserve.sh list` shows what is mid-review;
  `reserve.sh release <pr>` frees a slot by hand; `reserve.sh gc` reclaims
  expired leases (also done implicitly on every `reserve`/`list`/`slots`).

## Panel composition

- The panel is **pinned to three panelists** by this skill: every
  `/panel-review` call passes
  `--panelist claude --panelist codex --panelist claude/decompose`. `claude` and
  `codex` each do a standard whole-diff review; a second `claude` runs the
  `decompose` approach (chunk the diff, read each group closely, then a
  cross-boundary seam pass). Two strong, independent models plus a deep chunked
  pass.
- **`opencode-go/glm-5.2` is excluded** because it hit a weekly usage limit and
  returned empty output. It is excluded simply by **not being in the pinned
  roster** — there is nothing to configure.
- Because the skill pins `--panelist`, the `PANEL_REVIEW_PANELISTS` env var is
  **not honored**. `panel-review`'s precedence is
  `--panelist flags > PANEL_REVIEW_PANELISTS env > PATH auto-detect`, and the
  env fallback only fires when **no** `--panelist` flag is given
  (`panel-review.sh`:
  `if [[ ${#PANEL_IDS[@]} -eq 0 && -n "$PANEL_REVIEW_PANELISTS" ]]`). So no
  `~/.zshenv` setup is needed, and any `PANEL_REVIEW_PANELISTS` already in your
  environment is ignored by this loop.
- To change the roster, edit the `--panelist` flags in `SKILL.md` (Step 4a); to
  re-add opencode once its limit resets, add `--panelist opencode`.

## Architecture (who does what)

| Layer                                 | Responsibility                                                                                                                                                                                                                                                                                                                |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| cron / `/loop`                        | Fires one sweep every ~5 min. Cron (primary): a local launchd/crontab `claude -p` run per fire. `/loop` (fallback): dynamic `ScheduleWakeup` self-pacing.                                                                                                                                                                     |
| `/bot-panel-review-loop` (this skill) | ONE sweep: `select-prs.sh` to pick PRs, dispatch one sub-agent per PR, `pr-actions.sh` for all GitHub calls. Does NOT schedule; pins the panel via `--panelist` (claude + codex + claude/decompose). Owns the cap via `reserve.sh` (reserve at dispatch, release on sub-agent return); under cron, also holds the sweep-lock. |
| `reserve.sh` (bundled)                | The durable cap + in-flight lease table (SQLite); driver-only (`reserve`/`release`/`sweep-lock`). The per-PR sub-agent never touches it.                                                                                                                                                                                      |
| `panel-review` skill                  | Spawns the panelist CLIs (one throwaway git worktree per panelist on the shared `.git`); honors the `--panelist` flags this skill pins.                                                                                                                                                                                       |
| per-PR review sub-agent               | Reviews exactly one PR and posts results back. Does NOT load this skill — it only gets the brief the driver hands it plus the absolute path to `pr-actions.sh`.                                                                                                                                                               |

## Per-PR review lifecycle (what each sub-agent does)

The driver brackets the sub-agent with the lease —
`[driver: reserve <pr> <head>]` before dispatch and `[driver: release <pr>]`
when the sub-agent returns (any outcome). The sub-agent itself does, and knows,
none of that:

`confirm <pr> <head>` (bail on skip/defer) -> `react` (adds 👀) ->
`/panel-review --pr <n> --panelist claude --panelist codex --panelist claude/decompose`
(gather-only, run synchronously) -> judge findings + mandatory adversarial
refute on any surviving HIGH/CRITICAL -> `threads` dedup -> post new inline FIX
comments -> post one `summary` comment (must carry
`<!-- bot-panel-review-loop: head=<sha> -->`) -> `settle` the reaction.

## Selection gates (handled by `select-prs.sh`)

Open and not an unlabeled draft; passes own/dependabot flag filters; engagement
is NEW or UPDATED (SEEN = already reviewed at this head -> skip); no merge
conflict (CONFLICTING -> skip, UNKNOWN -> defer); CI green (pending -> defer,
red -> skip).

## Reaction semantics + stale-🚀 on re-reviews

- `settle approve` -> deletes the bot's 👀 and posts 🚀 (idempotent).
- `settle comments` -> leaves 👀, touches no reactions.
- A PR can be approved (🚀), then the author pushes again -> it re-surfaces as
  UPDATED at a new head with a **stale 🚀 from the old head**. On the re-review:
  re-approve keeps the 🚀; if the verdict **downgrades** to do-not-approve, the
  driver/agent must DELETE the stale 🚀 by id
  (`gh api -X DELETE repos/<owner>/<repo>/issues/<n>/reactions/<id>`) after
  `settle comments`.

## Operational gotchas

- **Shared-`.git` worktree race.** Each panel makes one worktree per panelist on
  the single `.git` (three panelists -> three worktrees per PR, up to nine at
  cap 3). Concurrent reviews multiply `git worktree add/remove` contention; a
  panel can **silently produce no output** (empty out-dir) under contention
  (observed with two PRs dispatched together). The lease says "slot held", not
  "panel produced output", so on each sweep/completion sanity-check in-flight
  panels have a live proc or non-empty out-dir, and re-dispatch any silent miss
  **under its existing lease** (the slot is already held — do not re-`reserve`,
  which returns `held`).
- **Lease and marker are separate durable state.** The `head=` summary marker is
  the _completed-review_ dedup (lives on GitHub, read by `select-prs.sh` for
  NEW/UPDATED/SEEN). The `reserve.sh` lease is the _in-flight_ cap (lives in
  local SQLite). A missing/wrong marker causes infinite re-review; a missing
  `release` pins a slot. Different stores, different failure modes — don't
  conflate them.
- **Stuck slot vs TTL.** Every `reserve` needs a `release` (on any sub-agent
  return, or on dispatch failure); the tick-start reconcile (`list` vs
  SEEN-at-head) is the safety net if the driver's context compacted mid-flight.
  The TTL only reclaims a slot after a true crash, and at the 30-min default a
  legitimately slow (10-15 min) panel is never GC'd; `renew` only if a review
  approaches the TTL.
- **WAIT, do not re-dispatch.** A sub-agent that rests saying "panelists still
  running" is usually SLOW, not dead (decompose panels take ~10-15 min). Wait
  for it to self-resume; check PR state (latest summary marker, reactions)
  before ever re-dispatching, or you race a duplicate panel/summary. If a panel
  is confirmed done-but-agent-silent, you can nudge the agent (SendMessage) or
  synthesize from the completed out-dir rather than re-running the panel.
- **Summary marker is mandatory.** Every summary must carry `head=<full sha>`;
  the prefilter's engagement check reads the most recent marker to compute
  NEW/UPDATED/SEEN. A missing/wrong marker causes infinite re-review.
- **claude model alias.** Observed once: the claude panelist was launched with a
  `opus-4.8` alias the CLI rejected and had to be relaunched with `opus`. If it
  recurs, fix the claude model alias in `panel-review`'s config (a wrong alias
  could silently drop the claude panelist, leaving codex-only).
- **Em-dash-free prose.** All posted comments/summaries use
  colons/commas/parens, no em dashes (repo user-facing-copy convention).

## Where things live / deploying a change

- **Source (this repo):**
  `~/source/catena/dev-skills/skills/bot-panel-review-loop`.
- **Deployed copy:** `~/.agents/skills/bot-panel-review-loop`, which
  `~/.claude/skills/bot-panel-review-loop` symlinks to. This is a **separate
  copy** from the source — editing the source does not change live behavior
  until it is synced/installed into `~/.agents/skills`. (Confirm the project's
  install/sync step; the two can drift.)
- **Lease DB + logs:**
  `${XDG_STATE_HOME:-~/.local/state}/bot-panel-review-loop/` holds
  `reservations.db` (plus its `-wal`/`-shm` sidecars) and, for the cron
  entrypoint, `sweep.log`. Machine-local, not in this repo — a new operator's
  box starts empty (the table is created on first `reserve`).

## Cron setup (local)

The primary entrypoint is a **local** 5-min cron; it must run on this machine
because the panel CLIs, the git worktrees, and the lease DB are all here
(`/schedule` runs in the cloud and cannot see them). Each fire is one
self-draining singleton sweep:

```bash
#!/usr/bin/env bash
# launchd StartInterval=300, or crontab: */5 * * * *
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0   # REQUIRED: the 10-min default would cut off a 15-min panel
export BASH_MAX_TIMEOUT_MS=600000               # headroom for any long bash in a sub-agent
cd /path/to/target-repo                          # repo context for gh + worktrees
timeout 5400 claude -p "/bot-panel-review-loop" \
  --permission-mode acceptEdits \
  --allowedTools "Bash,Read,Grep,Glob,Skill,Agent,TodoWrite" \
  >> "$HOME/.local/state/bot-panel-review-loop/sweep.log" 2>&1
```

- `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is mandatory: without it `claude -p`
  stops waiting on a background review after 10 min and cuts the sweep off
  mid-panel.
- The sweep self-guards with `reserve.sh sweep-lock <ttl>`, so overlapping fires
  are no-ops. The lock TTL must exceed both the cron interval and the renew
  period — lock `600`s, `sweep-renew 600` every ~`120`s during the drain. A
  crash kills the session-scoped sub-agents and lets the lock + leases expire by
  TTL, so a later fire never collides with still-live work.
- Confirm `claude`/`gh` auth works unattended, and that env vars come from the
  cron environment (launchd/crontab), not an interactive login shell.

## How another dev picks this up

1. Install on `PATH` and authenticate: `codex`, `claude`, `gh` (for the target
   repo), and **`sqlite3`** (ships on macOS and every Linux; the lease DB needs
   it). The skill pins the panel to `claude + codex + claude/decompose`, so
   opencode is excluded automatically — no `PANEL_REVIEW_PANELISTS` setup
   needed.
2. `cd` into the target repo (e.g. `catena-labs/bank`).
3. Install the local cron (see "Cron setup" above): a launchd/crontab job that
   runs `claude -p "/bot-panel-review-loop"` every ~5 min with
   `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. For an interactive run instead, use
   `/loop /bot-panel-review-loop` (the fallback).
4. Sanity-check with `reserve.sh list` (what is mid-review) and tail
   `sweep.log`; the operating model above is the policy either entrypoint
   follows.
