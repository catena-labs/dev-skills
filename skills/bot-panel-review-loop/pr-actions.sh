#!/usr/bin/env bash
# pr-actions.sh — the deterministic GitHub plumbing for one PR's review agent.
#
# Every operation in here is no-judgment: it has exactly one correct form, so it
# lives in a script instead of being hand-assembled (gh/jq/graphql) in each
# per-PR subagent prompt. The agent keeps the judgment (which findings are real,
# the verdict, the comment/summary bodies); this keeps the GitHub calls and the
# error-prone JSON escaping.
#
# Verbs (all resolve the repo via `gh` unless --repo owner/name is passed):
#
#   confirm <num> <queued_head>
#       Re-resolve live PR state at dispatch (Step 4a) and print one disposition
#       line; the agent proceeds only on `ok`:
#         ok <headRefOid>                 reviewable, at the expected head
#         skip skipped (merged|closed)    state left OPEN
#         skip skipped (now draft)        draft and no longer "ready for review"
#         skip skipped (merge conflict)   mergeable == CONFLICTING
#         defer deferred (author pushed)  head moved since enumeration
#
#   react <num> [content]      Add a reaction (default: eyes — the 4a pickup
#                              mark). Dedupes per actor+content server-side.
#
#   settle <num> approve|comments
#       Terminal reaction (Step 4d). approve → drop our eyes, add rocket.
#       comments → leave eyes in place (no-op). Never 👎.
#
#   threads <num>      Every inline review thread already on the PR, one TSV row
#                      each: `resolved|open <TAB> path <TAB> body[:100]`. Reads
#                      resolution state (GraphQL only), so the agent can skip a
#                      FIX comment already covered or one a human resolved (4c).
#
#   comment <num> <path> <line> [--start <n>] [--side RIGHT|LEFT] <body-file>
#       Post one standalone inline review comment (4c). <body-file> holds the
#       raw markdown body (agent-authored, with any ```suggestion block); the
#       script wraps it as JSON and pins commit_id to the live head. Prints
#       `posted` on success, or `offdiff` (exit 0) when GitHub 422s an off-diff
#       line — the agent then folds that finding into the summary instead.
#       --start makes it a multi-line range (start_line..line, both RIGHT).
#
#   summary <num> <body-file>
#       Post a fresh summary comment (4c). A new comment is posted on every
#       review, so the PR keeps a running history of verdicts rather than one
#       overwritten summary. <body-file> holds the raw markdown summary; the
#       script wraps it as JSON (the body's marker is read by the prefilter).
#
# Targets bash 3.2 (macOS system bash).
set -uo pipefail

REPO=""
START=""
SIDE="RIGHT"
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --start) START="${2:-}"; shift 2 ;;
    --side)  SIDE="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "pr-actions.sh: unknown flag: $1" >&2; exit 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

for bin in gh jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "pr-actions.sh: need '$bin' on PATH" >&2; exit 1; }
done

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || true
fi
[[ -z "$REPO" ]] && { echo "pr-actions.sh: could not resolve repo (pass --repo owner/name)" >&2; exit 1; }

