#!/usr/bin/env bash
#
# Deterministic prefilter for the bot-panel-review-loop skill.
#
# Runs every selection gate that needs no LLM judgment (draft / flag filters /
# merge conflict / engagement marker / CI status) and
# emits only the distilled result, so the giant `gh pr list` JSON, the per-PR
# marker reads, and the CI-check output never enter the model's context. The
# heavy work the script intentionally leaves to the LLM is the panel review and
# the verdict, which is everything downstream of selection.
#
# Output (stdout), two sections delimited by sentinel lines:
#
#   ===ACTIONABLE_JSON===
#   [ {"number","title","head","engagement","ci","note","revisit"}, ... ]
#   ===REPORT_TABLE===
#   | PR | Title | Engagement | Result | Effort/Risk | Panel | Human |
#   | ... one row per open PR (unlabeled drafts dropped); actionable rows carry PENDING_VERDICT ... |
#
# Drafts are ignored entirely (no row) unless they carry a "ready for review"
# label, which is treated as an explicit author opt-in and runs the same gates
# as an active PR. Actionable engagement is NEW, UPDATED, or REVISIT with CI green;
# every other PR is a terminal row (skipped/deferred) with its reason filled in.
# REVISIT is a PR at an already-reviewed head that the bot last told the author to
# fix (do-not-approve) and whose inline comments the author has since resolved or
# replied to without pushing a new commit: no fresh panel is warranted (the diff is
# unchanged), but it is worth re-judging whether the concerns are now addressed.
# Its "revisit" field carries the engagement fingerprint the reviewer must echo
# into the summary marker (revisit=<fp>) so the same state is not revisited twice.
# The caller dispatches one review agent per actionable entry, then replaces each
# PENDING_VERDICT row with the returned verdict.
#
# Flags mirror the skill: --exclude-own, --dependabot (include dependabot).
# Targets bash 3.2 (macOS system bash). Human-approved PRs are reviewed like any
# other (the engagement marker still skips one already reviewed at this head).
set -uo pipefail

EXCLUDE_OWN=0
INCLUDE_DEPENDABOT=0
for arg in "$@"; do
  case "$arg" in
    --exclude-own) EXCLUDE_OWN=1 ;;
    --dependabot) INCLUDE_DEPENDABOT=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) || { echo "failed to resolve repo" >&2; exit 1; }
me=$(gh api user -q .login) || { echo "failed to resolve login" >&2; exit 1; }

prs=$(gh pr list --state open --limit 100 \
  --json number,title,headRefOid,isDraft,mergeable,author,labels) \
  || { echo "failed to list PRs" >&2; exit 1; }

actionable_file=$(mktemp)
report_file=$(mktemp)
trap 'rm -f "$actionable_file" "$report_file"' EXIT

# Full body of the PR's most recent engagement-marker comment ("" if none).
# Matches both the current "bot-panel-review-loop" marker and the legacy
# "panel-review-prs" marker, so PRs reviewed before the rename are still
# recognized (not re-reviewed). The caller parses head= (SEEN/UPDATED), the
# verdict, and any revisit= fingerprint (REVISIT dedup) out of the returned body.
last_marker_body() {
  gh api "repos/$repo/issues/$1/comments" --paginate \
    -q '[.[] | select(.body | test("<!-- (bot-panel-review-loop|panel-review-prs): head=")) | .body] | (last // "")' 2>/dev/null
}

