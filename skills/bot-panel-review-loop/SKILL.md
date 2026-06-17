---
name: bot-panel-review-loop
description:
  Use when asked to sweep, review, or babysit the open PRs in a repo with a
  panel review and post advisory findings. For each open, CI-green,
  not-yet-approved PR that is either non-draft or a draft labeled "ready for
  review", dispatch a fresh per-PR agent that reacts 👀, runs a gather-only
  panel review, posts inline PR comments at the correct file+line suggesting
  fixes, posts a concise approve/do-not-approve summary (findings and a
  human-review note for sensitive surfaces — auth, money movement, schema,
  secrets — folded into collapsible sections), and swaps its 👀 reaction to 🚀
  on an approve verdict (leaving 👀 when it left comments). Tracks engagement
  (NEW / UPDATED / SEEN) and posts each comment at most once (never re-posting
  one already on the PR or one a human resolved; the summary is upserted), so it
  doesn't repeat work. Read-only toward the code: it never edits, commits, or
  pushes. Designed to be the body of `/loop /bot-panel-review-loop`.
allowed-tools:
  Bash, Read, Grep, Glob, Skill, Agent, TodoWrite, AskUserQuestion, ScheduleWakeup
argument-hint: "[--all] [--exclude-own] [--dependabot]"
---

# Bot Panel Review Loop

One invocation = one fleet-wide sweep of the repo's open PRs. The sweep selects
the actionable PRs, then **dispatches one fresh agent per PR** to review it and
post advisory comments back. **This skill never changes the code** — no edits,
no commits, no pushes. Its only side effects are GitHub reactions and comments.

Two bundled scripts carry every deterministic, no-judgment step so the bulky
`gh`/`jq`/`graphql` plumbing never enters the model's context and the JSON is
never hand-escaped:

- **`select-prs.sh`** (Step 1) — selection: which PRs are actionable this tick.
- **`pr-actions.sh`** (Step 4) — per-PR GitHub calls: re-confirm live state,
  react, fetch existing threads, post comments, upsert the summary, settle the
  reaction. Run `bash <skill-dir>/pr-actions.sh --help` for the verb list.

The model keeps the judgment (which findings are real, the verdict, the comment
and summary bodies); the scripts keep the plumbing.

## Running it

Run it from inside the target repo (it resolves the repo via `gh`). It is built
to be driven by `/loop`, so each tick is one fleet-wide sweep:

```bash
# Continuous: re-sweep the repo on an interval, picking up new and updated PRs.
/loop /bot-panel-review-loop

# One-off: a single sweep, then stop.
/bot-panel-review-loop

# Flags pass straight through (see "Flags" below).
/loop /bot-panel-review-loop --all --exclude-own --dependabot
```

Per-PR engagement markers keep it from re-reviewing a PR it already covered at
the same head.

## Flags

- `--all` — include already-approved PRs (default: skip approved).
- `--exclude-own` — skip PRs you authored (default: include them).
- `--dependabot` — include Dependabot PRs (default: skip them).

## Selection gates (a PR is reviewed only if ALL hold)

These are the canonical gate definitions; later steps reference them by number.

1. **Open, and not a draft unless labeled `ready for review`.** Drafts are the
   author's WIP, so they're ignored entirely — no report row at all — except a
   draft carrying the `ready for review` label, which the author has explicitly
   opted into review, so it runs the same remaining gates as an active PR.
   Re-confirmed live just before dispatch (Step 4a), since enumeration only
   proves a PR was open _then_.
2. **Passes the flag filters** above (own / approved / dependabot).
3. **Engagement is NEW or UPDATED** (classified by the Step 1 prefilter). `SEEN`
   (already reviewed at this exact head, nothing new) is skipped — re-posting
   identical findings every tick is this skill's cardinal sin.
4. **No merge conflicts.** `mergeable == CONFLICTING` → skip, report "skipped
   (merge conflict)": a PR that can't merge cleanly will be rebased, changing
   the diff a panel would review. `mergeable == UNKNOWN` (GitHub hasn't computed
   mergeability yet) → defer to a later tick, same as pending CI.
