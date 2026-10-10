#!/bin/zsh
# Checks the Swift code of the repository without changing any file (TK-023).
#   Tools/Lint/lint.sh
# Exit 0: nothing to report. Exit 1: a check failed; every check still runs, so one run shows all.
# SwiftLint warnings (force_try, force_cast) are printed and counted but do not fail the check.
set -u
source "${0:A:h}/common.sh"
cd "$ROOT"
prepare

failed=0
echo "== SwiftFormat $("$LINT/.tools/swiftformat" --version): formatting"
"$LINT/.tools/swiftformat" --lint . 2>&1 | grep -vE "^(Running SwiftFormat|SwiftFormat completed|\(lint mode)" || true
"$LINT/.tools/swiftformat" --lint . >/dev/null 2>&1 || failed=1

echo "== SwiftLint $("$LINT/.tools/swiftlint" --version)"
"$LINT/.tools/swiftlint" lint --quiet --config .swiftlint.yml || failed=1
warnings=$("$LINT/.tools/swiftlint" lint --quiet --config .swiftlint.yml 2>/dev/null | grep -c ": warning:" || true)
echo "SwiftLint warnings (not failing): $warnings"

echo "== spacing-check: blank lines before return / after multi-line if"
"$SPACING" "${SOURCES[@]}" "${SPACING_EXCLUDES[@]}" || failed=1

if (( failed == 0 )); then echo "lint: ok"; else echo "lint: FAILED (Tools/Lint/format.sh fixes what is fixable)"; fi
exit $failed