# Decide whether a PR at an already-reviewed head is worth a REVISIT rather than a
# plain SEEN skip. A revisit is warranted when the last review said do-not-approve,
# the bot opened at least one inline comment thread, every such thread is now
# resolved or has a non-bot reply (the author engaged without pushing a new
# commit), and that engagement state differs from the one the last revisit already
# evaluated (recorded as the marker's revisit= fingerprint). Prints the current
# fingerprint and returns 0 when a revisit is warranted; prints nothing and returns
# non-zero otherwise. Costs one GraphQL call, and only for a do-not-approve PR, so
# approved/clean PRs pay nothing.
revisit_fingerprint() { # num marker_body
  local num="$1" body="$2" lines fp prev_fp
  # Only a PR the bot last told the author to fix is a candidate.
  printf '%s' "$body" | grep -qiE 'verdict:.*do not approve' || return 1

  # One canonical "<resolved 0|1>:<non-bot-reply 0|1>" line per bot-opened thread.
  # env.BOT_LOGIN carries our login into the (gojq) filter; a bot thread is one
  # whose first comment is ours, and it is "handled" if resolved or if any later
  # comment is by someone other than us (the author responded).
  lines=$(BOT_LOGIN="$me" gh api graphql \
    -f owner="${repo%%/*}" -f repo="${repo##*/}" -F num="$num" -f query='
      query($owner:String!,$repo:String!,$num:Int!){
        repository(owner:$owner,name:$repo){ pullRequest(number:$num){
          reviewThreads(first:100){ nodes{
            isResolved
            comments(first:50){ nodes{ author{ login } } }
          } } } } }' \
    -q '
      .data.repository.pullRequest.reviewThreads.nodes[]
      | select(.comments.nodes[0].author.login == env.BOT_LOGIN)
      | "\(if .isResolved then 1 else 0 end):\(if ([.comments.nodes[1:][].author.login] - [env.BOT_LOGIN] | length) > 0 then 1 else 0 end)"' \
    2>/dev/null) || return 1

  # No inline thread the bot opened -> nothing was "resolved or replied to".
  [ -n "$lines" ] || return 1
  # Every bot thread must be handled (resolved, or a non-bot reply); a "0:0" line
  # is a still-open, unanswered bot thread, so bail.
  printf '%s\n' "$lines" | grep -qE '^0:0$' && return 1

  # Fingerprint the handled-state; stable tick-to-tick unless the author engages
  # further (resolves or replies to more), which should re-trigger a revisit.
  fp=$(printf '%s\n' "$lines" | LC_ALL=C sort | cksum | awk '{print $1"-"$2}')
  prev_fp=$(printf '%s' "$body" | grep -oE 'revisit=[0-9-]+' | sed 's/revisit=//' | tail -n1)
  # Already revisited this exact engagement state -> nothing new to judge.
  [ "$prev_fp" = "$fp" ] && return 1

  printf '%s' "$fp"
  return 0
}

emit_row() { # number title engagement result
  # Trailing placeholders: Effort/Risk, Panel, Human. The driver fills them for
  # PENDING_VERDICT rows; skip/defer rows keep the dashes.
  printf '| #%s | %s | %s | %s | - | - | - |\n' "$1" "$2" "$3" "$4" >> "$report_file"
}

push_actionable() { # number title head engagement ci note revisit
  jq -nc \
    --argjson number "$1" --arg title "$2" --arg head "$3" \
    --arg engagement "$4" --arg ci "$5" --arg note "$6" --arg revisit "$7" \
    '{number:$number, title:$title, head:$head, engagement:$engagement,
      ci:$ci, note:(if $note=="" then null else $note end),
      revisit:(if $revisit=="" then null else $revisit end)}' >> "$actionable_file"
}