5. **CI / tests passing.** Pending → defer. Failing → skip, report "skipped (CI
   red)". A broken PR is not worth a panel's time. "Passing" means CI is green —
   the sweep never checks out branches or runs tests locally (too expensive
   across a fleet).

## Step 1: Select the actionable PRs (prefilter script)

Run the prefilter. It applies every selection gate that needs no judgment (draft
/ flag filters / merge conflict / engagement marker / incremental compare / CI
status) inside one script, so the `gh pr list` JSON, the per-PR marker reads,
and the CI-check output never enter your context:

```bash
# Replace <skill-dir> with this skill's base directory (printed as
# "Base directory for this skill" when the skill loads).
bash <skill-dir>/select-prs.sh [--all] [--exclude-own] [--dependabot]
```

Pass through whatever flags the invocation received. The script prints two
sentinel-delimited sections:

- `===ACTIONABLE_JSON===` — a JSON array of the PRs that survived every gate,
  each `{number, title, head, engagement, prevReviewedHead, ci, note}`.
  `engagement` is `NEW` or `UPDATED`; `prevReviewedHead` is the watermark that
  scopes an UPDATED re-review (`null` for NEW); `note` flags a diverged/rebased
  full re-review or a PR with no CI checks. **This is the dispatch list for Step
  4** — one agent per entry.
- `===REPORT_TABLE===` — a prebuilt markdown table, one row per open PR
  (unlabeled drafts are dropped entirely, so they never appear). Every
  skipped/deferred row already carries its reason; each actionable row carries
  `PENDING_VERDICT`. **Keep it for Step 5** and replace each `PENDING_VERDICT`
  row with the verdict its agent returns.

If `ACTIONABLE_JSON` is `[]`, nothing needs a panel this tick — print the table
and go straight to Step 5.

Trust the script's output; only re-derive a disposition by hand (with
`gh pr list` / `gh api .../comments` / `gh pr checks`) if it errors or a result
is clearly wrong. Every no-judgment gate now lives inside it.

## Step 4: Dispatch one fresh agent per actionable PR

One fresh isolated context per PR, done as subagents: the sweep stays cheap and
each PR gets clean, uncontaminated context. Each agent owns exactly one PR, does
Steps 4a-4d, and returns a one-line verdict. Inherit the session model — don't
pin one; the judgment (which findings are real, the verdict) wants the strong
model. The subagent doesn't load this skill, so **pass it the absolute path to
`pr-actions.sh`** (the same `<skill-dir>` from Step 1) along with the brief.

**Bound concurrency to 2-3 PRs at a time.** Each review runs `panel-review.sh`,
which materializes one throwaway git worktree _per panelist_ under a `mktemp`
dir pinned to the PR head. Those linked worktrees share this repo's single
`.git`, so fanning out every PR at once means (PRs x panelists) concurrent
`git worktree add`/`remove` racing on `.git/worktrees` and index/config locks.
Dispatch in small batches (or sequentially if a batch errors on a git lock) —
fresh-context-per-PR is the goal, not maximum parallelism.

The skill never checks out a PR into your working tree; the diff arrives over
the GitHub API via `gh`, so nothing here scales with PR size. The review path
(`panel-review --pr {number}`) materializes the per-panelist ephemeral worktrees
and each panelist runs `gh pr diff` inside its own; the comment path (4b/4c)
fetches no diff at all — comments post optimistically and GitHub 422s off-diff
lines, and any per-finding sanity check pulls only that one path.

Give each agent the brief below, filling `{owner}/{repo}` and the entry's
`number` and `head` from `ACTIONABLE_JSON`. For an **UPDATED** entry also pass
its `prevReviewedHead` (scopes findings to the new commits); for **NEW** it is
`null`, so omit it. If the entry carries a `note` (rebased/diverged full
re-review, or no CI checks), pass it along so the agent can mention it.

### 4a. Re-confirm actionable, react 👀, gather findings, classify surfaces

