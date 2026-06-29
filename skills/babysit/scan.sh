#!/usr/bin/env bash
# scan.sh — read-only scan for the babysit skill (single PR).
#
# Emits one compact JSON digest of the ONE PR this branch is on (or the PR
# passed via --pr) so the coding agent spends tokens on fixes, not on
# data-gathering. It does the deterministic work — roll up CI, extract just the
# error signature from
# failing-check logs, count unresolved human review threads, scan root-level
# comments, bucket for routing, recommend the next /loop delay — but for one PR
# instead of the whole fleet. The script never commits, pushes, merges, or
# resolves anything — it only reads.
#
# Output (stdout, JSON):
#   {
#     "repo": "owner/name",
#     "anythingToDo": bool,            // the PR is in an actionable bucket
#     "suggestedDelaySeconds": 270|1800,
#     "pr": null | {                   // null => this branch has no open PR
#        "number", "title", "branch", "isDraft",
#        "mergeable", "mergeState", "reviewDecision",
#        "ci": { "passed", "failed", "pending", "failing": [ {name, link} ] },
#        "unresolvedThreads": int,     // unresolved, not-outdated, last non-bot/non-ignored comment is a reviewer (total)
#        "newThreads": int,            // of those, NOT yet in the seen-ledger
#        "standingGates": int,         // of those, already acked (silenced, unchanged)
#        "threads": [ {sig, threadId, path, line, lastAuthor, at} ],  // the unseen ones only
#        "newRootComments": int,       // unseen non-author, non-bot root (issue) comments
#        "standingRootGates": int,     // of those, already acked
#        "rootComments": [ {sig, author, at} ],  // the unseen root comments only
#        "newReviewComments": int,     // unseen non-author, non-bot review-summary bodies
#        "standingReviewGates": int,   // of those, already acked
#        "reviewComments": [ {sig, author, state, at} ],  // the unseen review summaries only
#        "failingLogs": [ {check, jobId, excerpt} ],  // error signature only, capped
#        "bucket": "CONFLICTING|CI_FAIL|HAS_COMMENTS|BEHIND|CI_PENDING|GREEN_IDLE"
#     }
#   }
#
# Drafts are NOT excluded: you invoked this skill on the PR
# you are sitting on, so it works the PR whether or not it is a draft. isDraft is
# carried through so the agent can mention it.
#
# Three comment channels are scanned: inline review threads (`threads`),
# root-level PR conversation comments (`rootComments`), and review-summary bodies
# (`reviewComments`). The root channel catches a finding a reviewer drops on a
# line outside the diff; the review channel catches a CHANGES_REQUESTED review
# whose feedback lives in the top-level body with no inline/root comment — the
# inline-thread query sees neither. All three feed HAS_COMMENTS.
#
# Seen-ledger: an inline thread's `sig` is "c"+<id of its last non-bot,
# non-ignored comment> (a reviewer's, for any surfaced thread), a root comment's
# `sig` is "r"+<comment id>, and a review summary's `sig` is "v"+<review id>, so
# a reviewer reply or new review (new id) mints a fresh sig and re-surfaces the
# item — while a trailing bot reply does not. mark-seen.sh (the only writer) records sigs the agent
# triaged to a no-further-action verdict; this scanner only READS the ledger to
# split new items from standing (acked) ones. HAS_COMMENTS fires on newThreads,
# newRootComments, or newReviewComments, so once every item is acked the PR goes
# quiet until one changes. Ledger lives at
# ${XDG_STATE_HOME:-$HOME/.local/state}/babysit/<owner>-<name>.json.
#
# Usage:
#   scan.sh [--repo owner/name] [--pr N] [--no-logs]
#
# Notes:
# - No `set -e`: `gh pr checks` exits non-zero when a check is failing/pending
#   while still printing valid JSON to stdout. Aborting on that exit would drop
#   the data we want. We guard each call individually instead.
# - Log excerpts use the REST per-job logs endpoint
#   (`repos/{repo}/actions/jobs/{id}/logs`), NOT `gh run view --log-failed`:
#   gh refuses to download any log while the overall run is still in progress
#   (other jobs pending), even for a job that already failed. The REST endpoint
#   returns the finished job's log regardless. The full (often multi-thousand-
#   line) log is fetched here and reduced to a ~40-line error signature so it
#   never reaches the agent's context.
set -uo pipefail