[[ ${#args[@]} -ge 1 ]] || { echo "pr-actions.sh: no verb (try --help)" >&2; exit 2; }
verb="${args[0]}"
num="${args[1]:-}"
[[ -n "$num" ]] || { echo "pr-actions.sh: $verb needs a PR number" >&2; exit 2; }

case "$verb" in
  confirm)
    queued="${args[2]:-}"
    [[ -n "$queued" ]] || { echo "pr-actions.sh: confirm needs <num> <queued_head>" >&2; exit 2; }
    read -r state draft head mergeable ready < <(
      gh pr view "$num" -R "$REPO" \
        --json state,isDraft,headRefOid,mergeable,labels \
        -q '"\(.state) \(.isDraft) \(.headRefOid) \(.mergeable) \([.labels[].name] | any(ascii_downcase == "ready for review"))"'
    ) || { echo "pr-actions.sh: confirm failed to read PR #$num" >&2; exit 1; }
    case "$state" in
      MERGED) echo "skip skipped (merged)"; exit 0 ;;
      OPEN)   ;;
      *)      echo "skip skipped (closed)"; exit 0 ;;
    esac
    if [[ "$draft" == "true" && "$ready" != "true" ]]; then
      echo "skip skipped (now draft)"; exit 0
    fi
    [[ "$mergeable" == "CONFLICTING" ]] && { echo "skip skipped (merge conflict)"; exit 0; }
    [[ "$head" != "$queued" ]] && { echo "defer deferred (author pushed; re-check next tick)"; exit 0; }
    echo "ok $head"
    ;;

  react)
    content="${args[2]:-eyes}"
    gh api "repos/$REPO/issues/$num/reactions" \
      --method POST -H "Accept: application/vnd.github+json" -f content="$content" >/dev/null \
      && echo "pr-actions.sh: reacted $content on #$num" >&2
    ;;

  settle)
    verdict="${args[2]:-}"
    case "$verdict" in
      approve)
        me="$(gh api user -q .login)"
        rid="$(gh api "repos/$REPO/issues/$num/reactions" -H "Accept: application/vnd.github+json" \
          -q ".[] | select(.user.login==\"$me\" and .content==\"eyes\") | .id" | head -n1)"
        [[ -n "$rid" ]] && gh api "repos/$REPO/issues/$num/reactions/$rid" --method DELETE >/dev/null 2>&1
        gh api "repos/$REPO/issues/$num/reactions" \
          --method POST -H "Accept: application/vnd.github+json" -f content=rocket >/dev/null \
          && echo "pr-actions.sh: settled #$num eyes -> rocket" >&2
        ;;
      comments)
        echo "pr-actions.sh: left eyes on #$num (do-not-approve)" >&2
        ;;
      *) echo "pr-actions.sh: settle needs approve|comments" >&2; exit 2 ;;
    esac
    ;;

  threads)
    gh api graphql -f owner="${REPO%%/*}" -f repo="${REPO##*/}" -F num="$num" -f query='
      query($owner:String!,$repo:String!,$num:Int!){
        repository(owner:$owner,name:$repo){ pullRequest(number:$num){
          reviewThreads(first:100){ nodes{
            isResolved
            comments(first:1){ nodes{ path body } }
          } } } } }' \
      -q '.data.repository.pullRequest.reviewThreads.nodes[]
          | "\(if .isResolved then "resolved" else "open" end)\t\(.comments.nodes[0].path)\t\(.comments.nodes[0].body | gsub("\n";" ") | .[0:100])"'
    ;;

  comment)
    path="${args[2]:-}"; line="${args[3]:-}"; body_file="${args[4]:-}"
    [[ -n "$path" && -n "$line" && -n "$body_file" && -f "$body_file" ]] \
      || { echo "pr-actions.sh: comment needs <num> <path> <line> [--start n] <body-file>" >&2; exit 2; }
    head="$(gh pr view "$num" -R "$REPO" --json headRefOid -q .headRefOid)" \
      || { echo "pr-actions.sh: comment could not read head of #$num" >&2; exit 1; }
    payload="$(jq -n \
      --arg commit "$head" --arg path "$path" --argjson line "$line" \
      --arg side "$SIDE" --arg start "$START" --rawfile body "$body_file" '
      {commit_id:$commit, path:$path, line:$line, side:$side, body:$body}
      + (if $start == "" then {} else {start_line:($start|tonumber), start_side:$side} end)')"
    out="$(printf '%s' "$payload" | gh api "repos/$REPO/pulls/$num/comments" --method POST --input - 2>&1)"
    if [[ $? -eq 0 ]]; then
      echo "posted"
    elif printf '%s' "$out" | grep -qi 'must be part of'; then
      echo "offdiff"   # line not in the diff: agent folds this finding into the summary body
    else
      # Any other failure (incl. a 422 from an inverted/oversized range or a stale
      # commit_id) is a real error, not an off-diff line — surface it, don't demote.
      echo "pr-actions.sh: comment POST failed on #$num: $out" >&2; exit 1
    fi
    ;;

  summary)
    body_file="${args[2]:-}"
    [[ -n "$body_file" && -f "$body_file" ]] || { echo "pr-actions.sh: summary needs <num> <body-file>" >&2; exit 2; }
    payload="$(jq -Rs '{body: .}' < "$body_file")"
    printf '%s' "$payload" | gh api "repos/$REPO/issues/$num/comments" --method POST --input - >/dev/null \
      && echo "pr-actions.sh: posted summary on #$num (new)" >&2
    ;;

  *) echo "pr-actions.sh: unknown verb: $verb (try --help)" >&2; exit 2 ;;
esac