Enumeration is a snapshot; minutes can pass before this agent runs, and a PR can
merge, close, convert to draft, or get a fresh push in that gap. **Re-resolve
live state first** and bail before touching GitHub if it's no longer the ready,
open PR you queued:

```bash
bash <skill-dir>/pr-actions.sh confirm {number} {head}    # {head} = the queued head
```

It prints one disposition line. Act on the first word:

- **`ok <head>`** → reviewable, at the expected head; proceed.
- **`skip ...`** → report the reason verbatim (`skipped (merged)` / `(closed)` /
  `(now draft)` / `(merge conflict)`) and stop — **do not react or post.** (A
  draft still carrying the `ready for review` label is reviewable, so `confirm`
  only skips a draft once the label is gone.)
- **`defer ...`** → the author just pushed; defer to the next tick so the
  prefilter re-runs the engagement check against the new head (no double-review)
  and CI can settle.

Only once it returns `ok`, mark the PR picked up (before the panel, so watchers
see it in progress). The reaction dedupes per actor+content, so re-reacting on a
re-review is a no-op:

```bash
bash <skill-dir>/pr-actions.sh react {number}    # adds 👀
```

Then invoke the **`panel-review`** skill via the Skill tool, targeting the PR
(`/panel-review --pr {number}`), with one overriding instruction:

> **Gather-only. Do NOT modify the working tree; do not edit, commit, or push.**

A `--pr` panel review is a single gather-and-synthesize pass and is read-only by
design (its panelists run worktree-isolated with GitHub-write forbidden), so
this is exactly one fan-out — there is no fix/re-review loop to suppress and
never a `--uncommitted` switch (there are no working-tree fixes). You apply the
FIX/FOREGO judgment to its synthesis yourself (ledger below).

**Record the panel composition and round count.** `panel-review` emits one
`panel-review: <name> (<model>) done (exit N)` heartbeat per panelist; collect
the `<name> (<model>)` pairs that actually ran (it auto-detects codex, claude,
opencode on `PATH`, so a missing CLI silently shrinks the panel). It is always
**1 round** here. If only one panelist ran, say so in the summary (a single
panelist is a thinner signal than a true multi-model panel).

