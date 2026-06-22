# Phase 2 design: decomposed review for large PRs

Status: design finalized — open questions below are resolved into
recommendations. Not yet wired into `SKILL.md`. When built, this **replaces**
the current Tier-2 treatment ("second independent fan-out") with decomposition;
see "Integration with Phase 1" for the exact `SKILL.md` block to drop in. Phase
1 (the size-driven escalation tier) still ships first and stands on its own
until then.

## Problem

A `--pr` panel review is one gather-and-synthesize pass per fan-out. Phase 1
adds a second independent fan-out for `size: "large"` PRs, but both fan-outs
still hand each model the **entire** diff. On a 100+ file PR that means every
model skims everything: attention dilutes, and a subtle bug in file 80 competes
for the same context budget as boilerplate in file 3. More models over the same
huge diff does not fix per-model dilution; it just buys more skims.

The lever that does fix it is **depth per area**: let each reviewer read ~20
files closely rather than ~100 shallowly.

## Decision summary

The questions raised while designing this, and what they resolved to (rationale
in the sections below):

| Question                                          | Resolution                                                                                                                                                                                    |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Who decomposes — a panelist or the orchestrator?  | **The per-PR orchestrator.** Panelists are stateless CLI subprocesses that only return findings; the orchestrator already holds the changed-file list.                                        |
| Chunk by area vs by surface?                      | **Semantic chunking, with each sensitive surface forced into its own chunk.** Surface-isolation is a hard constraint on top of an LLM-chosen grouping.                                        |
| Does the seam reviewer need the full diff?        | **Yes — full diff as read-only context, findings only on cross-boundary interfaces.** Safety beats the marginal token cost for one reviewer.                                                  |
| Should `panel-review` grow a `--paths` scope?     | **No — out of scope.** Chunk reviewers do cheap direct `gh pr diff -- <paths>` reads. Revisit only if `panel-review` adds path scoping for its own reasons.                                   |
| Replace Tier 2, or add a Tier 3?                  | **Replace Tier 2.** The second identical fan-out is the weak lever; decomposition strictly dominates it. No Tier 3 — fewer thresholds to tune.                                                |
| Build substrate — nested subagents or a workflow? | **A workflow.** It is a fan-out/synthesize DAG with a real synthesizer stage and typed ledgers; nested subagents are the fallback when a workflow cannot be launched from the per-PR context. |

## Goal

For Tier-2 PRs (large, or large + sensitive), get deep per-area review without:

- losing cross-cutting bugs at the seams between areas,
- breaking the inline-comment dedup + engagement-marker model,
- multiplying `panel-review` git-worktree contention, or
- spending unbounded tokens.

## Mechanism

The per-PR agent the sweep already dispatches is the **orchestrator**. It fans
out a small set of gather-only sub-reviews, then a **synthesizer** merges and
posts once. Panelists never decompose — they are non-interactive CLI
subprocesses that return findings and nothing else; the orchestrator is the only
actor that already holds the changed-file list (fetched for sensitive-surface
classification), so it is the natural and only place to chunk.

1. **Chunk the changed-file list — semantically, with surface isolation.** The
   orchestrator reads the changed-file list (and a cheap diff summary) and
   groups files into <= 4 coherent chunks by _what they do_, not merely by path
   prefix — a feature that spans `apps/api` + `apps/web` + a shared type belongs
   in one chunk, because reviewing it whole is what catches its bugs. **Hard
   constraint: every sensitive surface (auth/authz, money movement,
   schema/migration, secrets/external) gets its own dedicated chunk**, so the
   deepest, most isolated read always sits on the riskiest code and is never
   diluted by boilerplate in the same chunk. Cap at 4 chunks; group the long
   tail into a "rest" chunk. (Mechanical area- or surface-only grouping is the
   fallback if a semantic split is ambiguous — but the surface-isolation
   constraint is non-negotiable either way.)

2. **One scoped reviewer per chunk.** Each reviewer reads the **full diff for
   context** but raises findings **only on its assigned paths** — the rest of
   the diff is read-only context, not re-litigated. This scoping is what
   preserves cross-cutting awareness while parallelizing the close read.