REPO=""
PR=""
INCLUDE_LOGS=1
# Comma-separated logins to drop from root-level comments on top of the [bot]
# accounts already filtered. Defaults to catena's review bot (catenabot), which
# posts advisory panel reviews from a regular User account. Override, or clear
# with an empty value, via BABYSIT_IGNORE_LOGINS=foo,bar.
IGNORE_LOGINS="${BABYSIT_IGNORE_LOGINS-catenabot}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) [[ $# -ge 2 && -n "${2:-}" ]] || { echo "scan.sh: --repo requires owner/name" >&2; exit 2; }; REPO="$2"; shift 2 ;;
    --pr) [[ $# -ge 2 && -n "${2:-}" ]] || { echo "scan.sh: --pr requires a PR number" >&2; exit 2; }; PR="$2"; shift 2 ;;
    --no-logs) INCLUDE_LOGS=0; shift ;;
    -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "scan.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

for bin in gh jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "scan.sh: need '$bin' on PATH" >&2; exit 1; }
done

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || true
fi
[[ -z "$REPO" ]] && { echo "scan.sh: could not resolve repo slug (pass --repo owner/name)" >&2; exit 1; }
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# Seen-ledger (read-only here; mark-seen.sh is the only writer). A malformed or
# absent file degrades to an empty object so a corrupt ledger never blocks a
# sweep — at worst every thread reads as unseen and re-surfaces once.
LEDGER="${XDG_STATE_HOME:-$HOME/.local/state}/babysit/${OWNER}-${NAME}.json"
ledger="$(cat "$LEDGER" 2>/dev/null)"
printf '%s' "$ledger" | jq -e 'type == "object"' >/dev/null 2>&1 || ledger="{}"

# Reduce a failing job's log to just its error signature, capped hard so a
# pathological log can't blow up the digest. Strip the leading ISO timestamp
# each runner line carries so the budget holds signal, not clock noise. Prefer
# error-ish lines; fall back to the tail, which usually carries the failing
# assertion or summary.
log_excerpt_for_job() {
  local job_id="$1" log excerpt
  log="$(gh api "repos/$REPO/actions/jobs/$job_id/logs" 2>/dev/null)" || true
  [[ -z "$log" ]] && return 0
  log="$(printf '%s\n' "$log" | sed -E 's/^[0-9]{4}-[0-9T:.-]+Z //')"
  excerpt="$(printf '%s\n' "$log" | grep -iE 'error|fail|✖|✗|exception|expected|assert|not found|undefined|panic' | tail -n 40)"
  [[ -z "$excerpt" ]] && excerpt="$(printf '%s\n' "$log" | tail -n 40)"
  printf '%s' "$excerpt" | head -c 2000
}

# Run a read-only gh data fetch and abort the whole scan if it fails, rather than
# letting an auth / rate-limit / network / API error degrade to empty data and a
# phantom GREEN_IDLE (a ~30-min nap on an unscanned PR). Stdout is the payload;
# stderr is captured to $gherr and surfaced on failure. `gh pr checks` is handled
# separately below — it exits non-zero on failing/pending checks, which is valid,
# so it cannot use this all-or-nothing helper.
gh_fetch() {
  local label="$1"; shift
  local out rc
  out="$("$@" 2>"$gherr")"; rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "scan.sh: failed to fetch $label (gh exited $rc):" >&2
    cat "$gherr" >&2
    exit 1
  fi
  printf '%s' "$out"
}

# Resolve the ONE PR to work. With --pr N, that exact PR; otherwise the PR for
# the current branch. Three outcomes are kept distinct — folding them all into
# `2>/dev/null || pr=""` would turn an auth/network/API error into a silent
# pr:null and a ~30-min nap on a phantom "no PR":
#   - fetched OK but state != OPEN  -> emit pr:null (a closed/merged PR is
#     nothing to babysit, and honors the "null when no open PR" contract).
#   - default (current-branch) mode and the branch has no PR  -> emit pr:null.
#   - explicit --pr, or any other gh error  -> print it and exit non-zero so the
#     loop stops instead of mistaking a real failure for "nothing to do".
view_args=(--json number,title,headRefName,isDraft,state,author,mergeable,mergeStateStatus,reviewDecision)
# Explicit --pr targets that PR in $REPO; default mode resolves the current
# branch's PR from the ambient git context. -R is omitted in the default case on
# purpose: `gh pr view -R <repo>` demands a positional number/branch and errors
# without one, which the old `2>/dev/null` hid as a phantom pr:null.
if [[ -n "$PR" ]]; then
  view_cmd=(gh pr view "$PR" "${view_args[@]}" -R "$REPO")
else
  view_cmd=(gh pr view "${view_args[@]}")
fi
pr_err="$(mktemp)"
gherr="$(mktemp)"
trap 'rm -f "$pr_err" "$gherr"' EXIT
if pr="$("${view_cmd[@]}" 2>"$pr_err")"; then
  [[ "$(printf '%s' "$pr" | jq -r '.state')" == "OPEN" ]] || pr=""