The per-finding ledger: severity, `file:line`, the issue, the recommended fix,
and the **FIX**/**FOREGO** verdict (with forego reason). Calibration:
fix-by-default for CRITICAL and 2+ panelist consensus; verify single-panelist
HIGH / non-consensus MEDIUM before recommending; LOW is polish (forego by
default). severity = trigger probability x consequence; narrow or self-healing
edges are LOW. Auth, money (`@bank/money`, `services/transfers.ts`), and
schema/migration findings warrant extra weight per the repo's CLAUDE.md.

**UPDATED only — incremental scope.** When given `{prevReviewedHead}`, confine
new findings to the commits added since. Pull the changed paths with
`gh api repos/{owner}/{repo}/compare/{prevReviewedHead}...{headRefOid} -q '.files[].filename'`
and instruct the panel to raise findings **only on hunks introduced in that
range** — the rest of the PR is read-only context, not re-litigated (a finding
on an unchanged line was posted last round or deliberately left alone, so
re-posting reads as oscillation). If the compare shows zero added commits (head
moved but tree didn't, e.g. a base merge), skip and report "no new commits".
This scoping is the only behavioral difference from a NEW review.

**Re-evaluate a carried-forward finding against the surface that would resolve
it, not the commit diff.** A _code_ finding is closed by a change in the compare
range (the diff scope above covers it). But a **PR-metadata / process finding —
a misleading title, a missing or wrong description, an undisclosed sensitive
change (the CLAUDE.md "call it out in the PR description" gate), a missing
`security-review` note, labels** — is closed by editing the PR's title/body/
labels, and **a description edit is not a commit, so it never appears in the
compare diff.** A commit-diff-scoped re-review is structurally blind to it.
Whenever a prior finding was about the title/description/disclosure, re-read the
live metadata before carrying it forward:

```bash
gh pr view {number} -R {owner}/{repo} --json title,body,labels
```

If the body now discloses what the finding flagged, the finding is **resolved**
— drop it and recompute the verdict. Never hold a do-not-approve on a disclosure
or title gap the author has since closed in the body. The same rule governs a
fresh review: judge a disclosure finding against the **actual PR body you
fetched**, never inferred from a `docs:`-style title alone.

**Classify the sensitive surface while you have the changed-file list.** Using
the catalog in 4c, record which surfaces (auth/authz, money movement,
schema/migration, secrets/external integrations) the PR touches — computed
independently of whether the panel found anything. For each touched surface also
note the `file:line` of the changed sensitive code (the new auth gate, the
money-math line, the new migration column, the credential read), so the
human-review note can point a reader at it. These surfaces populate the
collapsed human-review section in the summary (4c) and the human-review flag
returned to the sweep — they are not posted as inline comments.

### 4b. Resolve the correct file + line for each finding

An inline comment only lands on the right code when its anchor matches the PR
diff exactly. Per finding, get all four right:

- **`path`** — repo-root-relative, exactly as in the diff (e.g.
  `apps/api/src/services/transfers.ts`). Panelists run inside a worktree, so
  strip any worktree prefix.
- **`line`** — the **post-image (new-file) line number** at the PR head, used
  with `side: RIGHT`. Panelists read files at head, so the line they cite is
  already the post-image line. Use `side: LEFT` only when the finding is about a
  line the PR **deleted** (rare).
- **`start_line` + `line`** (both RIGHT) for a range, so the comment and any
  ` ```suggestion ` block replace exactly those lines. Omit `start_line` for a
  one-line finding (GitHub rejects an inverted or single-line range).
- **The line must fall inside an added/changed hunk.** GitHub 422s a comment on
  unchanged context. A correct `file:line` pointing at pre-existing code the PR
  didn't touch is **not** placeable inline → it belongs in the summary body as
  an off-diff finding, never forced onto the nearest diff line.

**Confirm cheaply when unsure — fetch only that one path, never the whole PR**
(`pulls/{number}/files` is O(PR size); one file's hunks is O(1)):

```bash
gh pr diff {number} -R {owner}/{repo} -- path/to/file.ts   # just that file's hunks
```

Verify two things before posting: (1) the cited line content is the code the
finding describes (panelists occasionally cite a line a few off after a rebase),
and (2) the line sits inside a `+`/changed hunk. Correct a drifted line; route
an off-diff one to the summary instead.

### 4c. Post inline comments, then one summary comment

**Idempotency — post every comment at most once; never re-post one already on
the PR or one a human resolved.** This skill re-runs on every UPDATED push, so
without a guard it re-posts the same findings each tick — its cardinal sin.
Before posting anything, fetch what is already on the PR (inline comments live
in review threads, and only GraphQL exposes a thread's resolution state):

```bash
bash <skill-dir>/pr-actions.sh threads {number}
```

Each line is `resolved|open <TAB> path <TAB> body[:100]`. A planned FIX comment
is **already covered** when an existing thread targets the same `path` and makes
the same point — match on the **issue** (the bold `[SEV]` headline), not the
line number, since lines drift across commits but the point does not. Skip a
planned comment that is already covered:

- **resolved** → a human dispositioned it and closed the thread; re-posting
  reopens a decision they made. Never re-post.
- **open** → already on the PR (a prior tick, a human, anyone); a duplicate is
  pure noise.

Post only the FIX comments **not** already covered. Each one is its own
standalone inline comment — never a batched review object (a batch is atomic, so
one off-diff line 422s the whole thing). Lead the body with the `[SEVERITY]` tag
and include a ` ```suggestion ` block for concrete line-level replacements
(one-click commit) or prose for structural fixes. Write the body to a file and
post it; the script pins the commit to the live head and 422-folds an off-diff
line back to the summary for you:

````bash
# Single line: just <path> <line>. Body file holds the raw markdown:
#   **[HIGH] <one-line issue>**
#
#   <why it matters>
#
#   ```suggestion
#   <exact replacement>
#   ```
bash <skill-dir>/pr-actions.sh comment {number} apps/api/src/foo.ts 42 /tmp/bot-panel-review-loop-{number}-{i}.md

# Multi-line range: add --start so the suggestion replaces exactly those lines.
bash <skill-dir>/pr-actions.sh comment {number} apps/api/src/foo.ts 42 --start 40 /tmp/bot-panel-review-loop-{number}-{j}.md
````

The script prints `posted` on success or `offdiff` when GitHub 422s the line —
on `offdiff`, drop that finding into the summary's off-diff section instead.

Then write the summary + verdict as one issue comment. This body and the inline
comments go to GitHub, so keep them em-dash-free (colons, commas, parens) per
the repo's user-facing-prose convention.

**Upsert it — one summary per PR, always current.** Write the raw markdown body
(template below) to a file and hand it to `upsert`; it PATCHes the bot's
existing marker-carrying comment in place if one exists, else POSTs a new one.
So an UPDATED re-review refreshes the single summary (new verdict, new head
marker) instead of stacking a fresh comment each tick:

```bash
bash <skill-dir>/pr-actions.sh upsert {number} /tmp/bot-panel-review-loop-{number}-summary.md
```

Summary body — keep the **visible** body to just the three things a reader
actually scans: the verdict, the panel (models + round count), and the head.
Every findings list and the human-review note live in collapsed `<details>`
accordions, so a reader expands only what they want. Always written (posted or
upserted), even with zero inline findings. **Omit any findings accordion whose
count is zero**; omit the human-review accordion only when no sensitive surface
is touched. The blank line after each `<summary>` is required for GitHub to
render the markdown inside. The `<!-- ... head= -->` marker is mandatory and
must carry the current head — the Step 1 prefilter's engagement check depends on
it.

```
## Panel review (advisory)

**Verdict: <Approve | Do not approve yet>.** <one-line reason>

**Panel:** {name (model), name (model), ...} ({N} round, at {short head}; gather-only, no code was changed). <only-if-thin: note any supported CLI not on PATH, e.g. "codex and opencode were not detected, so consensus is single-panelist.">

<details>
<summary><b>Recommend fixing ({count})</b></summary>

- [SEV] file:line: issue. Fix: <suggested fix> (posted inline)

</details>

<details>
<summary><b>Off-diff / structural ({count})</b></summary>

- [SEV] file:line: issue. Fix: <suggested fix>

</details>

<details>
<summary><b>Left alone ({count})</b></summary>

- [SEV] file:line: finding. Why not fixed: <reason>

</details>

<details>
<summary><b>Human review recommended ({sensitive surfaces touched})</b></summary>

{one line on what a human should scrutinize}, at {file:line of each sensitive hunk}.

</details>

<!-- bot-panel-review-loop: head={headRefOid} -->
```

The **Panel** line is mandatory: list every panelist that ran as `name (model)`
plus the round count, so the summary is self-describing about the panel's
breadth (and flags a thin single-CLI run). Everything else is collapsed by
design — do not promote a findings list or the human-review note into the
visible body.

**Verdict rule:** **Do not approve yet** if any FIX finding is CRITICAL/HIGH or
a substantiated wrong-approach flag survives; **Approve** if only MEDIUM/LOW
polish remains ("clean, mergeable" is a valid verdict — don't manufacture
blockers). The verdict is advisory prose; never cast a formal
approval/request-changes, never merge — humans own the merge button.

**Sensitive-surface catalog** (drives the collapsed human-review section;
determine from the already-fetched changed-file list, not a fresh full-diff
fetch):

- **Authentication / authorization** — login, session, token, 2FA/passkey,
  device-link, replay/ownership gates, or RBAC
  (`packages/shared/src/permissions/`, `requirePermission` / `hasPermission`,
  `docs/role-capabilities.md`).
- **Money movement** — anything under `@bank/money`, `services/transfers.ts`,
  send/transfer/withdraw flows, fees, balances, or Bridge/Turnkey outbound
  provider paths (see `docs/adr/0001-...`).
- **Schema / migrations** — new files under `apps/api/src/migrations/` or repo
  changes, especially money-typed or constraint-changing columns.
- **Secrets / external integrations** — credential handling, webhook
  verification, or third-party API surfaces.

The human-review recommendation is **independent of the verdict**: a clean panel
verdict on auth or money is exactly when a human second look is most valuable,
so an Approve still gets the collapsed human-review section, and a
Do-not-approve on a sensitive surface still includes it (the human reviews
both). Omit the section entirely — no empty or "none" accordion — only when no
sensitive surface is touched.

### 4d. Settle the reaction to reflect the verdict

The 👀 from 4a means "panel in progress". Once the summary is posted, settle it
to a terminal reaction mirroring the verdict (never 👎 — a reject is too strong
for an advisory panel):

```bash
# Approve → drop 👀, add 🚀 ("clean, ship it"). Do-not-approve → leave 👀 ("see my comments").
bash <skill-dir>/pr-actions.sh settle {number} approve     # or: settle {number} comments
```

So the reaction alone tells a watcher the outcome: 🚀 = approved, 👀 = comments
worth addressing. Reactions dedupe per actor+content, so the swap is idempotent
on an UPDATED re-review.

Return to the sweep:
`#{number} {NEW|UPDATED}: {approve|do-not-approve} (N posted) [panel: name(model)+...; R round] [human-review: {surfaces or none}]`.
The trailing tags let the sweep show panel breadth and the human-review flag
without re-reading each PR.

## Step 5: Report (in-session)

The prefilter already emitted `REPORT_TABLE` — one row per open PR (unlabeled
drafts excluded) with every skip/defer reason filled in. Take it verbatim and,
for each `PENDING_VERDICT` row, replace the last three columns with what that
PR's agent returned: the **Result** (verdict + finding counts), the **Panel**
(models that ran + round count), and the **Human** column (human-review
surfaces, or blank). Skip and defer rows are already final.

| PR   | Title           | Engagement | Result                          | Panel                                | Human |
| ---- | --------------- | ---------- | ------------------------------- | ------------------------------------ | ----- |
| #903 | evidence lookup | NEW        | do-not-approve (2 HIGH, 1 MED)  | codex(gpt-5.5)+claude(opus-4.8); 1rd | auth  |
| #905 | fee preview     | UPDATED    | approve (clean)                 | claude(opus-4.8); 1rd (codex/oc n/a) | money |
| #906 | bump deps       | -          | dependabot → skipped            | -                                    | -     |
| #907 | reconcile tweak | NEW        | deferred (CI pending)           | -                                    | -     |
| #910 | my refactor     | SEEN       | skipped (reviewed at this head) | -                                    | -     |

Keep it to signal — detailed findings live on each PR. The Panel column says at
a glance whether a review was a full multi-model panel or a thinner single-CLI
run; the Human column surfaces which approved PRs still want a human sign-off,
so a clean 🚀 on sensitive code is not mistaken for "no one needs to look."

## Loop semantics (when driven by /loop or /schedule)

`/loop` owns cadence; one invocation is one full sweep. **Default dynamic-mode
delay: every ~5 minutes — use `270s` on every tick**, whether the board is idle,
freshly reviewed, or has PRs deferred on pending CI. A 5-minute cadence keeps
new and updated PRs picked up promptly and catches CI as it goes green. Use
`270s`, not a literal `300s`: 270s sits just under the 5-minute prompt-cache TTL
so each tick stays cache-warm, whereas 300s pays a cache miss without buying a
longer wait. Only stretch past this (toward `1200s`+) if you have a specific
reason to back off and the user has not asked for the 5-minute default. Inherit
the session model; never pin one.

`/loop` keeps one continuous context — tokens accumulate across ticks and only
shrink via auto-compaction. This skill keeps the main context tiny anyway (heavy
review work lives in discarded per-PR subagents; the sweep only retains the
prefilter's compact output plus the per-PR verdicts). For a genuinely fresh
context every tick, drive it with `/schedule` (a cron routine) instead — each
run is a new session, which works here because all NEW/UPDATED/SEEN state lives
in the GitHub head markers, not in conversation memory. The trade is
fixed-interval cron vs `/loop`'s dynamic self-pacing.
