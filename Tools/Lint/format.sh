#!/bin/zsh
# Rewrites the Swift code of the repository to the agreed style (TK-023). Explicit, never run by a
# build. Commit its result apart from any functional change.
#   Tools/Lint/format.sh
set -eu
source "${0:A:h}/common.sh"
cd "$ROOT"
prepare

"$LINT/.tools/swiftformat" .
"$SPACING" --fix "${SOURCES[@]}" "${SPACING_EXCLUDES[@]}"
echo "format: done; run Tools/Lint/lint.sh to confirm"