elif [[ -z "$PR" ]] && grep -qiE 'no .*pull requests? found' "$pr_err"; then
  pr=""   # current branch genuinely has no PR — nothing to babysit
else
  echo "scan.sh: could not resolve PR via 'gh pr view':" >&2
  cat "$pr_err" >&2
  exit 1
fi
if [[ -z "$pr" ]]; then
  jq -n --arg repo "$REPO" '{repo:$repo, anythingToDo:false, suggestedDelaySeconds:1800, pr:null}'
  exit 0
fi

num="$(printf '%s' "$pr" | jq '.number')"
title="$(printf '%s' "$pr" | jq -r '.title')"
branch="$(printf '%s' "$pr" | jq -r '.headRefName')"
isdraft="$(printf '%s' "$pr" | jq '.isDraft')"
author="$(printf '%s' "$pr" | jq -r '.author.login // ""')"
mergeable="$(printf '%s' "$pr" | jq -r '.mergeable')"
mergestate="$(printf '%s' "$pr" | jq -r '.mergeStateStatus')"
reviewdec="$(printf '%s' "$pr" | jq -r '.reviewDecision // ""')"

# CI rollup. gh pr checks exits non-zero both for failing/pending checks (valid —
# stdout is still a JSON array) and for real fetch errors (auth/network). Trust
# any valid-JSON stdout regardless of exit; otherwise distinguish a benign "no
# checks reported" (treat as no checks) from a real error, and abort on the
# latter rather than misread an unscanned PR as GREEN_IDLE and nap.
checks="$(gh pr checks "$num" -R "$REPO" --json name,state,bucket,link 2>"$gherr")" || true
if ! printf '%s' "$checks" | jq -e 'type == "array"' >/dev/null 2>&1; then
  if grep -qiE 'no checks? (reported|found)' "$gherr"; then
    checks="[]"   # PR has no checks configured — nothing failing
  else
    echo "scan.sh: failed to fetch CI checks via 'gh pr checks':" >&2
    cat "$gherr" >&2
    exit 1
  fi
fi
ci="$(printf '%s' "$checks" | jq '{
  passed:  [.[] | select(.bucket=="pass")]    | length,
  failed:  [.[] | select(.bucket=="fail")]    | length,
  pending: [.[] | select(.bucket=="pending")] | length,
  failing: [.[] | select(.bucket=="fail") | {name, link}]
}')"

# Unresolved review threads whose last comment is from someone other than the
# author (and not a bot / ignored login — see the filter below). This is a
# routing signal only; triage-pr-comments does the precise Fix/Dismiss filtering
# (already-replied, etc.) once the agent acts. Each thread's comments are fetched
# first:100 (not inner-paginated) — an accepted cap, since a single inline thread
# with >100 comments is unrealistic; the representative-comment pick below would
# then only consider the first 100.
threads_raw="$(gh_fetch "review threads" gh api graphql --paginate \
  -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100, after: $endCursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              path
              line
              comments(first: 100) {
                nodes { databaseId author { login __typename } createdAt }
              }
            }
          }
        }
      }
    }
  ' -f owner="$OWNER" -f repo="$NAME" -F pr="$num")"
threads="$(printf '%s' "$threads_raw" | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]?]')"
[[ -z "$threads" ]] && threads="[]"

