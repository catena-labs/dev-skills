# decompose — orchestrated panelist

An orchestrated `panel-review` panelist that improves _recall_ on a change by
reviewing it in focused pieces instead of one whole-diff pass. An LLM reading a
large diff in a single pass spreads its attention thin and skims past subtle
bugs; a reviewer responsible for a handful of files reads them closely.
`decompose` runs several such focused reviewers plus a dedicated cross-boundary
pass, then returns one merged ledger that folds into the panel synthesis like
any other panelist.

It is **gather-only**: it reads code and returns findings. It never edits,
commits, pushes, or posts — the `panel-review` coordinator owns all output.

## When it runs

Opt-in. The default panel is CLI-only; `decompose` is added when the user asks
for it or a caller always includes it (e.g. `bot-panel-review-loop`). It
_composes_ with the CLI panelists: they review the whole diff, `decompose`
reviews it in pieces, and synthesis merges both. Running it alongside at least
one CLI panelist is the point — `decompose` adds depth, the CLI panel adds
breadth.

## Inputs

- The review target, and how to read its diff (whole and path-scoped):
  - **PR:** `gh pr diff <ref>` / `gh pr diff <ref> -- <paths>`.
  - **`--base` / `--commit`:** `git diff <base>...<head>` / `... -- <paths>`.
  - **`--uncommitted` / `--staged`:** `git diff` / `git diff --staged`, scoped
    with `-- <paths>`.
- The changed-file list (the same command with `--name-only`).

## Procedure

1. **Chunk the changed-file list into ≤ 4 coherent groups.** Group semantically
   by what the code _does_, not by path prefix — a feature spanning `api` +
   `web` + a shared type belongs in one chunk, because reviewing it whole is
   what catches its bugs. **Force each sensitive surface (auth/authz, money
   movement, schema/migration, secrets/external) into its own chunk** so the
   closest read sits on the riskiest code; sweep the long tail into a "rest"
   chunk. **Self-scale down:** a small diff may only support one or two real
   chunks — make as many as the diff actually has, never pad to four.

2. **Fan out, all gather-only.** Spawn these as subagents; if your runtime
   cannot nest subagents, do the reads inline and sequentially — the depth comes
   from the scoping, not the parallelism.
   - **One scoped reviewer per chunk** — reads the _whole_ diff for context but
     raises findings _only on its assigned paths_. A single strong model reading
     the path-scoped diff directly (no worktree).
   - **One seam reviewer** — reads the whole diff but raises findings _only on
     changed cross-boundary interfaces_: exported signatures, shared types,
     migration-vs-repo column drift, API request/response shapes — the bugs the
     chunk-local reviewers structurally miss.

3. **Merge into one ledger.** Union the chunk and seam findings and dedupe by
   issue (match on the bold `[SEV]` headline, not the line — lines drift, the
   point does not). Form a `Goal:` / `Approach:` tag from your own read of the
   diff. Return the ledger; do not post it anywhere.

## Output

One ledger in the standard per-finding shape, attributed
`Flagged by: decompose`:

```md
- [SEVERITY] file:line — one-sentence issue. Fix: one-sentence change. Flagged
  by: decompose
```

The coordinator folds this into synthesis like any panelist — a finding only
`decompose` caught surfaces as unique; one a CLI panelist also caught becomes
consensus on the same `Flagged by:` line.

## Cost & guards

- Cap chunks at 4; one seam reviewer, never more.
- Chunk reviewers are direct path-scoped reads (single model, no worktree), so
  they add depth without multiplying `panel-review`'s git-worktree contention —
  the worktree count stays at the CLI panel's, not `chunks × panelists`.
- Why this shape and not "run the whole panel twice": the multi-model CLI panel
  already gives breadth over the whole diff. `decompose` adds _depth_ via cheap
  scoped reads and the seam pass — the two are complementary, not redundant.
