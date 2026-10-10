#!/bin/zsh
# Checks the tools against each other on small fixtures (TK-023 acceptance):
#   - good.swift is accepted by SwiftFormat, SwiftLint and spacing-check, and no formatter changes it;
#   - bad.swift is rejected by each of them for the reason it should be;
#   - formatting bad.swift gives code that all of them accept, and formatting again changes nothing.
#   Tools/Lint/selftest.sh
set -u
source "${0:A:h}/common.sh"
prepare
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$LINT/Fixtures/good.swift" "$LINT/Fixtures/bad.swift" "$work/"
# The repository config without its path filters, which are for the repository.
grep -vE '^(included|excluded):|^  - ("\*\*|Apps|Packages)' "$ROOT/.swiftlint.yml" > "$work/swiftlint.yml"
failures=0
check() {  # description, expected exit (0 or nonzero), command...
  local description=$1 expect=$2; shift 2
  "$@" > "$work/out.txt" 2>&1
  local code=$?
  if { [[ $expect == 0 ]] && (( code == 0 )); } || { [[ $expect != 0 ]] && (( code != 0 )); }; then
    echo "ok    $description"
  else
    echo "FAIL  $description (exit $code)"; sed 's/^/        /' "$work/out.txt"; failures=$((failures + 1))
  fi
}
expect_output() {  # description, pattern  (looks at the last output)
  if grep -qE "$2" "$work/out.txt"; then echo "ok    $1"; else echo "FAIL  $1: no match for $2"; sed 's/^/        /' "$work/out.txt"; failures=$((failures + 1)); fi
}
format_lint=("$LINT/.tools/swiftformat" --config "$ROOT/.swiftformat" --lint)
swiftlint_run=("$LINT/.tools/swiftlint" lint --quiet --config "$work/swiftlint.yml")

check "good.swift: SwiftFormat accepts" 0 "${format_lint[@]}" "$work/good.swift"
check "good.swift: SwiftLint accepts" 0 "${swiftlint_run[@]}" "$work/good.swift"
check "good.swift: spacing-check accepts" 0 "$SPACING" "$work/good.swift"

check "bad.swift: SwiftFormat rejects" 1 "${format_lint[@]}" "$work/bad.swift"
expect_output "bad.swift: SwiftFormat names the guard rule" "blankLinesAfterGuardStatements"
expect_output "bad.swift: SwiftFormat names the parameter layout" "wrapArguments"
check "bad.swift: SwiftLint rejects mixed parameters" 1 "${swiftlint_run[@]}" "$work/bad.swift"
expect_output "bad.swift: SwiftLint names the rule" "multiline_parameters"
check "bad.swift: spacing-check rejects" 1 "$SPACING" "$work/bad.swift"
expect_output "bad.swift: a return after a comment group is named with its line" "bad.swift:27:9: error: \[blank_line_before_return\]"
expect_output "bad.swift: a nested return is named" "bad.swift:37:13: error: \[blank_line_before_return\]"
expect_output "bad.swift: an if is named" "bad.swift:39:9: error: \[blank_line_after_multiline_if\]"

cp "$work/bad.swift" "$work/fixed.swift"
"$LINT/.tools/swiftformat" --config "$ROOT/.swiftformat" "$work/fixed.swift" > /dev/null 2>&1
"$SPACING" --fix "$work/fixed.swift" > /dev/null 2>&1
check "formatted bad.swift: SwiftFormat accepts" 0 "${format_lint[@]}" "$work/fixed.swift"
check "formatted bad.swift: SwiftLint accepts" 0 "${swiftlint_run[@]}" "$work/fixed.swift"
check "formatted bad.swift: spacing-check accepts" 0 "$SPACING" "$work/fixed.swift"
check "formatted bad.swift is the good fixture" 0 diff <(sed 1,1d "$work/fixed.swift") <(sed 1,1d "$work/good.swift")

cp "$work/fixed.swift" "$work/again.swift"
"$LINT/.tools/swiftformat" --config "$ROOT/.swiftformat" "$work/again.swift" > /dev/null 2>&1
"$SPACING" --fix "$work/again.swift" > /dev/null 2>&1
check "formatting twice changes nothing" 0 cmp "$work/fixed.swift" "$work/again.swift"

check "the check mode changes no file" 0 zsh -c 'before=$(shasum "$1"); "$2" "$1" >/dev/null; [[ "$before" == "$(shasum "$1")" ]]' _ "$work/bad.swift" "$SPACING"

if (( failures == 0 )); then echo "selftest: ok"; else echo "selftest: $failures failed"; exit 1; fi
