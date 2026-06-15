---
name: bot-panel-review-loop
description:
  Use when asked to sweep, review, or babysit the open PRs in a repo with a
  panel review and post advisory findings. For each open, CI-green,
  not-yet-approved PR that is either non-draft or a draft labeled "ready for
  review", dispatch a fresh per-PR agent that reacts 👀, runs a
  gather-only panel-review-loop, posts inline PR comments at the correct
  file+line suggesting fixes, anchors an inline "human review recommended" note
  on each sensitive hunk (auth, money movement, schema, secrets), posts an
  approve/do-not-approve summary, and swaps its 👀 reaction to 🚀 on an approve
  verdict (leaving 👀 when it left comments). Tracks engagement (NEW / UPDATED /
  SEEN) so it doesn't repeat work. Read-only toward the code: it never edits,
  commits, or pushes. Designed to be the body of `/loop /bot-panel-review-loop`.
allowed-tools:
  Bash, Read, Grep, Glob, Skill, Agent, TodoWrite, AskUserQuestion, ScheduleWakeup
argument-hint: "[--all] [--exclude-own] [--dependabot]"
---

# Bot Panel Review Loop

One invocation = one fleet-wide sweep of the repo's open PRs. The sweep selects
the actionable PRs, then **dispatches one fresh agent per PR** to review it and
post advisory comments back. **This skill never changes the code** — no edits,
no commits, no pushes. Its only side effects are GitHub reactions and comments.

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

Each tick selects the actionable PRs and dispatches one fresh agent per PR;
per-PR engagement markers keep it from re-reviewing a PR it already covered at
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

The gate definitions above are canonical; the script is their implementation. It
settles `mergeable == UNKNOWN` once (gate 4) and guards the UPDATED incremental
range (ahead → scoped re-review, identical → SEEN/skip, diverged → full
re-review). Trust its output; only re-derive a disposition by hand (with
`gh pr list` / `gh api .../comments` / `gh pr checks`) if the script errors or a
result is clearly wrong. Everything the former Steps 2 (engagement) and 3 (CI)
did now happens inside it.

## Step 4: Dispatch one fresh agent per actionable PR

One fresh isolated context per PR, done as subagents: the sweep stays cheap and
each PR gets clean, uncontaminated context. Each agent owns exactly one PR, does
Steps 4a-4d, and returns a one-line verdict. Inherit the session model — don't
pin one; the judgment (which findings are real, the verdict) wants the strong
model.

**Bound concurrency to 2-3 PRs at a time.** Each review runs `panel-review.sh`,
which materializes one throwaway git worktree _per panelist_ under a `mktemp`
dir pinned to the PR head (see below). Those linked worktrees share this repo's
single `.git`, so fanning out every PR at once means (PRs x panelists)
concurrent `git worktree add`/`remove` racing on `.git/worktrees` and
index/config locks. Dispatch in small batches (or sequentially if a batch errors
on a git lock) — fresh-context-per-PR is the goal, not maximum parallelism.

### How the diff is fetched

The skill never checks out a PR into your working tree; the diff arrives over
the GitHub API via `gh`. The **review** path (`panel-review-loop` →
`panel-review.sh --pr {number}`) resolves metadata with `gh pr view`,
materializes the per-panelist ephemeral worktrees, and each panelist runs
`gh pr diff` itself inside its isolated, auto-removed worktree. The **comment**
path (4b/4c) fetches no diff at all — comments post optimistically and GitHub
422s off-diff lines; any per-finding sanity check pulls only that one path. So
nothing here scales with PR size.

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
gh pr view {number} -R {owner}/{repo} \
  --json state,isDraft,headRefOid,mergeable,labels \
  -q '"\(.state) \(.isDraft) \(.headRefOid) \(.mergeable) \([.labels[].name] | any(ascii_downcase == "ready for review"))"'
```

- `state != OPEN` → **skip, do not react or post**; report "skipped (merged)" /
  "skipped (closed)". (It merged between the sweep and dispatch.)
- `isDraft == true` **and the `ready for review` label is gone** (the trailing
  field is `false`) → skip ("skipped (now draft)"). A draft that still carries
  the label is a deliberate opt-in — proceed. (If the author both pushed and
  removed the label, the head check below also defers it.)
- `mergeable == CONFLICTING` → skip ("skipped (merge conflict)") — gate 4 again,
  re-checked because it can flip after enumeration.
- `headRefOid` differs from the queued head → the author just pushed; defer to
  the next tick so the prefilter re-runs the engagement check against the new
  head (so you don't double-review) and CI can settle.

Only once it re-confirms as OPEN, reviewable (non-draft, or a draft still
labeled `ready for review`), non-conflicting, at the expected head, mark it
picked up (before the panel, so watchers see it in progress):

```bash
gh api repos/{owner}/{repo}/issues/{number}/reactions \
  --method POST -H "Accept: application/vnd.github+json" -f content=eyes