3. **One seam reviewer.** A contract change in `packages/X` that breaks a caller
   in `apps/Y` is exactly what chunk-local reviewers miss. One pass reads the
   full diff for context but raises findings **only on the interfaces touched
   across chunk boundaries**: changed exported signatures, shared types,
   migration-vs-repo column drift, API request/response shapes. Full-diff
   context (not just the interface deltas) is the safe choice — a seam bug often
   only reveals itself from both sides, and it is one reviewer, so the extra
   read does not multiply.

4. **One synthesizer.** Collects every chunk + seam + panel ledger, dedupes by
   issue (the `[SEV]` headline, not the line), applies the global FIX/FOREGO
   calibration, runs Tier-1 adversarial verification on surviving HIGH/CRITICAL,
   and is the **only** actor that touches GitHub: posts the not-already-covered
   inline comments and posts the summary via `pr-actions.sh`. Chunk and seam
   reviewers are pure gather-only and **return** their ledgers; they never post.
   This is what keeps idempotency intact.

## Why the depth-vs-cost knob is the panel, not the chunking

Running a full multi-model `panel-review` _inside each chunk_ would materialize
`chunks x panelists` git worktrees for one PR, and `SKILL.md` already flags
worktree contention as the real concurrency limit. So the recommended shape is a
**hybrid**:

- Chunk reviewers do **lightweight direct reads** (`gh pr diff -- <paths>`, no
  worktree, no `panel-review`) — single strong model each, scoped. Cheap, no
  `.git` contention, parallelizable.
- The **multi-model panel** runs once over the whole PR for cross-cutting
  coherence (this is just the Phase-1 Tier-0 fan-out — the original 1 codex + 1
  claude, preserved). It is _not_ run a second time; decomposition is what
  replaces the second pass.
- Synthesizer unions: panel ledger (breadth/coherence) + chunk ledgers (depth) +
  seam ledger (interfaces).

So decomposition adds _depth_ via cheap scoped reads, while the expensive panel
stays bounded to its single whole-PR fan-out. Worktree count stays at "one
fan-out's worth," not `chunks x panelists`.

## Build substrate: a workflow

The decomposition is a fan-out/synthesize DAG, which is exactly what a workflow
models. Recommended shape:

```
chunk stage   -> agent reads changed-file list + diff summary,
                 returns <= 4 chunks + the seam interface list (structured output)
review stage  -> parallel: one scoped reviewer per chunk
                          + one seam reviewer
                          + the whole-PR panel (panel-review --pr) once
                 each returns a typed ledger; none post
synth stage   -> one synthesizer: union -> dedupe -> calibrate -> verify
                 -> post inline + post summary + settle (the only GitHub writes)
```

A workflow gives a deterministic fan-out, a real synthesizer stage with every
ledger in hand, and structured-output schemas so the synthesizer gets typed
findings instead of parsed prose. The per-PR orchestrator launches this workflow
for its single Tier-2 PR; the fan-out is bounded (<= 4 chunks + seam + panel +
synth = <= 7 agents), so even inside an autonomous `/loop` the spend per Tier-2
PR is capped and auditable.

**Fallback — nested subagents from the per-PR brief.** If a workflow cannot be
launched from the dispatched per-PR context (or the runtime forbids the
nesting), the orchestrator spawns the chunk/seam reviewers as parallel `Agent`
calls and synthesizes inline. Lower ceremony, but the parent/synthesizer wiring
lives in prose in the dispatch brief and is easier to drift, and ledgers arrive
as prose rather than typed objects. Prefer the workflow; keep this as the escape
hatch.

## Posting / idempotency (unchanged contract)

- Exactly one fresh summary comment (carrying the
  `<!-- bot-panel-review-loop: head= -->` marker) and one `settle` per review.
  Only the synthesizer posts.
- The synthesizer still runs the `threads` dedup before posting inline comments,
  so re-reviews on UPDATED pushes do not double-post them — same rule as today.
