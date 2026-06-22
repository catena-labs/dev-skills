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
#   [ {"number","title","head","engagement","ci","note",
#      "additions","deletions","changedFiles","size"}, ... ]
#   ===REPORT_TABLE===
#   | PR | Title | Engagement | Result | Panel | Human |
#   | ... one row per open PR (unlabeled drafts dropped); actionable rows carry PENDING_VERDICT ... |
#
# Drafts are ignored entirely (no row) unless they carry a "ready for review"
# label, which is treated as an explicit author opt-in and runs the same gates
# as an active PR. Actionable engagement is NEW or UPDATED with CI green; every
# other PR is a terminal row (skipped/deferred) with its reason filled in. The caller
# dispatches one review agent per actionable entry, then replaces each
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
  --json number,title,headRefOid,isDraft,mergeable,author,labels,additions,deletions,changedFiles) \
  || { echo "failed to list PRs" >&2; exit 1; }

actionable_file=$(mktemp)
report_file=$(mktemp)
trap 'rm -f "$actionable_file" "$report_file"' EXIT

# Pull the most recent engagement marker head for a PR ("" if none). Matches both
# the current "bot-panel-review-loop" marker and the legacy "panel-review-prs"
# marker, so PRs reviewed before the rename are still recognized (not re-reviewed).
last_marker() {
  gh api "repos/$repo/issues/$1/comments" --paginate \
    -q '[.[] | select(.body | test("<!-- (bot-panel-review-loop|panel-review-prs): head=")) | .body] | last' 2>/dev/null \
    | grep -oE 'head=[0-9a-f]+' | sed 's/head=//' | tail -n1
}

emit_row() { # number title engagement result
  printf '| #%s | %s | %s | %s | - | - |\n' "$1" "$2" "$3" "$4" >> "$report_file"
}

# Size thresholds for the Step 4 escalation tier. A PR is "large" when it crosses
# either bound; large PRs get a deeper review (Tier 2: decompose into per-area
# scoped reviews plus per-HIGH verification) per the SKILL.md Step 4 escalation
# policy. Tunable.
LARGE_CHANGED_FILES=20
LARGE_ADDITIONS=1000

push_actionable() { # number title head engagement ci note adds dels files
  local adds=${7:-0} dels=${8:-0} files=${9:-0} size="small"
  if [ "$files" -ge "$LARGE_CHANGED_FILES" ] || [ "$adds" -ge "$LARGE_ADDITIONS" ]; then
    size="large"
  fi
  jq -nc \
    --argjson number "$1" --arg title "$2" --arg head "$3" \
    --arg engagement "$4" --arg ci "$5" --arg note "$6" \
    --argjson adds "$adds" --argjson dels "$dels" --argjson files "$files" \
    --arg size "$size" \
    '{number:$number, title:$title, head:$head, engagement:$engagement,
      ci:$ci, note:(if $note=="" then null else $note end),
      additions:$adds, deletions:$dels, changedFiles:$files, size:$size}' >> "$actionable_file"
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
  # whether there is anything new to look at since the last review at all.
  prev=$(last_marker "$num")
  note=""
  if [ -z "$prev" ]; then
    engagement="NEW"
  elif [ "$prev" = "$head" ]; then
    emit_row "$num" "$title" "SEEN" "skipped (reviewed at this head)"; continue
  else
    # Head moved since the last review. "identical" means the tree did not change
    # (e.g. a base merge) so there is nothing new to review; anything else (ahead,
    # diverged/rebased, or compare unavailable) is UPDATED and re-reviewed in full.
    status=$(gh api "repos/$repo/compare/$prev...$head" -q .status 2>/dev/null)
    if [ "$status" = "identical" ]; then
      emit_row "$num" "$title" "SEEN" "skipped (no new commits)"; continue
    fi
    engagement="UPDATED"
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
  # Pull this candidate's diff size from the list payload (no extra API call) so
  # Step 4 can pick an escalation tier. Candidates are few, so the per-PR jq is cheap.
  read -r adds dels files < <(printf '%s' "$prs" | jq -r --argjson n "$num" \
    '.[] | select(.number==$n) | "\(.additions) \(.deletions) \(.changedFiles)"')
  push_actionable "$num" "$title" "$head" "$engagement" "$ci" "$note" \
    "${adds:-0}" "${dels:-0}" "${files:-0}"
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
echo "| PR | Title | Engagement | Result | Panel | Human |"
echo "| --- | --- | --- | --- | --- | --- |"
cat "$report_file"