# Pass 1: the gates expressible from the list payload alone. Emits one TSV row
# per PR: number, head, title, disposition. disposition is a terminal skip
# reason, "recheck" (mergeable==UNKNOWN, settle below), or "candidate".
while IFS=$'\t' read -r num head title disp draft; do
  [ -n "$num" ] || continue
  kind=${disp%%:*}
  reason=${disp#*:}

  if [ "$kind" = "skip" ]; then
    emit_row "$num" "$title" "-" "$reason"
    continue
  fi

  if [ "$kind" = "recheck" ]; then
    # gh often reports UNKNOWN for a few seconds after a push; settle it once.
    m=$(gh pr view "$num" -R "$repo" --json mergeable -q .mergeable 2>/dev/null)
    if [ "$m" = "CONFLICTING" ]; then
      emit_row "$num" "$title" "-" "skipped (merge conflict)"; continue
    elif [ "$m" != "MERGEABLE" ]; then
      emit_row "$num" "$title" "-" "deferred (mergeability unknown)"; continue
    fi
    # MERGEABLE now: fall through to candidate handling.
  fi

  # --- candidate: engagement classification ---
  # UPDATED gets the same full-PR re-review as NEW; the marker only tells us
  # whether there is anything new to look at since the last review at all. A PR at
  # a head already reviewed is normally SEEN (skip), but if the last verdict was
  # do-not-approve and the author has since resolved/replied to every bot comment
  # (without pushing), it becomes REVISIT: re-judge whether the concerns are now
  # addressed. revisit_fingerprint decides that and, when it does, returns the
  # engagement fingerprint that dedupes it (see the function).
  marker=$(last_marker_body "$num")
  prev=$(printf '%s' "$marker" | grep -oE 'head=[0-9a-f]+' | sed 's/head=//' | tail -n1)
  note=""
  revisit_fp=""
  if [ -z "$prev" ]; then
    engagement="NEW"
  elif [ "$prev" = "$head" ]; then
    if revisit_fp=$(revisit_fingerprint "$num" "$marker"); then
      engagement="REVISIT"; note="${note:+$note; }author resolved/replied to all comments; re-evaluating"
    else
      revisit_fp=""
      emit_row "$num" "$title" "SEEN" "skipped (reviewed at this head)"; continue
    fi
  else
    # Head moved since the last review. "identical" means the tree did not change
    # (e.g. a base merge) so there is nothing new to review; anything else (ahead,
    # diverged/rebased, or compare unavailable) is UPDATED and re-reviewed in full.
    status=$(gh api "repos/$repo/compare/$prev...$head" -q .status 2>/dev/null)
    if [ "$status" = "identical" ]; then
      if revisit_fp=$(revisit_fingerprint "$num" "$marker"); then
        engagement="REVISIT"; note="${note:+$note; }author resolved/replied to all comments; re-evaluating"
      else
        revisit_fp=""
        emit_row "$num" "$title" "SEEN" "skipped (no new commits)"; continue
      fi
    else
      engagement="UPDATED"
    fi
  fi

  # --- CI gate (gate 5) ---
  ci_out=$(gh pr checks "$num" -R "$repo" 2>&1); ci_rc=$?
  if [ "$ci_rc" -eq 0 ]; then
    ci="pass"
  elif printf '%s' "$ci_out" | grep -qiE "no checks? (reported|on)"; then
    ci="pass"; note="${note:+$note; }no CI checks reported"
  elif [ "$ci_rc" -eq 8 ]; then
    emit_row "$num" "$title" "$engagement" "deferred (CI pending)"; continue
  else
    emit_row "$num" "$title" "$engagement" "skipped (CI red)"; continue
  fi

  [ "$draft" = "draft" ] && note="${note:+$note; }ready-for-review draft"
  push_actionable "$num" "$title" "$head" "$engagement" "$ci" "$note" "$revisit_fp"
  emit_row "$num" "$title" "$engagement" "PENDING_VERDICT"
done < <(printf '%s' "$prs" | jq -r \
  --arg me "$me" \
  --argjson exclOwn "$EXCLUDE_OWN" \
  --argjson inclDep "$INCLUDE_DEPENDABOT" '
  .[]
  # Drafts are ignored entirely (no row) unless labeled "ready for review", an
  # explicit author opt-in; a labeled draft then runs the same gates as an
  # active PR. The trailing column carries the draft marker into the loop.
  | select( (.isDraft | not)
            or ([.labels[].name] | any(ascii_downcase == "ready for review")) )
  | [ (.number|tostring), .headRefOid, .title,
      ( if (((.author.login // "") | test("dependabot"))) and ($inclDep==0) then "skip:dependabot → skipped"
        elif (.author.login==$me) and ($exclOwn==1) then "skip:own PR → skipped"
        elif .mergeable=="CONFLICTING" then "skip:skipped (merge conflict)"
        elif .mergeable=="UNKNOWN" then "recheck:"
        else "candidate:" end ),
      ( if .isDraft then "draft" else "" end )
    ] | @tsv')

echo "===ACTIONABLE_JSON==="
if [ -s "$actionable_file" ]; then jq -s '.' "$actionable_file"; else echo "[]"; fi
echo "===REPORT_TABLE==="
echo "| PR | Title | Engagement | Result | Effort/Risk | Panel | Human |"
echo "| --- | --- | --- | --- | --- | --- | --- |"
cat "$report_file"
