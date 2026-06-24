---
name: babysit
description:
  Use when asked to babysit, watch, or maintain the single PR you are on (the
  current branch's PR) — keep it mergeable, CI green, review comments handled —
  especially as the body of a /loop or recurring schedule.
---

# Babysit (single PR)

One invocation = one health pass over the **single PR this branch is on** (or
the PR passed via `--pr N`): keep it mergeable, CI green, and review comments
handled. Designed to be driven by `/loop /babysit` (dynamic mode). Do NOT nest
another per-tick scheduler or PR-watching loop in the same session — two
schedulers would fight over the session's single wakeup.

You are already on the PR's branch (that is the whole premise), so fixes happen
**directly in this worktree** — no `git worktree add`, no temp checkout.

Drafts are in scope: you invoked this on the PR you are sitting on, so it works
the PR whether or not it is a draft (`isDraft` is reported so you can call it
out). The never-rewrite-history rule below still holds regardless.

## Scan first (one read-only command)

Start every tick with the bundled scanner. It does all the deterministic
data-gathering so you spend tokens on fixes, not on fetching and parsing:

```bash
skills/babysit/scan.sh        # add --no-logs to skip CI log excerpts; --repo owner/name and --pr N to override
```

It resolves the repo slug, finds the PR for the current branch (or `--pr N`),
and emits one compact JSON digest:

```jsonc
{
  "repo": "owner/name",
  "anythingToDo": false,            // false => nothing actionable this tick
  "suggestedDelaySeconds": 1800,    // feed straight to the /loop driver
  "pr": {                           // null => this branch has no open PR
    "number", "title", "branch", "isDraft",
    "mergeable", "mergeState", "reviewDecision",
    "ci": { "passed", "failed", "pending", "failing": [{ "name", "link" }] },
    "unresolvedThreads": 0,         // unresolved, not-outdated, last non-bot/non-ignored comment is a reviewer (total)
    "newThreads": 0,                // of those, NOT yet acked in the seen-ledger
    "standingGates": 0,             // of those, already acked (silenced, unchanged)
    "threads": [{ "sig", "threadId", "path", "line", "lastAuthor", "at" }],  // the unseen inline ones only
    "newRootComments": 0,           // unseen non-author, non-bot root (issue) comments
    "standingRootGates": 0,         // of those, already acked
    "rootComments": [{ "sig", "author", "at" }],  // the unseen root comments only
    "newReviewComments": 0,         // unseen non-author, non-bot review-summary bodies
    "standingReviewGates": 0,       // of those, already acked
    "reviewComments": [{ "sig", "author", "state", "at" }],  // the unseen review summaries only
    "failingLogs": [{ "check", "jobId", "excerpt" }],  // ~40-line error signature only
    "bucket": "CONFLICTING | CI_FAIL | HAS_COMMENTS | BEHIND | CI_PENDING | GREEN_IDLE"
  }
}
```

The scanner is **strictly read-only**: it gathers and buckets, never commits,
pushes, merges, or resolves. If `pr` is null, this branch has no open PR — say
so and stop. If `anythingToDo` is false, there is nothing to do this tick —
report and sleep `suggestedDelaySeconds`. Otherwise act when the `bucket` is not
`GREEN_IDLE`/`CI_PENDING`, routed by the checks below. The bucket is a routing
hint built from the raw fields, which stay in the object; trust your judgment
over the label when they disagree.

**Seen-ledger.** The split into _new_ (unacked) and _standing_ (acked) is the
whole point: `HAS_COMMENTS` fires on
`newThreads`/`newRootComments`/`newReviewComments`, never on the total
`unresolvedThreads`, so a comment you have already triaged never re-surfaces.

- **Three channels, same shape.** Inline review `threads`, root-level
  `rootComments`, and review-summary `reviewComments` — the root channel catches
  a finding a reviewer drops on a line outside the diff, and the review channel
  catches a `CHANGES_REQUESTED` review whose feedback lives in the top-level
  body with no inline/root comment; the inline-thread query sees neither. All
  three arrays carry only the **unseen** items, no bodies (fetch those yourself
  for just these); inline threads also carry the GraphQL `threadId` you pass to
  resolve them (check 3), and review summaries carry their `state` so an
  `APPROVED`-with-body reads as a likely dismiss.
- **Sigs self-heal.** Inline sig is
  `"c"+<id of the thread's last non-bot, non-ignored comment>` (a reviewer's),
  root is `"r"+<comment id>`, review summary is `"v"+<review id>` — so a later
  reviewer reply or new review mints a new sig and the item re-surfaces on its
  own (a trailing bot reply does not).
- **Standing gates are noise, not work.** Already-acked-but-open items
  (`standingGates` / `standingRootGates`) get a one-liner in the report
  (`3 known gates, unchanged`) but are **not** actionable and never make the PR
  busy.
- **Filtering.** Author comments, `[bot]` accounts, and (by default) catena's
  review bot `catenabot` are dropped; adjust via `BABYSIT_IGNORE_LOGINS=foo,bar`
  (set it empty to clear).
- **Only `mark-seen.sh` writes the ledger** (see check 3); `scan.sh` only reads
  it.

| bucket         | route to                                                       |
| -------------- | -------------------------------------------------------------- |
| `CONFLICTING`  | Check 1 (freshness / conflict resolution)                      |
| `CI_FAIL`      | Check 2 (read `failingLogs[].excerpt` first)                   |
| `HAS_COMMENTS` | Check 3 (triage `threads` + `rootComments` + `reviewComments`) |
| `BEHIND`       | Check 1 (up-to-date gate)                                      |
| `CI_PENDING`   | nothing — checks still running, recheck next tick              |
| `GREEN_IDLE`   | nothing                                                        |

## Checks (in order)

1. **Freshness.** Update the branch only when it _needs_ it: merge conflicts
   with main, branch protection requiring up-to-date, or CI that must re-run
   against new main. A merely-behind-but-green PR is left alone (no churn). To
   update: `git merge origin/main` into the branch and resolve conflicts
   semantically. **Never rebase or force-push a non-draft PR** — reviewers lose
   their place and inline comments detach. If a conflict resolution requires
   choosing between two divergent intents, stop and ask the user instead of
   guessing.
2. **CI.** Read the digest's `failingLogs[].excerpt` first — it is the failing
   job's error signature, so you rarely need to pull the full log. Fix
   mechanical failures (lint, format, unused import, trivially broken test) as
   appended commits. Non-mechanical failures (logic, flaky infra, anything
   touching auth/money/schema): report and ask. Classifying mechanical-vs-not is
   your call, not the scanner's.
3. **Comments.** Work the **unseen** items from all three channels: the
   `threads` array (inline review), the `rootComments` array (root-level PR
   conversation), and the `reviewComments` array (review-summary bodies). Fetch
   bodies for just those — inline via
   `gh api repos/<owner>/<name>/pulls/comments/<id>` (id = the `sig` minus its
   `c` prefix), root via `gh api repos/<owner>/<name>/issues/comments/<id>` (id
   = the `sig` minus its `r` prefix), and review summaries via
   `gh api repos/<owner>/<name>/pulls/<number>/reviews/<id>` (id = the `sig`
   minus its `v` prefix). `triage-pr-comments` also fetches review bodies
   itself, so you can hand it the PR and let it pull them.

   **REQUIRED SUB-SKILL: triage-pr-comments.** It owns the whole comment engine
   — the analysis (understand → assess → verdict) **and** the reply/resolve
   mechanics. Its Step 5 ("Reply and resolve") is written as a mode-agnostic
   entry point you drive non-interactively, so **do not re-derive the `gh` /
   `jq` / `resolveReviewThread` commands, the read-back verification, or the
   push→reply→resolve failure ordering here** — run that procedure. Apply its
   simple Fix verdicts; for complicated ones (redesigns, scope changes, judgment
   calls, anything touching auth/money/schema) stop and ask the user via
   AskUserQuestion with a concrete recommendation instead of applying.

   When a comment is handled, **reply and resolve via triage-pr-comments' Step 5
   procedure**, with these babysit deltas:
   - **Reply-approval gate.** Bot replies post autonomously; a reply to a human
     reviewer is drafted and shown to the user (AskUserQuestion) before posting.
   - **Thread id.** Pass the `threadId` the scanner already put on each inline
     thread to `resolveReviewThread` — no need to re-query it.
   - **What retires an item, and the ledger.** Resolving an inline thread
     retires it (the scanner filters `isResolved`), so do **not** also ack it. A
     **root** comment or a **review summary** has no thread to resolve, so after
     replying, **ack** it in the ledger (below). If `resolveReviewThread` fails,
     ack the inline `sig` as a fallback so the loop doesn't re-handle a landed
     fix.
   - **On failure.** triage's Step 5 ordering applies (a failed push aborts the
     replies and resolves). Surface any reply/resolve failures in the tick
     report; never report a comment as handled while its reply or resolve is
     still outstanding.

   For items needing **no agent action** (human-review gate, won't-fix, deferred
   to the user), reply only if you have something useful to say, then **ack**
   the thread so it stops re-surfacing — pass its `sig` from the digest, never
   hand-computed:

   ```bash
   skills/babysit/mark-seen.sh --verdict human-gate <sig> [<sig> ...]
   ```

   Use a `--verdict` tag: `human-gate`, `wontfix`, `deferred`, or `handled` for
   no-action acks, or `fixed` for the root-comment / review-summary /
   resolve-failed fallback above. **Do NOT** pre-ack a thread before its fix
   lands — for inline fixes, reply + resolve retires it; the ledger is only for
   items GitHub won't resolve for you (no-action gates and replied-to root
   comments).

