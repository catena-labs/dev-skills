#!/usr/bin/env bash
#
# metrics.sh — SQLite effectiveness ledger for bot-panel-review-loop panelists.
#
# State lives OUTSIDE the skill dir (the deployed skill copy can be re-synced):
#   $METRICS_DB  default ${XDG_STATE_HOME:-$HOME/.local/state}/bot-panel-review-loop/metrics.db
#
# The per-PR judging agent records one row per synthesized finding, with the
# panelist(s) that raised it. Later workflow steps update verification,
# publication, and owner outcome. This makes reviewer effectiveness measurable
# without asking the panel runner to emit machine-readable findings.
#
# Usage: metrics.sh [--repo owner/name] [--db PATH] <verb> [args]
#
#   run-start <pr> <head> <engagement>
#       Create or reuse the metrics run for this PR head. Prints <run_id>.
#
#   run-finish <run_id> <verdict> <posted_count> <offdiff_count> <human_surfaces> <panel_line>
#       Mark the run complete with the final advisory verdict and panel line.
#
#   panelist <run_id> <reviewer_id> <model> <approach> <contributed|failed|missing> [exit_code]
#       Record which panelist actually ran. Record failed/missing panelists too
#       so availability and failure rate are visible.
#
#   finding <run_id> <severity> <path> <line> <issue> <fix> <sources_csv> [surface]
#       Record a distinct synthesized candidate finding and the panelist ids
#       that raised it. Prints "<finding_id> <fingerprint>". The fingerprint is
#       stable for path+issue within the run and is used only as a dedupe key.
#
#   missed <run_id> <severity> <path> <line> <issue> <fix> <discovered_by> [surface] [evidence]
#       Record a verified FIX finding discovered after the panel review that no
#       panelist raised. This counts as a missed opportunity for every
#       contributed panelist in that run.
#
#   verify <finding_id> <verified|false_positive|unverified> [notes]
#       Record whether the judging agent verified the finding.
#
#   judge <finding_id> <fix|forego|duplicate> [reason]
#       Record the bot's final disposition before publication.
#
#   publish <finding_id> <posted|covered|offdiff|summary|not_posted> [evidence]
#       Record whether the finding was posted inline, already covered by an
#       existing thread, folded into the summary, or not posted.
#
#   owner <finding_id> <fixed|acknowledged|rejected|superseded|unknown> [evidence]
#       Record the PR owner's eventual outcome. This is usually filled by a
#       post-merge owner-outcome sweep.
#
#   pending-owner
#       TSV of verified/fix findings whose owner outcome is still unknown.
#
#   runs [pr]
#       TSV of metrics runs for this repo, optionally limited to one PR.
#
#   run-findings <run_id>
#       TSV ledger for one run.
#
#   reviewer-stats
#       TSV effectiveness table per reviewer id.
#
# Exit: 0 success, 1 real error (no sqlite3/gh, db failure), 2 usage error.

set -uo pipefail

METRICS_DB="${METRICS_DB:-${XDG_STATE_HOME:-$HOME/.local/state}/bot-panel-review-loop/metrics.db}"
REPO=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 && "${2:-}" != -* ]] || { echo "metrics.sh: --repo needs owner/name" >&2; exit 2; }
      REPO="$2"; shift 2 ;;
    --db)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "metrics.sh: --db needs a path" >&2; exit 2; }
      METRICS_DB="$2"; shift 2 ;;
    -h|--help) sed -n '2,61p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "metrics.sh: unknown flag: $1" >&2; exit 2 ;;
    *)  args+=("$1"); shift ;;
  esac
done

command -v sqlite3 >/dev/null 2>&1 || { echo "metrics.sh: need 'sqlite3' on PATH" >&2; exit 1; }

verb="${args[0]:-}"
[[ -n "$verb" ]] || { echo "metrics.sh: no verb (try --help)" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "metrics.sh: need 'gh' on PATH or pass --repo" >&2; exit 1; }
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || true
fi
[[ -n "$REPO" ]] || { echo "metrics.sh: could not resolve repo (pass --repo owner/name)" >&2; exit 1; }

