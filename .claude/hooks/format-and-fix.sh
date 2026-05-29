#!/usr/bin/env bash
# PostToolUse hook: run oxlint --fix then oxfmt on the edited file.
# Receives Claude Code hook JSON on stdin.

set -uo pipefail

# No-op (rather than hard-fail) when a prerequisite is missing, e.g. jq isn't
# installed or the repo hasn't run `pnpm install` yet so the tools don't exist.
command -v jq >/dev/null 2>&1 || exit 0

file=$(jq -r '.tool_input.file_path // empty')
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

case "${file##*.}" in
  ts|tsx|js|jsx|mjs|cjs|mts|cts|css|scss|less|md|mdx|json|jsonc|json5) ;;
  *) exit 0 ;;
esac

bin="$CLAUDE_PROJECT_DIR/node_modules/.bin"
[ -x "$bin/oxlint" ] || exit 0
[ -x "$bin/oxfmt" ] || exit 0

# oxfmt runs even when oxlint exits non-zero so formatting always happens;
# lint errors propagate via the final exit code. --no-error-on-unmatched-pattern
# keeps the hook green for non-JS/TS files (md/json/css) that oxlint can't lint.
"$bin/oxlint" --fix --fix-suggestions --quiet --no-error-on-unmatched-pattern "$file"
lint=$?
"$bin/oxfmt" "$file"
fmt=$?

[ "$lint" -ne 0 ] && exit "$lint"
exit "$fmt"