## Mechanics

- `git fetch origin` — never `git fetch origin <branch>` (stale refs in
  bare-repo/worktree setups).
- Work **in the current worktree** — you are already on the PR's branch, so
  there is no temp worktree to add or remove. Delegate per-comment or
  conflict-resolution depth to subagents when it helps, but the tick itself
  stays cheap.
- Verify before any push: the repo's own gate (its lint / format / typecheck
  command, e.g. `pnpm run check`) plus tests scoped to changed files. Isolate
  the test database name per branch to avoid shared test-DB pollution.
- Pushes are plain `git push` (appends only).
- The seen-ledger lives at
  `${XDG_STATE_HOME:-$HOME/.local/state}/babysit/<owner>-<name>.json` and is
  written **only** by `mark-seen.sh`. `scan.sh` reads it; nothing else touches
  it. Each entry is keyed by the id of the comment/review its sig names — for an
  inline thread, the last non-bot/non-ignored comment — so it never hides a
  thread a reviewer has since replied to.

## Pacing and model (when driven by /loop)

- The /loop driver owns cadence. Use the scanner's `suggestedDelaySeconds`
  (1800s when nothing is actionable or pending, 270s when anything is in
  flight); override to ~270s on any tick where you just pushed and are waiting
  on CI.
- Inherit the session model; never pin one. Subagents doing conflict resolution
  should inherit too (it is judgment work, not grunt work).

