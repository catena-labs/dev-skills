# Bot Panel Review Loop — Operating Runbook

How to pick up and run the automated PR-review loop. This is the *operating
model* (cadence, concurrency, panel composition, gotchas); for the mechanics of a
single sweep see `SKILL.md` in this directory.

## What it is

`/bot-panel-review-loop` runs **one fleet-wide sweep** of the repo's open PRs: it
selects the actionable ones and dispatches **one fresh review sub-agent per PR**.
Each sub-agent runs a multi-model `panel-review` (approach: decompose), posts
advisory inline comments plus one summary comment, and settles a GitHub reaction.
The loop **never changes code** — its only side effects are GitHub comments and
reactions.

It is meant to be driven continuously by `/loop`:

```
/loop /bot-panel-review-loop
```

`/loop` with no interval runs in *dynamic mode* — the driver (the main agent)
self-paces with `ScheduleWakeup` and decides what to dispatch each tick.

## Operating model (the policy a driver must follow)

1. **Cadence: wake ~every 5 min (270s) on every tick**, regardless of what is
   running. One uniform heartbeat. (Sub-agent completion notifications also wake
   the loop immediately and free a slot; the 270s timer is the steady cadence
   between them.)
2. **Concurrency: up to 3 reviews running at once — a loose cap.** Checked only
   at dispatch time: do not start a new review if 3 are already in flight. Never
   kill or interrupt an in-flight review to honor the cap.
3. **Skip in-flight PRs.** `select-prs.sh` cannot tell you what is mid-review: a
   PR being reviewed still shows NEW/UPDATED because its new `head=` marker is
   not posted until the review finishes. So the driver must track an in-flight
   set of `{PR number -> sub-agent id}` across ticks, exclude those PRs from new
   dispatch, and drop a PR from the set when its agent reports completion.
4. **Top up each tick:** `available = 3 - len(in_flight)`; dispatch up to
   `available` of the actionable-and-not-in-flight PRs.

## Panel composition

- Panels currently run **codex + claude only**. `opencode-go/glm-5.2` is
  **excluded** because it hit a weekly usage limit and returned empty output
  (presented as a perpetual laggard).
- The exclusion is done with an env var read by `panel-review`, set in
  **`~/.zshenv`** (NOT in this repo, and NOT in `.zprofile`/`.zshrc` — only
  `.zshenv` is sourced by the `zsh -c` that launches each panel subprocess):

  ```sh
  export PANEL_REVIEW_PANELISTS="codex claude"
  ```