[[ "$REPO" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "metrics.sh: bad repo '$REPO'" >&2; exit 2; }

mkdir -p "$(dirname "$METRICS_DB")" 2>/dev/null || { echo "metrics.sh: cannot create state dir for $METRICS_DB" >&2; exit 1; }
db() { sqlite3 -batch -noheader -cmd ".timeout 5000" "$METRICS_DB" "$@"; }

db "PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS review_runs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,
  pr INTEGER NOT NULL,
  head TEXT NOT NULL,
  engagement TEXT,
  started_at INTEGER NOT NULL,
  completed_at INTEGER,
  verdict TEXT,
  posted_count INTEGER DEFAULT 0,
  offdiff_count INTEGER DEFAULT 0,
  human_surfaces TEXT,
  panel_line TEXT,
  UNIQUE(repo, pr, head));
CREATE TABLE IF NOT EXISTS panelists(
  run_id INTEGER NOT NULL,
  reviewer_id TEXT NOT NULL,
  model TEXT,
  approach TEXT,
  status TEXT NOT NULL,
  exit_code INTEGER,
  recorded_at INTEGER NOT NULL,
  PRIMARY KEY(run_id, reviewer_id));
CREATE TABLE IF NOT EXISTS findings(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL,
  fingerprint TEXT NOT NULL,
  severity TEXT NOT NULL,
  path TEXT NOT NULL,
  line TEXT,
  issue TEXT NOT NULL,
  fix TEXT,
  surface TEXT,
  verification TEXT NOT NULL DEFAULT 'unverified',
  verification_notes TEXT,
  verified_at INTEGER,
  judgment TEXT NOT NULL DEFAULT 'candidate',
  judgment_reason TEXT,
  publication TEXT NOT NULL DEFAULT 'not_posted',
  publication_evidence TEXT,
  owner_outcome TEXT NOT NULL DEFAULT 'unknown',
  owner_evidence TEXT,
  owner_checked_at INTEGER,
  origin TEXT NOT NULL DEFAULT 'panel',
  missed INTEGER NOT NULL DEFAULT 0,
  discovered_by TEXT,
  discovery_evidence TEXT,
  created_at INTEGER NOT NULL,
  UNIQUE(run_id, fingerprint));
CREATE TABLE IF NOT EXISTS finding_sources(
  finding_id INTEGER NOT NULL,
  reviewer_id TEXT NOT NULL,
  PRIMARY KEY(finding_id, reviewer_id));
CREATE INDEX IF NOT EXISTS idx_review_runs_repo_pr ON review_runs(repo, pr);
CREATE INDEX IF NOT EXISTS idx_findings_run ON findings(run_id);
CREATE INDEX IF NOT EXISTS idx_findings_owner ON findings(owner_outcome, verification, judgment);" >/dev/null \
  || { echo "metrics.sh: db init failed ($METRICS_DB)" >&2; exit 1; }
# Existing local DBs created before missed-finding tracking need these columns.
# Ignore duplicate-column errors on fresh DBs.
db "ALTER TABLE findings ADD COLUMN origin TEXT NOT NULL DEFAULT 'panel';" >/dev/null 2>&1 || true
db "ALTER TABLE findings ADD COLUMN missed INTEGER NOT NULL DEFAULT 0;" >/dev/null 2>&1 || true
db "ALTER TABLE findings ADD COLUMN discovered_by TEXT;" >/dev/null 2>&1 || true
db "ALTER TABLE findings ADD COLUMN discovery_evidence TEXT;" >/dev/null 2>&1 || true

sqlq() {
  local s="${1-}"
  s=${s//\'/\'\'}
  printf "'%s'" "$s"
}

need_int() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "metrics.sh: $verb needs integer <$name>" >&2; exit 2; }
}

need_run() {
  run_id="${args[1]:-}"
  need_int "run_id" "$run_id"
}

need_finding() {
  finding_id="${args[1]:-}"
  need_int "finding_id" "$finding_id"
}

validate_status() {
  local name="$1" value="$2" allowed="$3"
  case " $allowed " in
    *" $value "*) ;;
    *) echo "metrics.sh: $name must be one of: $allowed" >&2; exit 2 ;;
  esac
}