```

The endpoint dedupes per actor+content, so re-reacting on a re-review is a
no-op.

Then invoke the **`panel-review-loop`** skill via the Skill tool, targeting the
PR (`/panel-review-loop --pr {number}`), with one overriding instruction:

> **Gather-only. Do NOT modify the working tree; do not edit, commit, or push.**
> Produce the FIX / FOREGO judgment ledger and stop.

With no fixes applied the loop has nothing to re-review, so it **collapses to a
single gather-and-judge pass**. That is intended — don't spin extra rounds
against unchanged code (it only resurfaces identical findings and reads as
oscillation). Stay on `--pr {number}` throughout; never switch to
`--uncommitted` (there are no working-tree fixes).

**Record the panel composition and round count.** `panel-review` emits one
`panel-review: <name> (<model>) done (exit N)` heartbeat per panelist; collect
the `<name> (<model>)` pairs that actually ran (it auto-detects codex, claude,
opencode on `PATH`, so a missing CLI silently shrinks the panel). Gather-only
should always be **1 round** — surface the real number if it's higher. If only
one panelist ran, say so in the summary (a single-panelist run is a thinner
signal than a true multi-model panel).

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
it, not the commit diff.** Before you hold the verdict on a finding raised last
round, ask what would close it. A _code_ finding is closed by a change in the
compare range (or still stands if its cited lines are unchanged) — the diff
scope above covers that. But a **PR-metadata / process finding — a misleading
title, a missing or wrong description, an undisclosed sensitive change (the
CLAUDE.md "call it out in the PR description" gate), a missing `security-review`
note, labels** — is closed by editing the PR's title/body/labels, and **a
description edit is not a commit, so it never appears in the compare diff.** A
commit-diff-scoped re-review is therefore structurally blind to it. Whenever a
prior finding was about the title/description/disclosure rather than the code,
re-read the live metadata before carrying it forward:

```bash
gh pr view {number} -R {owner}/{repo} --json title,body,labels
```

If the body now discloses what the finding flagged, the finding is **resolved**
— drop it and recompute the verdict. Never hold a do-not-approve on a disclosure
or title gap the author has since closed in the PR body just because no _commit_
touched it. The same rule governs a fresh review: judge a disclosure finding
against the **actual PR body you fetched**, never inferred from a `docs:`-style
title alone (the body may already call the change out).

**Classify the sensitive surface while you have the changed-file list.** Using
the catalog in 4c, record which surfaces (auth/authz, money movement,
schema/migration, secrets/external integrations) the PR touches — computed
independently of whether the panel found anything. For each touched surface also
note the **representative anchor(s)**: the `file` + post-image `line` of the
changed sensitive code (the new auth gate, the money-math line, the new
migration column, the credential read). These anchors drive the inline
`[HUMAN REVIEW]` comments in 4c and the human-review flag returned to the sweep.

### 4b. Resolve the correct file + line for each finding

An inline comment only lands on the right code when its anchor matches the PR
diff exactly. Per finding (and per human-review anchor), get all four right:

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
# read the post-image to confirm the line content matches the finding:
gh api repos/{owner}/{repo}/contents/path/to/file.ts?ref=$HEAD -q .content | base64 -d | sed -n 'N,Mp'
```

Verify two things before posting: (1) the cited line content is the code the
finding describes (panelists occasionally cite a line a few off after a rebase),
and (2) the line sits inside a `+`/changed hunk. Correct a drifted line; route
an off-diff one to the summary instead.

### 4c. Post inline comments, then one summary comment

Do **not** bundle into a single review object — a batched review is atomic, so
one off-diff line 422s the whole thing. Post each comment as its own standalone
inline review comment; a 422 on one falls back to the summary without losing the
others.

