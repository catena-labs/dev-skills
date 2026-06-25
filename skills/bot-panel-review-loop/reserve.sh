#!/usr/bin/env bash
#
# reserve.sh — durable, atomic per-PR review reservations (a lease table) for
# bot-panel-review-loop. Replaces the driver's in-conversation in-flight map and
# the soft "cap of 3" with a SQLite-backed lease that survives context
# compaction, session restarts, and fresh-context cron sweeps.
#
# The driver (the sweep) owns every call here; the per-PR review sub-agent never
# touches reservations. `reserve` is the cap gate at dispatch, `release` frees
# the slot when the sub-agent returns (any outcome). The TTL is a crash backstop
# only — the happy path is an explicit `release`.
#
# State lives OUTSIDE the skill dir (the deployed skill copy can be re-synced):
#   $RESERVE_DB  default ${XDG_STATE_HOME:-$HOME/.local/state}/bot-panel-review-loop/reservations.db
# Leases are scoped by repo, so concurrent sweeps of different repos each get
# their own cap.
#
# Usage: reserve.sh [--repo owner/name] [--cap N] [--ttl SECS] <verb> [args]
#
#   reserve <num> <head>   Atomic GC + gate in one BEGIN IMMEDIATE txn: prints
#                          `held` if this PR already has a live lease, `full` if
#                          the repo is at the cap, else inserts and prints `ok`.
#                          Safe under concurrent callers; the cap is never
#                          exceeded.
#   release <num>          Drop this PR's lease (idempotent). Call on every
#                          sub-agent return (approve/do-not-approve/skip/defer).
#   renew <num>            Push this PR's lease expiry out by --ttl. `renewed`
#                          or `missing`.
#   list                   Active leases, TSV: `<num> <head> <age> <expires_in>`.
#   slots                  Free slots for this repo: cap - active.
#   gc                     Delete expired leases; print how many reclaimed.
#   sweep-lock <ttl>       Singleton cron lock: `ok` (acquired / prior expired)
#                          or `busy`. One sweep per repo.
#   sweep-renew <ttl>      Extend the sweep lock.
#   sweep-unlock           Release the sweep lock.
#
# Exit: 0 success, 1 real error (no sqlite3/gh, db failure), 2 usage error.

set -uo pipefail

RESERVE_DB="${RESERVE_DB:-${XDG_STATE_HOME:-$HOME/.local/state}/bot-panel-review-loop/reservations.db}"
CAP="${RESERVE_CAP:-3}"
TTL="${RESERVE_TTL:-1800}"
REPO=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --cap)  CAP="${2:-}";  shift 2 ;;
    --ttl)  TTL="${2:-}";  shift 2 ;;
    -h|--help) sed -n '2,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "reserve.sh: unknown flag: $1" >&2; exit 2 ;;
    *)  args+=("$1"); shift ;;
  esac
done

command -v sqlite3 >/dev/null 2>&1 || { echo "reserve.sh: need 'sqlite3' on PATH" >&2; exit 1; }

verb="${args[0]:-}"
[[ -n "$verb" ]] || { echo "reserve.sh: no verb (try --help)" >&2; exit 2; }