fingerprint_for() {
  local path="$1" issue="$2"
  if command -v shasum >/dev/null 2>&1; then
    printf '%s\t%s\n' "$path" "$issue" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s\t%s\n' "$path" "$issue" | openssl dgst -sha256 | awk '{print $NF}'
  else
    printf '%s\t%s\n' "$path" "$issue" | cksum | awk '{print $1 "-" $2}'
  fi
}

case "$verb" in
  run-start)
    pr="${args[1]:-}"; head="${args[2]:-}"; engagement="${args[3]:-}"
    need_int "pr" "$pr"
    [[ "$head" =~ ^[0-9a-fA-F]{7,64}$ ]] || { echo "metrics.sh: run-start needs <head>" >&2; exit 2; }
    [[ "$engagement" =~ ^[A-Z][A-Z_-]*$ ]] || { echo "metrics.sh: run-start needs <engagement>" >&2; exit 2; }
    out="$(db "BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO review_runs(repo,pr,head,engagement,started_at)
        VALUES($(sqlq "$REPO"),$pr,$(sqlq "$head"),$(sqlq "$engagement"),strftime('%s','now'));
      UPDATE review_runs SET engagement=$(sqlq "$engagement")
        WHERE repo=$(sqlq "$REPO") AND pr=$pr AND head=$(sqlq "$head");
      SELECT id FROM review_runs WHERE repo=$(sqlq "$REPO") AND pr=$pr AND head=$(sqlq "$head");
      COMMIT;")" || { echo "metrics.sh: run-start failed for #$pr" >&2; exit 1; }
    echo "$out"
    ;;

  run-finish)
    need_run
    verdict="${args[2]:-}"; posted="${args[3]:-}"; offdiff="${args[4]:-}"
    human="${args[5]:-}"; panel="${args[6]:-}"
    [[ -n "$verdict" ]] || { echo "metrics.sh: run-finish needs <verdict>" >&2; exit 2; }
    need_int "posted_count" "$posted"; need_int "offdiff_count" "$offdiff"
    db "UPDATE review_runs SET completed_at=strftime('%s','now'),
        verdict=$(sqlq "$verdict"),
        posted_count=$posted,
        offdiff_count=$offdiff,
        human_surfaces=$(sqlq "$human"),
        panel_line=$(sqlq "$panel")
      WHERE id=$run_id AND repo=$(sqlq "$REPO");" >/dev/null \
      || { echo "metrics.sh: run-finish failed for run $run_id" >&2; exit 1; }
    echo "finished"
    ;;

  panelist)
    need_run
    reviewer="${args[2]:-}"; model="${args[3]:-}"; approach="${args[4]:-}"; status="${args[5]:-}"; exit_code="${args[6]:-}"
    [[ "$reviewer" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "metrics.sh: bad reviewer id '$reviewer'" >&2; exit 2; }
    validate_status "status" "$status" "contributed failed missing"
    if [[ -n "$exit_code" ]]; then need_int "exit_code" "$exit_code"; else exit_code="NULL"; fi
    db "INSERT OR REPLACE INTO panelists(run_id,reviewer_id,model,approach,status,exit_code,recorded_at)
      VALUES($run_id,$(sqlq "$reviewer"),$(sqlq "$model"),$(sqlq "$approach"),$(sqlq "$status"),$exit_code,strftime('%s','now'));" >/dev/null \
      || { echo "metrics.sh: panelist record failed for $reviewer" >&2; exit 1; }
    echo "recorded"
    ;;

  finding)
    need_run
    severity="${args[2]:-}"; path="${args[3]:-}"; line="${args[4]:-}"
    issue="${args[5]:-}"; fix="${args[6]:-}"; sources_csv="${args[7]:-}"; surface="${args[8]:-}"
    validate_status "severity" "$severity" "CRITICAL HIGH MEDIUM LOW UNKNOWN"
    [[ -n "$path" && -n "$issue" && -n "$sources_csv" ]] || {
      echo "metrics.sh: finding needs <severity> <path> <line> <issue> <fix> <sources_csv> [surface]" >&2; exit 2;
    }
    fp="$(fingerprint_for "$path" "$issue")"
    out="$(db "BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO findings(run_id,fingerprint,severity,path,line,issue,fix,surface,origin,missed,created_at)
        VALUES($run_id,$(sqlq "$fp"),$(sqlq "$severity"),$(sqlq "$path"),$(sqlq "$line"),$(sqlq "$issue"),$(sqlq "$fix"),$(sqlq "$surface"),'panel',0,strftime('%s','now'));
      UPDATE findings SET severity=$(sqlq "$severity"), path=$(sqlq "$path"), line=$(sqlq "$line"),
          issue=$(sqlq "$issue"), fix=$(sqlq "$fix"), surface=$(sqlq "$surface")
        WHERE run_id=$run_id AND fingerprint=$(sqlq "$fp");
      SELECT id FROM findings WHERE run_id=$run_id AND fingerprint=$(sqlq "$fp");
      COMMIT;")" || { echo "metrics.sh: finding record failed" >&2; exit 1; }
    finding_id="$out"
    IFS=',' read -r -a sources <<< "$sources_csv"
    for source in "${sources[@]}"; do
      [[ "$source" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "metrics.sh: bad source reviewer id '$source'" >&2; exit 2; }
      db "INSERT OR IGNORE INTO finding_sources(finding_id,reviewer_id)
        VALUES($finding_id,$(sqlq "$source"));" >/dev/null \
        || { echo "metrics.sh: source record failed for finding $finding_id" >&2; exit 1; }
    done
    echo "$finding_id $fp"
    ;;

  missed)
    need_run
    severity="${args[2]:-}"; path="${args[3]:-}"; line="${args[4]:-}"
    issue="${args[5]:-}"; fix="${args[6]:-}"; discovered_by="${args[7]:-}"
    surface="${args[8]:-}"; evidence="${args[9]:-}"
    validate_status "severity" "$severity" "CRITICAL HIGH MEDIUM LOW UNKNOWN"
    [[ -n "$path" && -n "$issue" && -n "$discovered_by" ]] || {
      echo "metrics.sh: missed needs <severity> <path> <line> <issue> <fix> <discovered_by> [surface] [evidence]" >&2; exit 2;
    }
    validate_status "discovered_by" "$discovered_by" "owner human ci post_merge later_review other"
    fp="$(fingerprint_for "$path" "MISSED:$issue")"
    out="$(db "BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO findings(run_id,fingerprint,severity,path,line,issue,fix,surface,
          verification,verified_at,judgment,judgment_reason,origin,missed,discovered_by,discovery_evidence,created_at)
        VALUES($run_id,$(sqlq "$fp"),$(sqlq "$severity"),$(sqlq "$path"),$(sqlq "$line"),$(sqlq "$issue"),$(sqlq "$fix"),$(sqlq "$surface"),
          'verified',strftime('%s','now'),'fix','missed by panel',$(sqlq "$discovered_by"),1,$(sqlq "$discovered_by"),$(sqlq "$evidence"),strftime('%s','now'));
      UPDATE findings SET severity=$(sqlq "$severity"), path=$(sqlq "$path"), line=$(sqlq "$line"),
          issue=$(sqlq "$issue"), fix=$(sqlq "$fix"), surface=$(sqlq "$surface"),
          verification='verified', verified_at=strftime('%s','now'), judgment='fix',
          judgment_reason='missed by panel', origin=$(sqlq "$discovered_by"), missed=1,
          discovered_by=$(sqlq "$discovered_by"), discovery_evidence=$(sqlq "$evidence")
        WHERE run_id=$run_id AND fingerprint=$(sqlq "$fp");
      SELECT id FROM findings WHERE run_id=$run_id AND fingerprint=$(sqlq "$fp");
      COMMIT;")" || { echo "metrics.sh: missed record failed" >&2; exit 1; }
    echo "$out $fp"
    ;;

  verify)
    need_finding
    status="${args[2]:-}"; notes="${args[3]:-}"
    validate_status "verification" "$status" "verified false_positive unverified"
    db "UPDATE findings SET verification=$(sqlq "$status"),
        verification_notes=$(sqlq "$notes"),
        verified_at=strftime('%s','now')
      WHERE id=$finding_id AND run_id IN (SELECT id FROM review_runs WHERE repo=$(sqlq "$REPO"));" >/dev/null \
      || { echo "metrics.sh: verify failed for finding $finding_id" >&2; exit 1; }
    echo "verified"
    ;;

  judge)
    need_finding
    judgment="${args[2]:-}"; reason="${args[3]:-}"
    validate_status "judgment" "$judgment" "fix forego duplicate"
    db "UPDATE findings SET judgment=$(sqlq "$judgment"), judgment_reason=$(sqlq "$reason")
      WHERE id=$finding_id AND run_id IN (SELECT id FROM review_runs WHERE repo=$(sqlq "$REPO"));" >/dev/null \
      || { echo "metrics.sh: judge failed for finding $finding_id" >&2; exit 1; }
    echo "judged"
    ;;

  publish)
    need_finding
    publication="${args[2]:-}"; evidence="${args[3]:-}"
    validate_status "publication" "$publication" "posted covered offdiff summary not_posted"
    db "UPDATE findings SET publication=$(sqlq "$publication"), publication_evidence=$(sqlq "$evidence")
      WHERE id=$finding_id AND run_id IN (SELECT id FROM review_runs WHERE repo=$(sqlq "$REPO"));" >/dev/null \
      || { echo "metrics.sh: publish failed for finding $finding_id" >&2; exit 1; }
    echo "published"
    ;;

  owner)
    need_finding
    outcome="${args[2]:-}"; evidence="${args[3]:-}"
    validate_status "owner_outcome" "$outcome" "fixed acknowledged rejected superseded unknown"
    db "UPDATE findings SET owner_outcome=$(sqlq "$outcome"),
        owner_evidence=$(sqlq "$evidence"),
        owner_checked_at=strftime('%s','now')
      WHERE id=$finding_id AND run_id IN (SELECT id FROM review_runs WHERE repo=$(sqlq "$REPO"));" >/dev/null \
      || { echo "metrics.sh: owner update failed for finding $finding_id" >&2; exit 1; }
    echo "owner-recorded"
    ;;

  pending-owner)
    printf 'run_id\tpr\thead\tfinding_id\tseverity\tlocation\tissue\torigin\tpublication\n'
    db -separator '	' "SELECT r.id, r.pr, r.head, f.id, f.severity,
        f.path || CASE WHEN coalesce(f.line,'')='' THEN '' ELSE ':' || f.line END,
        f.issue, f.origin, f.publication
      FROM findings f JOIN review_runs r ON r.id=f.run_id
      WHERE r.repo=$(sqlq "$REPO")
        AND f.verification='verified'
        AND f.judgment='fix'
        AND f.owner_outcome='unknown'
      ORDER BY r.pr, f.id;"
    ;;

  runs)
    pr_filter="${args[1]:-}"
    if [[ -n "$pr_filter" ]]; then need_int "pr" "$pr_filter"; fi
    printf 'run_id\tpr\thead\tengagement\tstarted_at\tcompleted_at\tverdict\thuman_surfaces\tpanel_line\n'
    where="r.repo=$(sqlq "$REPO")"
    [[ -n "$pr_filter" ]] && where="$where AND r.pr=$pr_filter"
    db -separator '	' "SELECT r.id, r.pr, r.head, r.engagement,
        datetime(r.started_at,'unixepoch'),
        CASE WHEN r.completed_at IS NULL THEN '' ELSE datetime(r.completed_at,'unixepoch') END,
        coalesce(r.verdict,''), coalesce(r.human_surfaces,''), coalesce(r.panel_line,'')
      FROM review_runs r
      WHERE $where
      ORDER BY r.pr, r.started_at;"
    ;;

  run-findings)
    need_run
    printf 'finding_id\tseverity\tlocation\tissue\tsources\torigin\tmissed\tverification\tjudgment\tpublication\towner_outcome\n'
    db -separator '	' "SELECT f.id, f.severity,
        f.path || CASE WHEN coalesce(f.line,'')='' THEN '' ELSE ':' || f.line END,
        f.issue,
        coalesce((SELECT group_concat(reviewer_id, ',') FROM finding_sources WHERE finding_id=f.id), ''),
        f.origin, f.missed, f.verification, f.judgment, f.publication, f.owner_outcome
      FROM findings f
      WHERE f.run_id=$run_id
        AND f.run_id IN (SELECT id FROM review_runs WHERE repo=$(sqlq "$REPO"))
      ORDER BY f.id;"
    ;;

  reviewer-stats)
    printf 'reviewer\truns\tfailed\tfound\tverified\tfalse_positive\tmissed\tfix_recommended\tpublished_or_covered\towner_fixed_or_ack\tprecision\trecall\tacceptance\n'
    db -separator '	' "WITH
      reviewers AS (
        SELECT DISTINCT p.reviewer_id FROM panelists p
          JOIN review_runs r ON r.id=p.run_id WHERE r.repo=$(sqlq "$REPO")
        UNION
        SELECT DISTINCT fs.reviewer_id FROM finding_sources fs
          JOIN findings f ON f.id=fs.finding_id
          JOIN review_runs r ON r.id=f.run_id WHERE r.repo=$(sqlq "$REPO")
      ),
      panel AS (
        SELECT p.reviewer_id,
          count(*) AS runs,
          sum(CASE WHEN p.status!='contributed' THEN 1 ELSE 0 END) AS failed
        FROM panelists p JOIN review_runs r ON r.id=p.run_id
        WHERE r.repo=$(sqlq "$REPO")
        GROUP BY p.reviewer_id
      ),
      found AS (
        SELECT fs.reviewer_id,
          count(*) AS found,
          sum(CASE WHEN f.verification='verified' THEN 1 ELSE 0 END) AS verified,
          sum(CASE WHEN f.verification='false_positive' THEN 1 ELSE 0 END) AS false_positive,
          sum(CASE WHEN f.verification='verified' AND f.judgment='fix' THEN 1 ELSE 0 END) AS fix_recommended,
          sum(CASE WHEN f.verification='verified' AND f.judgment='fix' AND f.publication IN ('posted','covered','offdiff','summary') THEN 1 ELSE 0 END) AS published_or_covered,
          sum(CASE WHEN f.verification='verified' AND f.judgment='fix' AND f.owner_outcome IN ('fixed','acknowledged') THEN 1 ELSE 0 END) AS owner_fixed_or_ack
        FROM finding_sources fs
          JOIN findings f ON f.id=fs.finding_id
          JOIN review_runs r ON r.id=f.run_id
        WHERE r.repo=$(sqlq "$REPO")
        GROUP BY fs.reviewer_id
      ),
      missed AS (
        SELECT p.reviewer_id,
          count(*) AS missed
        FROM panelists p
          JOIN review_runs r ON r.id=p.run_id
          JOIN findings f ON f.run_id=p.run_id
        WHERE r.repo=$(sqlq "$REPO")
          AND p.status='contributed'
          AND f.verification='verified'
          AND f.judgment='fix'
          AND NOT EXISTS (
            SELECT 1 FROM finding_sources fs
            WHERE fs.finding_id=f.id AND fs.reviewer_id=p.reviewer_id
          )
        GROUP BY p.reviewer_id
      )
      SELECT reviewers.reviewer_id,
        coalesce(panel.runs,0),
        coalesce(panel.failed,0),
        coalesce(found.found,0),
        coalesce(found.verified,0),
        coalesce(found.false_positive,0),
        coalesce(missed.missed,0),
        coalesce(found.fix_recommended,0),
        coalesce(found.published_or_covered,0),
        coalesce(found.owner_fixed_or_ack,0),
        CASE WHEN coalesce(found.found,0)=0 THEN ''
             ELSE printf('%.2f', 1.0*found.verified/found.found) END,
        CASE WHEN coalesce(found.fix_recommended,0)+coalesce(missed.missed,0)=0 THEN ''
             ELSE printf('%.2f', 1.0*coalesce(found.fix_recommended,0)/(coalesce(found.fix_recommended,0)+coalesce(missed.missed,0))) END,
        CASE WHEN coalesce(found.fix_recommended,0)=0 THEN ''
             ELSE printf('%.2f', 1.0*found.owner_fixed_or_ack/found.fix_recommended) END
      FROM reviewers
        LEFT JOIN panel ON panel.reviewer_id=reviewers.reviewer_id
        LEFT JOIN found ON found.reviewer_id=reviewers.reviewer_id
        LEFT JOIN missed ON missed.reviewer_id=reviewers.reviewer_id
      ORDER BY reviewers.reviewer_id;"
    ;;

  *) echo "metrics.sh: unknown verb: $verb (try --help)" >&2; exit 2 ;;
esac