- The reviewers' ledgers are in-memory return values, never GitHub writes, so a
  chunk reviewer dying mid-run leaves no partial state on the PR.

## Cost & concurrency guardrails

- Tier 2 only. Tier 0/1 never decompose.
- Cap chunks at 4 and reviewers at chunks + 1 seam + 1 panel + 1 synthesizer.
- The whole-PR panel runs **once**, not twice — decomposition is the replacement
  for the second fan-out, not an addition to it.
- While a PR is being decomposed, drop the outer per-PR sweep concurrency for
  that tick (decomposition is the heavy job; do not also run 2-3 other PRs'
  panels against the same `.git`).
- Emit one visible line: chosen chunks, reviewer count, and the rationale, so
  the spend is auditable (mirrors the Phase-1 tier log line).

## Integration with Phase 1

Phase 1's `size` field and Tier table already gate this. Phase 2 **redefines
Tier 2 in place** — same trigger (`size: "large"`, or large AND sensitive), new
treatment. The escalation policy block in `SKILL.md` Step 4 is the single place
that changes when this lands. The exact replacement for the current Tier-2
bullet:

> - **Tier 2 — `size: "large"`, or large AND sensitive.** Do not skim the whole
>   diff twice. **Decompose** instead. As the per-PR orchestrator, group the
>   changed-file list into <= 4 coherent chunks (semantic grouping by what the
>   code does, but force each sensitive surface — auth/authz, money, schema,
>   secrets — into its own chunk). Then fan out, all gather-only:
>   - **one scoped deep-dive reviewer per chunk** — a direct
>     `gh pr diff -- <paths>` read (single strong model, no worktree) that reads
>     the full diff for context but raises findings only on its assigned paths;
>   - **one seam reviewer** — reads the full diff but raises findings only on
>     changed cross-boundary interfaces (exported signatures, shared types,
>     migration-vs-repo column drift, API request/response shapes), the bugs
>     chunk-local reviewers structurally miss;
>   - **the whole-PR multi-model panel exactly once** (the Tier-0 fan-out) for
>     breadth and cross-cutting coherence — not a second time. Then synthesize:
>     as the single synthesizer, union every ledger, dedupe by the `[SEV]`
>     headline, apply the FIX/FOREGO calibration, and run Tier-1 adversarial
>     verification on the surviving HIGH/CRITICAL set. You are the only actor
>     that posts. State the chunks and reviewer count in the tier log line (e.g.
>     `tier 2: 102 files; 4 chunks + seam + panel`). See
>     `DESIGN-phase2-decomposition.md` for the full mechanism.

The Tier-2 line in the **Panel** summary and the Step-5 report table both keep
their shape; only the parenthetical changes from "2 fan-outs unioned" to the
chunk/reviewer breakdown.

## Resolved questions

1. **Chunking by area vs by surface.** Resolved: **semantic chunking with forced
   surface isolation.** Group by what the code does, but every sensitive surface
   gets its own chunk so the deepest read always sits on the riskiest code. A
   historical bake-off (area vs surface vs semantic on past large PRs) is still
   worth running to tune the chunker prompt, but surface-isolation is fixed.
2. **Does the seam reviewer need the full diff?** Resolved: **yes, full diff as
   read-only context, findings only on cross-boundary interfaces.** Full is
   safer and it is a single reviewer, so the extra read does not multiply across
   the fan-out.
3. **Should `panel-review` grow a `--paths` scope?** Resolved: **no, out of
   scope** for this skill. Chunk reviewers stay as cheap direct reads. If
   `panel-review` ever adds path scoping for its own reasons, revisit whether
   chunk reviewers should become real (worktree-isolated) scoped panels — but
   that is a change to a different skill and would only matter if per-chunk
   multi-model depth proves necessary, which the hybrid is designed to avoid.
4. **Threshold for decompose vs two-fan-out.** Resolved by **removing the
   distinction**: there is no Tier 3, and the two-fan-out treatment is gone.
   Tier 2's existing trigger (large, or large + sensitive) now means
   "decompose." One tier, one threshold.