if [[ -z "$REPO" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "reserve.sh: need 'gh' on PATH or pass --repo" >&2; exit 1; }
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || true
fi
[[ -n "$REPO" ]] || { echo "reserve.sh: could not resolve repo (pass --repo owner/name)" >&2; exit 1; }

# Validate so values are safe to interpolate into SQL.
[[ "$REPO" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "reserve.sh: bad repo '$REPO'" >&2; exit 2; }
[[ "$CAP"  =~ ^[0-9]+$ ]]           || { echo "reserve.sh: --cap must be an integer" >&2; exit 2; }
[[ "$TTL"  =~ ^[0-9]+$ ]]           || { echo "reserve.sh: --ttl must be an integer" >&2; exit 2; }

mkdir -p "$(dirname "$RESERVE_DB")" 2>/dev/null || { echo "reserve.sh: cannot create state dir for $RESERVE_DB" >&2; exit 1; }
# .timeout (dot-command) sets the busy timeout WITHOUT printing a result row;
# `-cmd "PRAGMA busy_timeout=N"` would emit N to stdout and corrupt every verb.
db() { sqlite3 -batch -noheader -cmd ".timeout 5000" "$RESERVE_DB" "$@"; }
db "PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS leases(
  repo TEXT NOT NULL, pr INTEGER NOT NULL, head TEXT,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  PRIMARY KEY(repo, pr));
CREATE TABLE IF NOT EXISTS sweeplock(
  repo TEXT PRIMARY KEY, expires_at INTEGER NOT NULL);" >/dev/null \
  || { echo "reserve.sh: db init failed ($RESERVE_DB)" >&2; exit 1; }

need_pr() { pr="${args[1]:-}"; [[ "$pr" =~ ^[0-9]+$ ]] || { echo "reserve.sh: $verb needs <num>" >&2; exit 2; }; }

case "$verb" in
  reserve)
    need_pr
    head="${args[2]:-}"
    [[ "$head" =~ ^[0-9a-fA-F]{7,64}$ ]] || { echo "reserve.sh: reserve needs <num> <head>" >&2; exit 2; }
    out="$(db "BEGIN IMMEDIATE;
      DELETE FROM leases WHERE repo='$REPO' AND expires_at<=strftime('%s','now');
      INSERT INTO leases(repo,pr,head,created_at,expires_at)
        SELECT '$REPO',$pr,'$head',strftime('%s','now'),strftime('%s','now')+$TTL
        WHERE NOT EXISTS(SELECT 1 FROM leases WHERE repo='$REPO' AND pr=$pr)
          AND (SELECT count(*) FROM leases WHERE repo='$REPO') < $CAP;
      SELECT CASE
        WHEN changes()=1 THEN 'ok'
        WHEN EXISTS(SELECT 1 FROM leases WHERE repo='$REPO' AND pr=$pr) THEN 'held'
        ELSE 'full' END;
      COMMIT;")" || { echo "reserve.sh: reserve txn failed for #$pr" >&2; exit 1; }
    echo "$out"
    echo "reserve.sh: reserve #$pr -> $out (cap $CAP, ttl ${TTL}s)" >&2
    ;;
  release)
    need_pr
    db "DELETE FROM leases WHERE repo='$REPO' AND pr=$pr;" >/dev/null \
      || { echo "reserve.sh: release failed for #$pr" >&2; exit 1; }
    echo "released"; echo "reserve.sh: released #$pr" >&2
    ;;
  renew)
    need_pr
    out="$(db "UPDATE leases SET expires_at=strftime('%s','now')+$TTL WHERE repo='$REPO' AND pr=$pr;
      SELECT CASE WHEN changes()=1 THEN 'renewed' ELSE 'missing' END;")" || exit 1
    echo "$out"; echo "reserve.sh: renew #$pr -> $out" >&2
    ;;
  list)
    db -separator '	' "DELETE FROM leases WHERE repo='$REPO' AND expires_at<=strftime('%s','now');
      SELECT pr, head, strftime('%s','now')-created_at, expires_at-strftime('%s','now')
        FROM leases WHERE repo='$REPO' ORDER BY pr;"
    ;;
  slots)
    db "DELETE FROM leases WHERE repo='$REPO' AND expires_at<=strftime('%s','now');
      SELECT max(0, $CAP - (SELECT count(*) FROM leases WHERE repo='$REPO'));"
    ;;
  gc)
    n="$(db "DELETE FROM leases WHERE repo='$REPO' AND expires_at<=strftime('%s','now'); SELECT changes();")"
    echo "$n reclaimed"; echo "reserve.sh: gc $REPO -> $n reclaimed" >&2
    ;;
  sweep-lock)
    lttl="${args[1]:-$TTL}"; [[ "$lttl" =~ ^[0-9]+$ ]] || { echo "reserve.sh: sweep-lock ttl must be integer" >&2; exit 2; }
    out="$(db "BEGIN IMMEDIATE;
      DELETE FROM sweeplock WHERE repo='$REPO' AND expires_at<=strftime('%s','now');
      INSERT INTO sweeplock(repo,expires_at)
        SELECT '$REPO', strftime('%s','now')+$lttl
        WHERE NOT EXISTS(SELECT 1 FROM sweeplock WHERE repo='$REPO');
      SELECT CASE WHEN changes()=1 THEN 'ok' ELSE 'busy' END;
      COMMIT;")" || exit 1
    echo "$out"; echo "reserve.sh: sweep-lock -> $out" >&2
    ;;
  sweep-renew)
    lttl="${args[1]:-$TTL}"; [[ "$lttl" =~ ^[0-9]+$ ]] || { echo "reserve.sh: sweep-renew ttl must be integer" >&2; exit 2; }
    db "UPDATE sweeplock SET expires_at=strftime('%s','now')+$lttl WHERE repo='$REPO';" >/dev/null || exit 1
    echo "renewed"
    ;;
  sweep-unlock)
    db "DELETE FROM sweeplock WHERE repo='$REPO';" >/dev/null || exit 1
    echo "unlocked"; echo "reserve.sh: sweep-unlock" >&2
    ;;
  *) echo "reserve.sh: unknown verb: $verb (try --help)" >&2; exit 2 ;;
esac
