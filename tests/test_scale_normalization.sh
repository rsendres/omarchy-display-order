#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
model="$root_dir/Model.js"
helper="$root_dir/scripts/reorder-displays"

command -v node >/dev/null || { printf 'SKIP: node is required to test Model.js\n'; exit 0; }

# Keep the cross-runtime cases in one table. Extracting the existing function
# avoids adding a production test-only command or a JS↔Bash runtime dependency.
eval "$(awk '/^clean_scale\(\) \{/{inside=1} inside{print} inside && /^}/{exit}' "$helper")"

model_clean_scale() {
  node - "$model" "$1" "$2" "$3" <<'NODE'
const model = require(process.argv[2])
process.stdout.write(model.cleanScale(process.argv[3], process.argv[4], process.argv[5]))
NODE
}

model_normalize_scale() {
  node - "$model" "$1" <<'NODE'
const model = require(process.argv[2])
process.stdout.write(model.normalizeScale(process.argv[3]))
NODE
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# scale width height reduced_units Model.js_output shell_output
cases=(
  '1.6 1600 900 200 1.67 1.66667'
  '1.5 1000 800 192 1.6 1.6'
  '1.234 1000 800 150 1.25 1.25'
  '2 1920 1080 240 2 2'
)

for test_case in "${cases[@]}"; do
  read -r scale width height reduced_units expected_model expected_shell <<<"$test_case"
  expected_effective=$(awk -v units="$reduced_units" 'BEGIN { printf "%g", units / 120 }')
  expected_shell_from_units=$(awk -v units="$reduced_units" 'BEGIN { printf "%g", units / 120 }')
  expected_model_from_units=$(model_normalize_scale "$expected_effective")
  [[ $expected_shell == "$expected_shell_from_units" ]] \
    || fail "case table shell formatting is inconsistent for $scale,$width,$height"
  [[ $expected_model == "$expected_model_from_units" ]] \
    || fail "case table UI formatting is inconsistent for $scale,$width,$height"
  model_output=$(model_clean_scale "$scale" "$width" "$height")
  shell_output=$(clean_scale "$scale" "$width" "$height")
  [[ $model_output == "$expected_model" ]] \
    || fail "Model.js cleanScale($scale,$width,$height) was $model_output, expected $expected_model"
  [[ $shell_output == "$expected_shell" ]] \
    || fail "shell clean_scale($scale,$width,$height) was $shell_output, expected $expected_shell"
  [[ $(model_normalize_scale "$shell_output") == "$expected_model" ]] \
    || fail "Model.js presentation normalization did not match effective shell scale $shell_output"
done

[[ $(model_normalize_scale 'not-a-scale') == '' ]] \
  || fail 'Model.js invalid normalization fallback changed'

printf 'ok - scale reduction and formatting contracts are pinned\n'
