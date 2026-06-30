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

Reviewer effectiveness lives in a separate SQLite metrics ledger (`metrics.sh`).
It records finding provenance, verification, posting/dedupe, missed findings,
and eventual PR-owner outcomes, scoped by repo and PR head.

## Operating model (the policy a driver must follow)

1. **Cadence.** Under cron, each fire is one self-draining sweep that runs to
   completion and exits; a `sweep-lock` makes overlapping 5-min fires no-ops.
   Under `/loop`, wake ~every 5 min (`270s`) on every tick; a sub-agent
   completion also wakes the loop and frees a slot.
2. **Concurrency: a durable cap of 3 via `reserve.sh`**, not counting in your
   head. `reserve <pr> <head>` before dispatch → `ok` dispatch, `full` stop this
   tick, `held` skip. The lease table is the in-flight truth (no `{PR -> agent}`
   map to carry), so `held` also covers a PR `select-prs.sh` still shows
   NEW/UPDATED while it's mid-review. Never kill an in-flight review.
3. **Release on return; reconcile each tick.** `release <pr>` on any sub-agent
   return or a failed dispatch; the TTL (30 min) is only a crash backstop. At
   each sweep start, reconcile a compacted driver: `release` any lease whose PR
   the prefilter now reports SEEN-at-head (its summary marker landed).

## Reservations (the lease table)

`reserve.sh` (bundled, beside `select-prs.sh`/`pr-actions.sh`) is the durable
cap and in-flight set; the **driver** calls it, the sub-agent never does. Verbs,
knobs (`RESERVE_CAP`/`RESERVE_TTL`/`RESERVE_DB`), and defaults live in
`reserve.sh --help`. The operator facts not in there:

- **State lives outside the skill dir** (so a deployed-copy re-sync can't
  clobber it) and is scoped by a `repo` column, so concurrent sweeps of
  different repos each get their own cap. WAL mode leaves `-wal`/`-shm`
  sidecars; wipe all three together. Path and logs are under "Where things live"
  below.
- **Inspect / unstick:** `reserve.sh list` shows what's mid-review;
  `reserve.sh release <pr>` frees a slot by hand; `gc` reclaims expired leases
  (also implicit on every `reserve`/`list`/`slots`).

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
  **not honored** (panel-review precedence is `--panelist` > env > PATH
  auto-detect; the env fallback fires only when no `--panelist` is passed). So
  no `~/.zshenv` setup is needed; any `PANEL_REVIEW_PANELISTS` in your env is
  ignored by this loop.
- To change the roster, edit the `--panelist` flags in `SKILL.md` (Step 4a); to
  re-add opencode once its limit resets, add `--panelist opencode`.

## Architecture (who does what)

| Layer                                 | Responsibility                                                                                                                                                                                                                                                                                                                |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| cron / `/loop`                        | Fires one sweep every ~5 min. Cron (primary): a local launchd/crontab `claude -p` run per fire. `/loop` (fallback): dynamic `ScheduleWakeup` self-pacing.                                                                                                                                                                     |
| `/bot-panel-review-loop` (this skill) | ONE sweep: `select-prs.sh` to pick PRs, dispatch one sub-agent per PR, `pr-actions.sh` for all GitHub calls. Does NOT schedule; pins the panel via `--panelist` (claude + codex + claude/decompose). Owns the cap via `reserve.sh` (reserve at dispatch, release on sub-agent return); under cron, also holds the sweep-lock. |
| `reserve.sh` (bundled)                | The durable cap + in-flight lease table (SQLite); driver-only (`reserve`/`release`/`sweep-lock`). The per-PR sub-agent never touches it.                                                                                                                                                                                      |
| `metrics.sh` (bundled)                | The local SQLite effectiveness ledger: per-run panelist availability, per-finding sources, verification, publication, missed findings, and owner outcome. Per-PR sub-agents write run/finding rows; later sweeps close owner outcomes and externally discovered misses.                                                       |
| `panel-review` skill                  | Spawns the panelist CLIs (one throwaway git worktree per panelist on the shared `.git`); honors the `--panelist` flags this skill pins.                                                                                                                                                                                       |
| per-PR review sub-agent               | Reviews exactly one PR and posts results back. Does NOT load this skill — it only gets the brief the driver hands it plus the absolute paths to `pr-actions.sh` and `metrics.sh`.                                                                                                                                             |

## Per-PR review lifecycle (what each sub-agent does)

The driver brackets the sub-agent with the lease —
`[driver: reserve <pr> <head>]` before dispatch and `[driver: release <pr>]`
when the sub-agent returns (any outcome). The sub-agent itself does, and knows,
none of that:

`confirm <pr> <head>` (bail on skip/defer) -> `react` (adds 👀) ->
`metrics.sh run-start` ->
`/panel-review --pr <n> --panelist claude --panelist codex --panelist claude/decompose`
(gather-only, run synchronously) -> record panelist heartbeats in metrics ->
judge findings + record sources in metrics -> mandatory adversarial refute on
any surviving HIGH/CRITICAL -> mark verification/judgment in metrics ->
`threads` dedup -> post new inline FIX comments and mark publication in metrics
-> post one `summary` comment (must carry
`<!-- bot-panel-review-loop: head=<sha> -->`) -> `settle` the reaction.

## Effectiveness metrics