**FIX findings** — one POST each, with a ` ```suggestion ` block for concrete
line-level replacements (one-click commit) or prose for structural fixes. Lead
with the `[SEVERITY]` tag.

```bash
HEAD=$(gh pr view {number} -R {owner}/{repo} --json headRefOid -q .headRefOid)
# Single line: omit start_line. line = post-image line number, side = RIGHT.
cat > /tmp/bot-panel-review-loop-{number}-{i}.json <<JSON
{ "commit_id": "$HEAD", "path": "apps/api/src/foo.ts", "line": 42, "side": "RIGHT",
  "body": "**[HIGH] <one-line issue>**\n\n<why it matters>\n\n\`\`\`suggestion\n<exact replacement>\n\`\`\`" }
JSON
# Multi-line: anchor the whole range so the suggestion replaces exactly those lines.
cat > /tmp/bot-panel-review-loop-{number}-{j}.json <<JSON
{ "commit_id": "$HEAD", "path": "apps/api/src/foo.ts", "start_line": 40, "start_side": "RIGHT",
  "line": 42, "side": "RIGHT",
  "body": "**[HIGH] <one-line issue>**\n\n<why it matters>\n\n\`\`\`suggestion\n<exact 3-line replacement>\n\`\`\`" }
JSON
gh api repos/{owner}/{repo}/pulls/{number}/comments --method POST \
  --input /tmp/bot-panel-review-loop-{number}-{i}.json \
  || echo "off-diff (422) -> fold this finding into the summary body"
```

**Human-review anchors** — for each sensitive surface classified in 4a, post one
inline comment at its representative anchor, leading with a `[HUMAN REVIEW]` tag
and **no suggestion block** (it's "a human should scrutinize this", not a fix).
Name the surface and what to check, so the human-review signal lands _on the
exact code_ a person should read, not only in the summary.

```bash
# One per sensitive anchor. Same independent-POST + 422-fallback contract as FIX.
cat > /tmp/bot-panel-review-loop-{number}-hr-{k}.json <<JSON
{ "commit_id": "$HEAD", "path": "apps/api/src/auth/session.ts", "line": 88, "side": "RIGHT",
  "body": "**[HUMAN REVIEW] Authentication.** This changes session/token handling; an automated panel should not be the only reviewer of auth. A human should confirm <the specific invariant: replay/ownership gate, token scope, expiry>." }
JSON
gh api repos/{owner}/{repo}/pulls/{number}/comments --method POST \
  --input /tmp/bot-panel-review-loop-{number}-hr-{k}.json \
  || echo "off-diff (422) -> the surface still appears in the summary callout"
```

Keep it to the **key anchor(s) per surface** (the load-bearing line), not every
touched line — one well-placed `[HUMAN REVIEW]` note per surface beats spamming
the diff. If a human-review anchor coincides with a FIX line, keep them as
distinct comments (different tags, different intent). An anchor that 422s
(somehow off-diff) is fine: the surface is still named in the summary callout.

Then post the summary + verdict as one issue comment (also where the dedup
marker lives). This body and the inline comments go to GitHub, so keep them
em-dash-free (colons, commas, parens) per the repo's user-facing-prose
convention.

```bash
gh api repos/{owner}/{repo}/issues/{number}/comments --method POST \
  --input /tmp/bot-panel-review-loop-{number}-summary.json
```

Summary body (always posted, even with zero inline findings):

```
## Panel review (advisory)

**Verdict: <Approve | Do not approve yet>.** <one-line reason>

Reviewed at {short head} by a fresh independent panel (gather-only; no code was changed).

**Panel:** {name (model), name (model), ...} ({N} round). <only-if-thin: note any supported CLI not on PATH, e.g. "codex and opencode were not detected, so consensus is single-panelist.">

> **Human review recommended ({sensitive surfaces touched}).** {one line on what to look at; anchored inline at the sensitive hunks}.

### Recommend fixing ({count})
- [SEV] file:line: issue. Fix: <suggested fix> (posted inline)

### Off-diff / structural ({count})
- [SEV] file:line: issue. Fix: <suggested fix>

### Left alone ({count})
- [SEV] file:line: finding. Why not fixed: <reason>

