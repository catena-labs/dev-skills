# bot-panel-review-loop

Sweep, review, and babysit the open PRs in a repo. One invocation = one
fleet-wide sweep: it selects the actionable PRs, then **dispatches one fresh
agent per PR** to run a gather-only panel review and post advisory findings back
to GitHub. It is **read-only toward your code** — it never edits, commits, or
pushes. Its only side effects are GitHub reactions and comments.

Designed to be the body of a `/loop`, so you start it once and it keeps sweeping
on an interval, picking up new and updated PRs as they land.

## How to run it

Run it from inside the target repo (it resolves the repo via `gh`). Drive it
with the `/loop` command so each tick is one fleet-wide sweep:

```bash
# Continuous: re-sweep the repo on an interval, picking up new and updated PRs.
/loop /bot-panel-review-loop

# One-off: a single sweep, then stop.
/bot-panel-review-loop

# Flags pass straight through (see "Flags" below).
/loop /bot-panel-review-loop --exclude-own --dependabot
```

Per-PR engagement markers (an HTML comment the skill posts on each PR) keep it
from re-reviewing a PR it already covered at the same head, so it is safe to
loop indefinitely.

### Flags

- `--exclude-own` — skip PRs you authored (default: include them).
- `--dependabot` — include Dependabot PRs (default: skip them).

Every PR is reviewed at the same depth — there is no depth flag. Each review
runs `panel-review` with
`--panelist claude --panelist codex --panelist claude/decompose`, so the panel
is three panelists: claude and codex each do a standard whole-diff review, plus
a second claude chunks the diff and adds a cross-boundary seam pass (the
`decompose` approach). It self-scales with diff size, so small PRs stay cheap.

Already-approved PRs are reviewed by default (the engagement marker still keeps
it from re-reviewing one at the same head).

## Install

```
npx skills add catena-labs/dev-skills --skill bot-panel-review-loop
```

Each per-PR agent runs a gather-only
[`panel-review`](https://github.com/catena-labs/dev-skills/tree/main/skills/panel-review)
(read-only; one of its three panelists uses the `decompose` approach), so
install it too:

```
npx skills add catena-labs/dev-skills --skill panel-review
```

You also need `gh` authenticated against the target repo and `sqlite3` on `PATH`
for the reservation and metrics databases.

## What it does

- **Selects the actionable PRs deterministically.** A bundled `select-prs.sh`
  prefilter applies every no-judgment gate (draft / flag filters / merge
  conflict / engagement marker / CI status) in one script, so the bulky `gh`
  JSON never enters the model's context. A PR is reviewed only if it is open,
  not a draft (unless labeled `ready for review`), passes the flag filters, is
  NEW or UPDATED since the last review, has no merge conflicts, and has green
  CI.
- **Dispatches one fresh agent per PR.** Each agent reacts 👀, runs a
  gather-only panel review of that PR's diff (claude + codex holistic, plus a
  third claude running `decompose` for a scoped-chunk-plus-seam-pass deep read),
  and posts back. A second bundled script, `pr-actions.sh`, carries the per-PR
  GitHub plumbing (re-confirm live state, react, fetch existing threads, post
  comments, post the summary, settle the reaction), so the agent never
  hand-assembles `gh`/`graphql` or escapes comment JSON itself.
- **Posts inline fix suggestions** at the correct file + line, with one-click
  ` ```suggestion ` blocks where the fix is concrete.
- **Posts a concise approve / do-not-approve summary** per PR. The visible body
  is just the verdict, the panel (which panelists ran), and the head; everything
  else — the findings lists and a human-review note for sensitive surfaces
  (auth, money movement, schema, secrets) — folds into collapsible `<details>`
  sections. It then swaps its 👀 reaction to 🚀 on an approve verdict (leaving
  👀 when it left comments). On a re-review that downgrades a prior approve, it
  also clears the now-stale 🚀 so the reaction never advertises a withdrawn
  approval.
- **Tracks engagement (NEW / UPDATED / SEEN)** via a marker comment, so it
  re-reviews the whole PR only when it has new commits and never re-posts an
  inline finding already on the PR. Each review still leaves a fresh summary
  comment, so the PR keeps a running history of verdicts.
- **Tracks reviewer effectiveness in SQLite.** A bundled `metrics.sh` ledger
  records which panelist raised each synthesized finding, whether the judging
  agent verified it, whether it was posted or already covered, and whether the
  PR owner later fixed, acknowledged, rejected, or superseded it. It also counts
  missed opportunities: verified findings a panelist did not raise, and
  externally discovered issues that no panelist caught. The rollup is local
  operator telemetry, not posted to PRs.

## What it does NOT do

- **Never changes your code.** No edits, no commits, no pushes — the only side
  effects are GitHub reactions and comments. Advisory by design.
- **Never checks out branches or runs tests locally.** "CI passing" means CI is
  green on GitHub; running the fleet's tests locally would be too expensive.
- **Never formally approves.** It posts an advisory approve/do-not-approve
  verdict as a comment; the actual GitHub approval stays a human action.

## Gotchas

- **It loops; engagement markers are how it stays sane.** It recognizes its own
  prior marker (and the legacy `panel-review-prs` marker, for repos reviewed
  before the rename) so a re-sweep skips unchanged PRs. Don't delete those
  marker comments unless you want a PR re-reviewed.
- **Each actionable PR costs a full fan-out.** A per-PR agent runs
  `panel-review` (three CLI panelists — claude, codex, and a second claude on
  `decompose` — minutes of wall clock); the decompose pass is its own panelist
  process and worktree, not a longer prompt on an existing one, so each PR
  materializes three worktrees. Concurrency is a loose cap of 3 reviews in
  flight, checked only at dispatch and tracked across `/loop` ticks; a busy repo
  sweep still takes a while. See `OPERATING.md` for the in-flight-tracking and
  top-up model.
- **A thin panel is possible.** The panel is `claude` + `codex` + a second
  `claude` on `decompose`; a CLI missing from `PATH`, or one that returns a
  `done (exit N) — FAILED: …` heartbeat, silently shrinks the panel, and the
  summary's **Panel** line flags it.
- **Metrics need a final outcome pass.** `metrics.sh pending-owner` lists
  verified FIX findings whose owner outcome is still unknown. A later sweep
  should mark them `fixed`, `acknowledged`, `rejected`, or `superseded` once the
  PR owner acts or the PR merges. If a human reviewer, CI, the owner, or a later
  review finds a real issue the panel missed, record it with
  `metrics.sh missed ...` so reviewer recall is measurable.