# One object per unresolved, not-outdated thread whose last NON-bot, NON-ignored
# comment is from someone other than the author — i.e. a reviewer has the last
# real word and the author has not yet responded. That single representative
# comment (`$last` below) carries the seen-ledger signature ("c"+its id), the
# timestamp, and the author shown; whether its sig is acked splits new vs
# standing. Keying everything to the last real comment — skipping trailing bot /
# IGNORE_LOGINS chatter — is what makes all the cases line up:
#   - pure bot thread (e.g. coderabbitai): no real comment, dropped — otherwise
#     it routes HAS_COMMENTS every tick until manually acked;
#   - human thread, bot replies last: the reviewer comment is still the last real
#     one, so it stays visible and reaches triage;
#   - author replied after the reviewer: the author is the last real comment,
#     dropped — the agent already answered, re-surfacing risks a duplicate reply;
#   - a genuinely new reviewer reply mints a fresh sig and re-surfaces; a later
#     bot or author reply does not churn it.
# This mirrors the bot / IGNORE_LOGINS drop and the sig-keyed-to-the-passing-
# comment shape of the root and review channels below (and the documented
# Filtering behavior).
threads_full="$(printf '%s' "$threads" | jq \
  --arg author "$author" --argjson ledger "$ledger" --arg ignore "$IGNORE_LOGINS" '
  ($ignore | split(",") | map(select(. != ""))) as $ignored
  | [ .[]
      | select(.isResolved == false and .isOutdated == false)
      | ( [ .comments.nodes[]
            | (.author.login // "") as $cl
            | select(((.author.__typename // "") != "Bot")
                     and (($ignored | index($cl)) | not)) ]
          | last ) as $last
      | select($last != null
               and $last.databaseId != null
               and ($last.author.login // "") != $author)
      | ("c" + ($last.databaseId | tostring)) as $sig
      | { sig: $sig, threadId: .id, path: .path, line: .line,
          lastAuthor: ($last.author.login // ""), at: $last.createdAt,
          seen: ($ledger | has($sig)) }
    ]')"
unresolved="$(printf '%s' "$threads_full" | jq 'length')"
newcount="$(printf '%s' "$threads_full" | jq '[.[] | select(.seen == false)] | length')"
standing="$(printf '%s' "$threads_full" | jq '[.[] | select(.seen == true)] | length')"
newthreads="$(printf '%s' "$threads_full" | jq '[.[] | select(.seen == false) | del(.seen)]')"

# Root-level (issue) comments on the PR conversation — reviewer feedback posted
# to the thread rather than inline (e.g. a finding on a line outside the diff).
# The reviewThreads query above never sees these, so without this channel a
# human comment here is silently missed. Drop the author's own comments, [bot]
# accounts, and any login in IGNORE_LOGINS; tag the rest with a seen-ledger sig
# ("r"+comment id) and split new vs already-acked, mirroring threads. Bodies are
# omitted on purpose — the agent fetches them for just the unseen ids.
root_raw="$(gh_fetch "root comments" gh api --paginate "repos/$REPO/issues/$num/comments")"
root_raw="$(printf '%s' "$root_raw" | jq -s '[.[][]?]')"
[[ -z "$root_raw" ]] && root_raw="[]"
root_full="$(printf '%s' "$root_raw" | jq \
  --arg author "$author" --argjson ledger "$ledger" --arg ignore "$IGNORE_LOGINS" '
  ($ignore | split(",") | map(select(. != ""))) as $ignored
  | [ .[]
      | (.user.login // "") as $login
      | select($login != $author
               and ((.user.type // "") != "Bot")
               and (($ignored | index($login)) | not))
      | ("r" + (.id | tostring)) as $sig
      | { sig: $sig, author: $login, at: .created_at,
          seen: ($ledger | has($sig)) }
    ]')"
[[ -z "$root_full" ]] && root_full="[]"
rootnewcount="$(printf '%s' "$root_full" | jq '[.[] | select(.seen == false)] | length')"
rootstanding="$(printf '%s' "$root_full" | jq '[.[] | select(.seen == true)] | length')"
rootnew="$(printf '%s' "$root_full" | jq '[.[] | select(.seen == false) | del(.seen)]')"

# Review-summary bodies (from pulls/{n}/reviews) — the third feedback channel. A
# reviewer can request changes with their reasoning in the top-level review body
# and no inline/root comment, which neither channel above sees; without this a
# body-only CHANGES_REQUESTED review buckets as GREEN_IDLE and the PR silently
# stalls. Keep non-empty, non-dismissed bodies from non-author, non-bot,
# non-ignored reviewers; sig is "v"+<review id>, split new vs already-acked like
# the other channels. State is carried so triage can read APPROVED-with-body as a
# likely dismiss without re-fetching.
reviews_raw="$(gh_fetch "review summaries" gh api --paginate "repos/$REPO/pulls/$num/reviews")"
reviews_raw="$(printf '%s' "$reviews_raw" | jq -s '[.[][]?]')"
[[ -z "$reviews_raw" ]] && reviews_raw="[]"
reviews_full="$(printf '%s' "$reviews_raw" | jq \
  --arg author "$author" --argjson ledger "$ledger" --arg ignore "$IGNORE_LOGINS" '
  ($ignore | split(",") | map(select(. != ""))) as $ignored
  | [ .[]
      | (.user.login // "") as $login
      | select(((.body // "") | gsub("\\s"; "")) != ""
               and .state != "DISMISSED"
               and $login != $author
               and ((.user.type // "") != "Bot")
               and (($ignored | index($login)) | not))
      | ("v" + (.id | tostring)) as $sig
      | { sig: $sig, author: $login, state: .state, at: .submitted_at,
          seen: ($ledger | has($sig)) }
    ]')"
[[ -z "$reviews_full" ]] && reviews_full="[]"
reviewnewcount="$(printf '%s' "$reviews_full" | jq '[.[] | select(.seen == false)] | length')"
reviewstanding="$(printf '%s' "$reviews_full" | jq '[.[] | select(.seen == true)] | length')"
reviewnew="$(printf '%s' "$reviews_full" | jq '[.[] | select(.seen == false) | del(.seen)]')"

# Error signatures for failing checks, deduped by job and capped at 3 jobs.
logs="[]"
if [[ "$INCLUDE_LOGS" == "1" ]]; then
  log_objs=()
  seen_jobs=" "
  while IFS= read -r entry; do
    [[ ${#log_objs[@]} -ge 3 ]] && break
    [[ -z "$entry" ]] && continue
    fname="$(printf '%s' "$entry" | jq -r '.name')"
    jid="$(printf '%s' "$entry" | jq -r '.link' | sed -nE 's#.*/job/([0-9]+).*#\1#p')"
    [[ -z "$jid" ]] && continue
    [[ "$seen_jobs" == *" $jid "* ]] && continue
    seen_jobs="$seen_jobs$jid "
    ex="$(log_excerpt_for_job "$jid")"
    [[ -z "$ex" ]] && continue
    log_objs+=("$(jq -n --arg check "$fname" --arg jid "$jid" --arg ex "$ex" \
      '{check:$check, jobId:$jid, excerpt:$ex}')")
  done < <(printf '%s' "$ci" | jq -c '.failing[]?')
  [[ ${#log_objs[@]} -gt 0 ]] && logs="$(printf '%s\n' "${log_objs[@]}" | jq -s '.')"
fi

# Bucket by highest-priority actionable condition. Raw fields stay in the
# object so the agent sees the full picture; the bucket is only the hint.
failed="$(printf '%s' "$ci" | jq '.failed')"
pending="$(printf '%s' "$ci" | jq '.pending')"
if [[ "$mergeable" == "CONFLICTING" || "$mergestate" == "DIRTY" ]]; then
  bucket="CONFLICTING"
elif [[ "$failed" -gt 0 ]]; then
  bucket="CI_FAIL"
elif [[ "$newcount" -gt 0 || "$rootnewcount" -gt 0 || "$reviewnewcount" -gt 0 ]]; then
  bucket="HAS_COMMENTS"
elif [[ "$mergestate" == "BEHIND" ]]; then
  bucket="BEHIND"
elif [[ "$pending" -gt 0 ]]; then
  bucket="CI_PENDING"
else
  bucket="GREEN_IDLE"
fi

pr_obj="$(jq -n \
  --argjson number "$num" \
  --arg title "$title" \
  --arg branch "$branch" \
  --argjson isDraft "$isdraft" \
  --arg mergeable "$mergeable" \
  --arg mergeState "$mergestate" \
  --arg reviewDecision "$reviewdec" \
  --argjson ci "$ci" \
  --argjson unresolvedThreads "$unresolved" \
  --argjson newThreads "$newcount" \
  --argjson standingGates "$standing" \
  --argjson threads "$newthreads" \
  --argjson newRootComments "$rootnewcount" \
  --argjson standingRootGates "$rootstanding" \
  --argjson rootComments "$rootnew" \
  --argjson newReviewComments "$reviewnewcount" \
  --argjson standingReviewGates "$reviewstanding" \
  --argjson reviewComments "$reviewnew" \
  --argjson failingLogs "$logs" \
  --arg bucket "$bucket" \
  '{number:$number, title:$title, branch:$branch, isDraft:$isDraft,
    mergeable:$mergeable, mergeState:$mergeState, reviewDecision:$reviewDecision,
    ci:$ci, unresolvedThreads:$unresolvedThreads, newThreads:$newThreads,
    standingGates:$standingGates, threads:$threads,
    newRootComments:$newRootComments, standingRootGates:$standingRootGates,
    rootComments:$rootComments,
    newReviewComments:$newReviewComments, standingReviewGates:$standingReviewGates,
    reviewComments:$reviewComments, failingLogs:$failingLogs,
    bucket:$bucket}')"

printf '%s' "$pr_obj" | jq --arg repo "$REPO" '
  { actionable: ["CONFLICTING","CI_FAIL","HAS_COMMENTS","BEHIND"],
    busy:       ["CONFLICTING","CI_FAIL","HAS_COMMENTS","BEHIND","CI_PENDING"] } as $sets
  | { repo: $repo,
      anythingToDo: (.bucket as $b | ($sets.actionable | index($b)) != null),
      suggestedDelaySeconds: (if (.bucket as $b | ($sets.busy | index($b)) != null) then 270 else 1800 end),
      pr: . }'
