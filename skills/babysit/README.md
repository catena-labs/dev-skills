# babysit

Keep the **single PR you're on** healthy on a recurring loop: the current
branch's PR mergeable, CI green, and review comments triaged. One invocation is
one pass — it starts with a single read-only scan, acts only if the PR actually
needs something, and otherwise reports and sleeps. This is the single-PR sibling
of [babysit-prs](../babysit-prs); use it when you're parked on one PR and want
just that PR watched.

## Install

```bash
npx skills add catena-labs/dev-skills --skill babysit
```

## How to use it

This skill is built to run on a loop. Hand it to `/loop` and let it pace itself:

```
/loop /babysit
```

`/loop` with no interval runs in **dynamic mode** — after each pass the skill
tells the loop how long to wait (≈30 min when nothing is in flight, ≈4.5 min
when a push is waiting on CI), so it polls tightly only when there's live work.
You can also kick off a single one-off pass by just asking:

- "babysit this PR"
- "watch my PR"
- "/babysit"

It operates on the PR for the current branch by default; pass `--pr N` to the
scanner to target another. It needs the `gh` CLI authenticated, plus `jq`, and
assumes you're inside the target git repo (or pass `--repo owner/name`).

> Run it as `/loop /babysit`, not by nesting `/monitor-pr` or `/babysit-prs`
> inside it — each is its own loop, and two schedulers will fight over the
> session's one wakeup.

## What it does

- **Scans once, read-only, before doing anything.** The bundled `scan.sh`
  resolves the current branch's PR and emits one compact JSON digest — its
  mergeability, a CI rollup, a ~40-line error signature for each failing check,
  and the unresolved human review threads — so the agent spends tokens on fixes,
  not on fetching and parsing. The scanner never commits, pushes, merges, or
  resolves.
- **Fixes in place.** You're already on the PR's branch, so it works the current
  worktree directly — no temp worktree.
- **Routes by bucket.** `CONFLICTING` / `BEHIND` → freshness, `CI_FAIL` → read
  the failing-log excerpt and fix, `HAS_COMMENTS` → triage. A `GREEN_IDLE` or
  `CI_PENDING` PR is left alone. If nothing is actionable, it reports and sleeps
  the suggested delay.
- **Fixes freshness without rewriting history.** Updates the branch only when it
  truly needs it (real conflicts, an up-to-date branch-protection gate, or CI
  that must re-run against new main) via a merge commit — **never** a rebase or
  force-push on a non-draft PR, so reviewers keep their place and inline
  comments stay attached.
- **Fixes only mechanical CI failures autonomously.** Lint, format, unused
  imports, trivially broken tests get appended fix commits. Anything
  non-mechanical — logic, flaky infra, or a fix touching auth, money movement,
  or schema — is reported and handed back to you.
- **Triages review comments, then replies and resolves.** New reviewer threads —
  both inline and root-level — are run through the `triage-pr-comments`
  sub-skill, which owns the whole comment engine: the analysis _and_ the
  reply/resolve mechanics. When a comment leads to a fix, that engine pushes the
  fix, posts a concise reply describing it, and **resolves** the inline thread
  on GitHub (root-level comments get a reply and a ledger ack, since GitHub
  can't resolve them). Threads you've deliberately left as standing gates are
  acked in a local seen-ledger via `mark-seen.sh` so they stop re-surfacing
  every tick; a later reviewer reply mints a fresh signature and the thread
  comes back on its own. Replies to a human reviewer are still drafted for your
  approval first.
- **Works drafts too.** Unlike `babysit-prs`, it doesn't skip a draft PR — you
  invoked it on the PR you're sitting on. It still never rewrites history.
- **Stops and asks at the right moments.** Design/architecture change requests,
  conflicts with genuinely divergent intent, anything that would rewrite history
  on a non-draft PR, and CI fixes touching auth/money/schema all pause for you —
  and it never posts a reply to a human reviewer without showing you a draft
  first.

## Gotchas

- **It needs `gh` and `jq` on PATH**, and `gh` authenticated against the repo.
- **The seen-ledger is local state**, at
  `${XDG_STATE_HOME:-$HOME/.local/state}/babysit/<owner>-<name>.json`, written
  only by `mark-seen.sh`. Deleting it just means every still-open thread
  re-surfaces once. It is separate from babysit-prs's ledger.