<!-- bot-panel-review-loop: head={headRefOid} -->
```

The marker line is mandatory and must carry the current head — the Step 1
prefilter's engagement check depends on it. The **Panel** line is mandatory:
list every panelist that ran as `name (model)` plus the round count, so the
summary is self-describing about the panel's breadth (and flags a thin
single-CLI run).

**Verdict rule:** **Do not approve yet** if any FIX finding is CRITICAL/HIGH or
a substantiated wrong-approach flag survives; **Approve** if only MEDIUM/LOW
polish remains ("clean, mergeable" is a valid verdict — don't manufacture
blockers). The verdict is advisory prose; never cast a formal
approval/request-changes, never merge.

**Sensitive-surface catalog** (drives both the inline `[HUMAN REVIEW]` anchors
in 4c and the summary callout; determine from the already-fetched changed-file
list, not a fresh full-diff fetch):

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
so an Approve still gets the callout and inline anchors. When the verdict is
already **Do not approve yet** on a sensitive surface, still include them (the
human reviews both the findings and the surface). Omit the callout entirely — no
empty or "none" line — only when no sensitive surface is touched.

### 4d. Settle the reaction to reflect the verdict

The 👀 from 4a means "panel in progress". Once the summary is posted, swap it to
a terminal reaction mirroring the verdict — never 👎 (a reject is too strong for
an advisory panel):

- **Approve** → remove your 👀 and add 🚀 ("clean, ship it"):

  ```bash
  ME=$(gh api user -q .login)
  RID=$(gh api repos/{owner}/{repo}/issues/{number}/reactions \
    -H "Accept: application/vnd.github+json" \
    -q ".[] | select(.user.login==\"$ME\" and .content==\"eyes\") | .id" | head -n1)
  [ -n "$RID" ] && gh api repos/{owner}/{repo}/issues/{number}/reactions/$RID --method DELETE
  gh api repos/{owner}/{repo}/issues/{number}/reactions \
    --method POST -H "Accept: application/vnd.github+json" -f content=rocket
  ```

- **Do not approve yet** → leave the 👀 in place ("reviewed, see my comments").

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
shrink via auto-compaction; there is no per-iteration clear. This skill keeps
the main context tiny anyway (heavy review work lives in discarded per-PR
subagents; the sweep only retains the prefilter's compact output (the actionable
JSON and report table) plus the per-PR verdicts). If you want a genuinely fresh
context every tick, drive it with `/schedule` (a cron routine) instead — each
run is a new session, which works here because all NEW/UPDATED/SEEN state lives
in the GitHub head markers, not in conversation memory. The trade is
fixed-interval cron vs `/loop`'s dynamic self-pacing.

## Common mistakes (the non-obvious ones)

| Mistake                                                                                       | Reality                                                                                                                                                                                                                                         |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Reacting / posting on a PR that merged mid-sweep                                              | Re-confirm live `state == OPEN` at dispatch (4a), not just at enumeration                                                                                                                                                                       |
| Spinning extra panel-review-loop rounds                                                       | Gather-only collapses to one pass; unchanged code = same finds                                                                                                                                                                                  |
| Posting an off-diff finding inline                                                            | GitHub 422s it — fold off-diff findings into the summary body                                                                                                                                                                                   |
| Re-targeting a finding onto a nearby diff line so it lands                                    | Mis-anchors on unrelated code; off-diff findings belong in the summary                                                                                                                                                                          |
| Citing a pre-image / worktree-prefixed line                                                   | `line` is the post-image (RIGHT) number; `path` is repo-root-relative — confirm against `gh pr diff -- path` (4b)                                                                                                                               |
| Suggestion block replacing the wrong span                                                     | Multi-line fixes need the `start_line`..`line` range, not a single `line`                                                                                                                                                                       |
| Human-review only in the summary                                                              | Anchor a `[HUMAN REVIEW]` inline comment on each sensitive hunk too (4c) — the human-review note belongs on the code                                                                                                                            |
| Holding a prior do-not-approve for a disclosure/title finding the author fixed in the PR body | A description edit is not a commit, so it never shows in the compare diff — re-read `gh pr view --json title,body,labels` on an UPDATED re-review; a metadata/process finding resolves the moment the body discloses it (4a, incremental scope) |
| Inferring a disclosure gap from a `docs:`-style title alone                                   | Judge disclosure against the actual PR body you fetched, not the title — the body may already call the sensitive change out (4a)                                                                                                                |
| Skipping the human-review callout on a clean auth/money PR                                    | An Approve on a sensitive surface still wants a human; emit callout + anchors (4c)                                                                                                                                                              |
| Editing / committing a fix                                                                    | Advisory-only; it posts comments, never patches                                                                                                                                                                                                 |
| Formal Approve / Request-changes / merge                                                      | Verdict is a plain comment; humans own the merge button                                                                                                                                                                                         |
| Leaving 👀 after approve, or reacting 👎                                                      | 4d swaps 👀→🚀 on approve; do-not-approve keeps 👀; never 👎                                                                                                                                                                                    |