- Panelist selection lives in the **`panel-review`** skill, not here. Its
  precedence is `--panelist flags > PANEL_REVIEW_PANELISTS env > PATH
  auto-detect (codex, claude, opencode)`. Editing `bot-panel-review-loop` cannot
  change the panel; change the env var (or pass `--panelist` on the
  `/panel-review` call, or edit `panel-review.sh`'s auto-detect list).
- To re-enable opencode once its limit resets: remove the `~/.zshenv` line.

## Architecture (who does what)

| Layer | Responsibility |
|---|---|
| `/loop` (bundled skill) | Drives the cadence via `ScheduleWakeup`. Owns the 5-min heartbeat. |
| `/bot-panel-review-loop` (this skill) | ONE sweep: `select-prs.sh` to pick PRs, dispatch one sub-agent per PR, `pr-actions.sh` for all GitHub calls. Does NOT schedule and does NOT pick panelists. Owns the 3-concurrent cap (it is the dispatcher). |
| `panel-review` skill | Spawns the panelist CLIs (one throwaway git worktree per panelist on the shared `.git`) and picks the panel composition. |
| per-PR review sub-agent | Reviews exactly one PR and posts results back. Does NOT load this skill — it only gets the brief the driver hands it plus the absolute path to `pr-actions.sh`. |

## Per-PR review lifecycle (what each sub-agent does)

`confirm <pr> <head>` (bail on skip/defer) -> `react` (adds 👀) ->
`/panel-review --pr <n> --approach decompose` (gather-only, run synchronously) ->
judge findings + mandatory adversarial refute on any surviving HIGH/CRITICAL ->
`threads` dedup -> post new inline FIX comments -> post one `summary` comment
(must carry `<!-- bot-panel-review-loop: head=<sha> -->`) -> `settle` the
reaction.

## Selection gates (handled by `select-prs.sh`)

Open and not an unlabeled draft; passes own/dependabot flag filters; engagement
is NEW or UPDATED (SEEN = already reviewed at this head -> skip); no merge
conflict (CONFLICTING -> skip, UNKNOWN -> defer); CI green (pending -> defer, red
-> skip).

## Reaction semantics + stale-🚀 on re-reviews

- `settle approve` -> deletes the bot's 👀 and posts 🚀 (idempotent).
- `settle comments` -> leaves 👀, touches no reactions.
- A PR can be approved (🚀), then the author pushes again -> it re-surfaces as
  UPDATED at a new head with a **stale 🚀 from the old head**. On the re-review:
  re-approve keeps the 🚀; if the verdict **downgrades** to do-not-approve, the
  driver/agent must DELETE the stale 🚀 by id (`gh api -X DELETE
  repos/<owner>/<repo>/issues/<n>/reactions/<id>`) after `settle comments`.

## Operational gotchas

- **Shared-`.git` worktree race.** Each panel makes one worktree per panelist on
  the single `.git`. Concurrent reviews multiply `git worktree add/remove`
  contention; a panel can **silently produce no output** (empty out-dir) under
  contention (observed with two PRs dispatched together). At cap 3 this is more
  likely. On each sweep/completion, sanity-check in-flight panels have a live
  proc or non-empty out-dir and re-dispatch any silent miss. This is why the cap
  is "loose" — throughput vs a small silent-failure risk.
- **WAIT, do not re-dispatch.** A sub-agent that rests saying "panelists still
  running" is usually SLOW, not dead (decompose panels take ~10-15 min). Wait for
  it to self-resume; check PR state (latest summary marker, reactions) before
  ever re-dispatching, or you race a duplicate panel/summary. If a panel is
  confirmed done-but-agent-silent, you can nudge the agent (SendMessage) or
  synthesize from the completed out-dir rather than re-running the panel.
- **Summary marker is mandatory.** Every summary must carry
  `head=<full sha>`; the prefilter's engagement check reads the most recent
  marker to compute NEW/UPDATED/SEEN. A missing/wrong marker causes infinite
  re-review.
- **claude model alias.** Observed once: the claude panelist was launched with a
  `opus-4.8` alias the CLI rejected and had to be relaunched with `opus`. If it
  recurs, fix the claude model alias in `panel-review`'s config (a wrong alias
  could silently drop the claude panelist, leaving codex-only).
- **Em-dash-free prose.** All posted comments/summaries use colons/commas/parens,
  no em dashes (repo user-facing-copy convention).

## Where things live / deploying a change

- **Source (this repo):** `~/source/catena/dev-skills/skills/bot-panel-review-loop`.
- **Deployed copy:** `~/.agents/skills/bot-panel-review-loop`, which
  `~/.claude/skills/bot-panel-review-loop` symlinks to. This is a **separate
  copy** from the source — editing the source does not change live behavior until
  it is synced/installed into `~/.agents/skills`. (Confirm the project's
  install/sync step; the two can drift.)
- **`~/.zshenv`** holds `PANEL_REVIEW_PANELISTS` (the opencode exclusion). It is
  user-level config, not in this repo — a new operator must set it themselves.

## How another dev picks this up

1. Have the `codex` and `claude` CLIs installed, on `PATH`, and authenticated
   (and `gh` authenticated for the target repo).
2. Add `export PANEL_REVIEW_PANELISTS="codex claude"` to `~/.zshenv` (drops the
   rate-limited opencode panelist).
3. `cd` into the target repo (e.g. `catena-labs/bank`).
4. Run `/loop /bot-panel-review-loop`.
5. Drive it per the operating model above: ~5-min sweeps, up to 3 concurrent
   reviews, skip in-flight PRs, watch for silent panel misses, handle stale-🚀 on
   re-reviews.