`metrics.sh` stores reviewer-effectiveness telemetry in
`${XDG_STATE_HOME:-~/.local/state}/bot-panel-review-loop/metrics.db` (WAL mode,
with `-wal`/`-shm` sidecars). It is separate from the reservation DB so a stuck
lease cannot corrupt historical effectiveness data.

Record every synthesized candidate finding, including false positives and
findings the judge foregoes. Volume alone is not useful; the important rates are
verified/found, false positives/found, missed opportunities, recall,
fix-recommended/verified, posted-or-covered/fix-recommended, and
owner-fixed-or-acknowledged/fix recommended. Also record failed or missing
panelists so availability is visible.

Misses have two sources. First, the rollup counts a miss for any contributed
panelist that did not raise a verified FIX finding another panelist raised.
Second, if a human reviewer, CI, PR owner, later bot review, or post-merge
incident finds a real issue that no panelist raised, record it with
`metrics.sh missed ...`; it counts as missed by every contributed panelist in
that run. Use `metrics.sh runs <pr>` if a later sweep needs to recover the right
run id for a PR head.

Owner outcomes are often knowable only later. Each sweep should run
`metrics.sh pending-owner` and inspect old verified FIX findings. Mark: `fixed`
when a later commit/metadata change addresses it, `acknowledged` when the owner
explicitly accepts or resolves it, `rejected` when the PR merges or closes with
the issue still applicable, and `superseded` when a later head or later bot
finding replaces it. Use `metrics.sh reviewer-stats` for the local rollup; do
not post this telemetry to PRs.

## Selection gates (handled by `select-prs.sh`)

Open and not an unlabeled draft; passes own/dependabot flag filters; engagement
is NEW or UPDATED (SEEN = already reviewed at this head -> skip); no merge
conflict (CONFLICTING -> skip, UNKNOWN -> defer); CI green (pending -> defer,
red -> skip).

## Reaction semantics + stale-🚀 on re-reviews

- `settle approve` -> deletes the bot's 👀 and posts 🚀 (idempotent).
- `settle comments` -> leaves 👀 and clears the bot's own stale 🚀 if one
  exists.
- A PR can be approved (🚀), then the author pushes again -> it re-surfaces as
  UPDATED at a new head with a **stale 🚀 from the old head**. On the re-review:
  re-approve keeps the 🚀; if the verdict **downgrades** to do-not-approve,
  `settle comments` deletes the stale bot 🚀 itself and leaves 👀 in place.

## Operational gotchas

- **Shared-`.git` worktree race.** Concurrent panels contend on the single
  `.git` (three worktrees per PR, up to nine at cap 3) and one can **silently
  produce an empty out-dir** (observed with two PRs dispatched together). The
  lease tracks "slot held", not "panel produced output", so sanity-check
  in-flight panels each sweep and re-dispatch a silent miss **under its existing
  lease** (don't re-`reserve`, which returns `held`).
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
  `reservations.db` and `metrics.db` (plus their `-wal`/`-shm` sidecars) and,
  for the cron entrypoint, `sweep.log`. Machine-local, not in this repo — a new
  operator's box starts empty (tables are created on first use).

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
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/bot-panel-review-loop"
mkdir -p "$state_dir"
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$timeout_bin" ]]; then
  echo "Install GNU coreutils for timeout/gtimeout (macOS: brew install coreutils)" >&2
  exit 1
fi
"$timeout_bin" 5400 claude -p "/bot-panel-review-loop" \
  --permission-mode acceptEdits \
  --allowedTools "Bash,Read,Grep,Glob,Skill,Agent,TodoWrite" \
  >> "$state_dir/sweep.log" 2>&1
```

- `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0` is mandatory: without it `claude -p`
  stops waiting on a background review after 10 min and cuts the sweep off
  mid-panel.
- The sweep self-guards with `reserve.sh sweep-lock <ttl>`, so overlapping fires
  are no-ops. Capture the token from `ok <token>` and pass it to
  `sweep-renew <token> 600` every ~`120`s during the drain, then
  `sweep-unlock <token>` on exit; the token prevents an expired owner from
  mutating a newer sweep's lock. The lock TTL must exceed both the cron interval
  and the renew period. A crash kills the session-scoped sub-agents and lets the
  lock + leases expire by TTL, so a later fire never collides with still-live
  work.
- Confirm `claude`/`gh` auth works unattended, and that env vars come from the
  cron environment (launchd/crontab), not an interactive login shell.

## How another dev picks this up

1. Install on `PATH` and authenticate: `codex`, `claude`, `gh` (for the target
   repo), a GNU timeout command (`timeout` on Linux or `gtimeout` from
   `brew install coreutils` on macOS), and **`sqlite3`** (ships on macOS and
   every Linux; the lease DB needs it — if missing, `brew install sqlite` on
   macOS or `apt-get install sqlite3` on Debian/Ubuntu). The skill pins the
   panel to `claude + codex + claude/decompose`, so opencode is excluded
   automatically — no `PANEL_REVIEW_PANELISTS` setup needed.
2. `cd` into the target repo (e.g. `catena-labs/bank`).
3. Install the local cron (see "Cron setup" above): a launchd/crontab job that
   runs `claude -p "/bot-panel-review-loop"` every ~5 min with
   `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. For an interactive run instead, use
   `/loop /bot-panel-review-loop` (the fallback).
4. Sanity-check with `reserve.sh list` (what is mid-review) and tail
   `sweep.log`; the operating model above is the policy either entrypoint
   follows.