## Stop-and-ask triggers

- Reviewer asks for a design/architecture change
- Conflict resolution with genuinely divergent semantics
- Anything that would rewrite history on a non-draft PR
- CI failure whose fix touches auth, money movement, or schema

## Common mistakes

| Mistake                                     | Reality                                                                                                                        |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Adding a temp worktree to do the work       | You are already on the PR's branch; fix in place                                                                               |
| Rebase + force-with-lease on an approved PR | Ready PRs get merge commits or appended fixes                                                                                  |
| Updating a behind-but-green branch          | No-conflict, green, no up-to-date gate = leave it                                                                              |
| Nesting another PR-watching loop            | Two schedulers fight over the session wakeup; this skill is the loop body                                                      |
| Replying to a human reviewer autonomously   | Draft + user approval first                                                                                                    |
| Re-fetching PR/CI/thread state by hand      | The scanner already gathered it; read the digest                                                                               |
| Re-triaging the same gate every tick        | Ack no-action threads with `mark-seen.sh`; `newThreads` drives `HAS_COMMENTS`                                                  |
| Acking a fixed inline thread in the ledger  | Push, reply, then `resolveReviewThread` — that retires it; the ledger is only for no-action gates and replied-to root comments |
| Replying to a fix but not retiring it       | Inline: reply **and** resolve. Root: reply **and** ack (no thread to resolve)                                                  |
| Pulling a full CI log to read one error     | `failingLogs[].excerpt` is the error signature                                                                                 |
