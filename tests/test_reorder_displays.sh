#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
helper="$root_dir/scripts/reorder-displays"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
pass() { printf 'ok - %s\n' "$*"; }

make_mocks() {
  mock_bin="$test_root/bin"
  mkdir -p "$mock_bin"
  cat >"$mock_bin/hyprctl" <<'MOCK_HYPRCTL'
#!/usr/bin/env bash
set -euo pipefail
log=${MOCK_LOG:?}
printf '%s\n' "$*" >>"$log"

if [[ ${1:-} == -j && ${2:-} == monitors ]]; then
  if [[ ${MOCK_TOPOLOGY_CHANGE:-0} == 1 || ${MOCK_POST_SYNC_LAYOUT:-0} == 1 ]]; then
    query_count=0
    [[ -r ${MOCK_STATE}.monitor-queries ]] && query_count=$(<"${MOCK_STATE}.monitor-queries")
    query_count=$((query_count + 1))
    printf '%s\n' "$query_count" >"${MOCK_STATE}.monitor-queries"
    if [[ ${MOCK_TOPOLOGY_CHANGE:-0} == 1 && $query_count -eq 3 && -r ${MOCK_CHANGED} ]]; then
      cat "$MOCK_CHANGED"
      exit 0
    fi
    if [[ ${MOCK_POST_SYNC_LAYOUT:-0} == 1 && $query_count -ge 4 && -r ${MOCK_PERSISTED} ]]; then
      cat "$MOCK_PERSISTED"
      exit 0
    fi
  fi
  cat "$MOCK_STATE"
  exit 0
fi
if [[ ${1:-} == -j && ${2:-} == activewindow ]]; then
  printf '%s\n' '{"address":"0xabc"}'
  exit 0
fi
if [[ ${1:-} == -j && ${2:-} == getoption ]]; then
  autoreload_state=false
  [[ -r ${MOCK_STATE}.autoreload ]] && autoreload_state=$(<"${MOCK_STATE}.autoreload")
  printf '{"bool":%s}\n' "$autoreload_state"
  exit 0
fi
if [[ ${1:-} == eval ]]; then
  lua=${2:-}
  if [[ $lua == *'disable_autoreload = true'* ]]; then
    printf '%s\n' true >"${MOCK_STATE}.autoreload"
  elif [[ $lua == *'disable_autoreload = false'* ]]; then
    if [[ ${MOCK_FAIL_AUTORELOAD_RESTORE_ONCE:-0} == 1
        && ! -e ${MOCK_STATE}.autoreload-restore-failed ]]; then
      : >"${MOCK_STATE}.autoreload-restore-failed"
      printf '%s\n' 'mock auto-reload restore failure' >&2
      exit 1
    fi
    printf '%s\n' false >"${MOCK_STATE}.autoreload"
  fi
  if [[ $lua == *hl.monitor* ]]; then
    count=0
    [[ -r ${MOCK_STATE}.eval-count ]] && count=$(<"${MOCK_STATE}.eval-count")
    count=$((count + 1))
    printf '%s\n' "$count" >"${MOCK_STATE}.eval-count"
    if [[ ${MOCK_FAIL_APPLY:-0} == 1 && $count -eq 1 ]]; then
      printf '%s\n' 'mock apply failure' >&2
      exit 1
    fi
    if [[ ${MOCK_FAIL_RESTORE:-0} == 1 && $count -gt 1 ]]; then
      printf '%s\n' 'mock restore failure' >&2
      exit 1
    fi
    if ((count == 1)); then
      cp -- "$MOCK_APPLIED" "$MOCK_STATE"
      if [[ ${MOCK_PAUSE_AFTER_APPLY:-0} == 1 ]]; then
        : >"${MOCK_STATE}.pause-ready"
        while [[ -e ${MOCK_STATE}.pause-ready ]]; do sleep 0.02; done
      fi
    else
      cp -- "$MOCK_ORIGINAL" "$MOCK_STATE"
    fi
  fi
  exit 0
fi
printf 'unsupported mock hyprctl call: %s\n' "$*" >&2
exit 1
MOCK_HYPRCTL
  chmod 755 "$mock_bin/hyprctl"

  cat >"$mock_bin/luac" <<'MOCK_LUAC'
#!/usr/bin/env bash
if [[ ${MOCK_LUAC_FAIL:-0} == 1 ]]; then
  printf '%s\n' 'mock luac failure' >&2
  exit 1
fi
exec /usr/bin/luac "$@"
MOCK_LUAC
  chmod 755 "$mock_bin/luac"

  cat >"$mock_bin/mv" <<'MOCK_MV'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${MOCK_FAIL_ORDER_MV:-0} == 1 && " $* " == *'/.order.json.'* ]]; then
  if [[ ! -e ${MOCK_STATE}.order-mv-failed ]]; then
    : >"${MOCK_STATE}.order-mv-failed"
    printf '%s\n' 'mock order rename failure' >&2
    exit 1
  fi
fi
exec /bin/mv "$@"
MOCK_MV
  chmod 755 "$mock_bin/mv"
}

set_fixture() {
  local fixture=$1
  export MOCK_STATE="$test_root/state.json"
  export MOCK_ORIGINAL="$test_root/original.json"
  export MOCK_APPLIED="$test_root/applied.json"
  export MOCK_LOG="$test_root/hyprctl.log"
  cp -- "$fixture" "$MOCK_STATE"
  cp -- "$fixture" "$MOCK_ORIGINAL"
  : >"$MOCK_LOG"
  rm -f -- "$MOCK_STATE.eval-count" "$MOCK_STATE.monitor-queries" "$MOCK_STATE.order-mv-failed" "$MOCK_STATE.autoreload-restore-failed"
  printf '%s\n' false >"$MOCK_STATE.autoreload"
  cp -- "$fixture" "$MOCK_APPLIED"
}

set_2_monitor_fixture() {
  local dir=$1
  cat >"$dir/two.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
  cat >"$dir/two-reversed.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
}

set_3_monitor_fixture() {
  local dir=$1
  cat >"$dir/three.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1200,"height":900,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}},
  {"name":"C","width":800,"height":600,"refreshRate":60,"x":2200,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":3}}
]
JSON
}

set_disabled_mirrored_fixture() {
  local dir=$1
  cat >"$dir/disabled-mirrored.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":true,"mirrorOf":"none","activeWorkspace":{"id":2}},
  {"name":"C","width":800,"height":600,"refreshRate":60,"x":2000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"A","activeWorkspace":{"id":3}}
]
JSON
}

new_case() {
  local fixture=$1
  rm -rf -- "$test_root/home" "$test_root/state-home" "$test_root/runtime"
  mkdir -p "$test_root/home/.config/hypr" "$test_root/state-home" "$test_root/runtime"
  printf '%s\n' 'local omarchy_monitor_scale = 1' >"$test_root/home/.config/hypr/monitors.lua"
  export HOME="$test_root/home"
  export XDG_STATE_HOME="$test_root/state-home"
  export XDG_RUNTIME_DIR="$test_root/runtime"
  unset HYPRLAND_INSTANCE_SIGNATURE
  export PATH="$mock_bin:/usr/bin:/bin"
  export MOCK_FAIL_APPLY=0 MOCK_FAIL_RESTORE=0 MOCK_FAIL_ORDER_MV=0 MOCK_LUAC_FAIL=0 MOCK_TOPOLOGY_CHANGE=0 MOCK_POST_SYNC_LAYOUT=0 MOCK_PAUSE_AFTER_APPLY=0 MOCK_FAIL_AUTORELOAD_RESTORE_ONCE=0
  set_fixture "$fixture"
}

run_ok() {
  local output
  if ! output=$($helper "$@" 2>&1); then
    printf '%s\n' "$output" >&2
    fail "expected success: $*"
  fi
  LAST_OUTPUT=$output
}

run_fail() {
  local output
  if output=$($helper "$@" 2>&1); then
    printf '%s\n' "$output" >&2
    fail "expected failure: $*"
  fi
  LAST_OUTPUT=$output
}

assert_order() {
  local expected=$1 actual
  actual=$(<"$XDG_STATE_HOME/omarchy/omarchy-display-order.display-order/order.json")
  [[ $actual == "$expected" ]] || fail "order was $actual, expected $expected"
}

make_applied_layout() {
  local fixture=$1 output=$2 names_json
  shift 2
  names_json=$(jq -cn --args '$ARGS.positional' "$@")
  jq -c --argjson order "$names_json" '
    . as $monitors
    | reduce $order[] as $name ({x: 0, out: []};
        ($monitors[] | select(.name == $name)) as $monitor
        | .out += [$monitor + {x: .x}]
        | .x += ($monitor.width / $monitor.scale)
      )
    | .out
  ' "$fixture" >"$output"
}

assert_config_order() {
  local expected=$1 config=$HOME/.config/hypr/monitors.lua
  local -a outputs=()
  mapfile -t outputs < <(awk -F'"' '/output = / {print $2}' "$config")
  [[ ${outputs[*]} == "$expected" ]] || fail "config order was ${outputs[*]}, expected $expected"
}

assert_mock_log_has_no_eval() {
  local line
  while IFS= read -r line; do
    if [[ $line == eval\ * ]]; then
      fail "mock hyprctl log contains a live eval: $line"
    fi
  done <"$MOCK_LOG"
}

assert_mock_log_empty() {
  [[ ! -s "$MOCK_LOG" ]] || fail "mock hyprctl was called: $(<"$MOCK_LOG")"
}

assert_mock_log_has_eval() {
  local line
  while IFS= read -r line; do
    if [[ $line == eval\ * ]]; then
      return 0
    fi
  done <"$MOCK_LOG"
  fail 'mock hyprctl log contains no live eval'
}

startup_claim_count() {
  local claim_dir="$XDG_RUNTIME_DIR/omarchy-display-order.display-order"
  local -a claims=()
  shopt -s nullglob
  claims=("$claim_dir"/startup-*.claim)
  shopt -u nullglob
  printf '%s\n' "${#claims[@]}"
}

assert_autoreload_state() {
  local expected=$1 actual
  actual=$(<"$MOCK_STATE.autoreload")
  [[ $actual == "$expected" ]] || fail "Hyprland auto-reload state was $actual, expected $expected"
}

assert_no_transaction_temps() {
  local runtime="$XDG_RUNTIME_DIR/omarchy-display-order.display-order"
  for path in "$runtime"/reorder-displays-order-before.* "$runtime"/reorder-displays-config-before.*; do
    [[ ! -e $path ]] || fail "transaction temporary remains: $path"
  done
}

make_mocks
mkdir -p "$test_root/fixtures"
set_2_monitor_fixture "$test_root/fixtures"
set_3_monitor_fixture "$test_root/fixtures"
set_disabled_mirrored_fixture "$test_root/fixtures"

new_case "$test_root/fixtures/two.json"
for order in 'A B' 'B A'; do
  for repeat in 1 2 3; do
    read -r first second <<<"$order"
    run_ok --dry-run "$first" "$second"
    [[ $LAST_OUTPUT == *"$first: x=0"* ]] || fail "two-monitor permutation did not put $first first"
    [[ $LAST_OUTPUT == *"$second: x=1000"* ]] || fail "two-monitor permutation did not put $second second"
  done
done
pass 'repeated two-monitor permutations are calculated without mutating Hyprland'

for order in 'A B C' 'A C B' 'B A C' 'B C A' 'C A B' 'C B A'; do
  new_case "$test_root/fixtures/three.json"
  read -r first second third <<<"$order"
  run_ok --dry-run "$first" "$second" "$third"
  [[ $LAST_OUTPUT == *"$first: x=0"* ]] || fail "three-monitor permutation did not put $first first"
  [[ $LAST_OUTPUT == *"$second: x="* ]] || fail "three-monitor permutation omitted $second"
  [[ $LAST_OUTPUT == *"$third: x="* ]] || fail "three-monitor permutation omitted $third"
done
pass 'three-monitor permutations are calculated'

for order in 'A B' 'B A'; do
  new_case "$test_root/fixtures/two.json"
  read -r first second <<<"$order"
  make_applied_layout "$test_root/fixtures/two.json" "$MOCK_APPLIED" "$first" "$second"
  run_ok --apply-and-save "$first" "$second"
  expected_order=$(jq -cn --args '$ARGS.positional' "$first" "$second")
  assert_order "$expected_order"
  assert_config_order "$order"
  cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail "two-monitor transaction did not commit live state for $order"
  assert_autoreload_state false
done
pass 'repeated two-monitor apply-and-save commits order, config, and live state'

new_case "$test_root/fixtures/two.json"
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
printf '%s\n' true >"$MOCK_STATE.autoreload"
run_ok --apply-and-save B A
assert_autoreload_state true
pass 'transaction restores an initially enabled auto-reload flag'

for order in 'A B C' 'A C B' 'B A C' 'B C A' 'C A B' 'C B A'; do
  new_case "$test_root/fixtures/three.json"
  read -r first second third <<<"$order"
  make_applied_layout "$test_root/fixtures/three.json" "$MOCK_APPLIED" "$first" "$second" "$third"
  run_ok --apply-and-save "$first" "$second" "$third"
  expected_order=$(jq -cn --args '$ARGS.positional' "$first" "$second" "$third")
  assert_order "$expected_order"
  assert_config_order "$order"
  cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail "three-monitor transaction did not commit live state for $order"
  assert_autoreload_state false
done
pass 'all three-monitor apply-and-save permutations commit order, config, and live state'

new_case "$test_root/fixtures/two.json"
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
cat >"$test_root/fixtures/two-persisted.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":1100,"y":42,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":100,"y":42,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
export MOCK_PERSISTED="$test_root/fixtures/two-persisted.json" MOCK_POST_SYNC_LAYOUT=1
run_ok --apply-and-save B A
assert_order '["B","A"]'
assert_config_order 'B A'
cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail 'semantic post-sync verification changed live state'
assert_autoreload_state false
pass 'post-sync verification accepts persisted base/y differences while enforcing order and eligibility'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
cat >"$test_root/fixtures/two-bad-persisted.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
export MOCK_PERSISTED="$test_root/fixtures/two-bad-persisted.json" MOCK_POST_SYNC_LAYOUT=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'post-sync live layout verification failed'* ]] || fail 'post-sync failure was not reported'
assert_order '["A","B"]'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'post-sync failure did not restore monitors.lua'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'post-sync failure did not restore live state'
assert_autoreload_state false
assert_no_transaction_temps
pass 'post-sync failure after config write restores config, order, live state, and autoreload'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
export MOCK_FAIL_AUTORELOAD_RESTORE_ONCE=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'could not restore Hyprland auto-reload state after sync'* ]] || fail 'transient autoreload restore failure was not reported'
[[ $LAST_OUTPUT != *'transaction rollback was incomplete'* ]] || fail 'autoreload retry recovery was incorrectly reported as incomplete'
assert_order '["A","B"]'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'autoreload restore retry did not restore monitors.lua'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'autoreload restore retry did not restore live state'
assert_autoreload_state false
assert_no_transaction_temps
pass 'transient autoreload restore failure is retried by rollback without false success'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
assert_order '["A","B"]'
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_STATE"
cp -- "$test_root/fixtures/two.json" "$MOCK_APPLIED"
run_ok --apply-saved
cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail 'apply-saved did not reload the persisted order'
run_ok --save-order B A
assert_order '["B","A"]'
run_fail --save-order A A
assert_order '["B","A"]'
pass 'persist, reload, reorder, and duplicate rejection work'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
run_ok --sync-config
assert_autoreload_state false
pass 'standalone config sync restores the captured auto-reload flag'

new_case "$test_root/fixtures/two.json"
runtime_dir="$XDG_RUNTIME_DIR/omarchy-display-order.display-order"
mkdir -p "$runtime_dir"
: >"$runtime_dir/reorder-displays.lockfile"
run_ok --save-order A B
[[ -e "$runtime_dir/reorder-displays.lockfile" ]] || fail 'advisory lock pathname was removed'

(
  exec 9>"$runtime_dir/reorder-displays.lockfile"
  flock -n 9
  sleep 2
) &
holder=$!
sleep 0.1
run_fail --save-order B A
[[ $LAST_OUTPUT == *'another display reorder is already in progress'* ]] || fail 'lock contention was not reported'
wait "$holder"
run_ok --save-order B A
assert_order '["B","A"]'
pass 'advisory lock serializes callers, preserves its pathname, and releases the FD'

new_case "$test_root/fixtures/two.json"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
export MOCK_FAIL_APPLY=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'live apply failed'* ]] || fail "apply failure was not reported: $LAST_OUTPUT"
[[ $LAST_OUTPUT == *'automatic restore'* ]] || fail "apply failure did not attempt live rollback: $LAST_OUTPUT"
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'apply failure did not restore live state'
[[ ! -e "$XDG_STATE_HOME/omarchy/omarchy-display-order.display-order/order.json" ]] || fail 'apply failure wrote order.json'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'apply failure changed monitors.lua'
assert_no_transaction_temps
pass 'live apply failure restores the snapshot and cleans transaction files'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
export MOCK_FAIL_ORDER_MV=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'persistence failed after live apply'* ]] || fail 'save failure was not reported after apply'
assert_order '["A","B"]'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'save failure did not restore live state'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'save failure changed monitors.lua'
assert_no_transaction_temps
pass 'order save failure rolls back live state and the old order'

new_case "$test_root/fixtures/two.json"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
export MOCK_PAUSE_AFTER_APPLY=1
signal_output="$test_root/signal-output"
"$helper" --apply-and-save B A >"$signal_output" 2>&1 &
signal_pid=$!
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [[ -e "$MOCK_STATE.pause-ready" ]] && break
  sleep 0.05
done
[[ -e "$MOCK_STATE.pause-ready" ]] || fail 'transaction signal test did not reach its post-apply pause'
kill -TERM "$signal_pid"
rm -f -- "$MOCK_STATE.pause-ready"
if wait "$signal_pid"; then
  signal_status=0
else
  signal_status=$?
fi
[[ $signal_status -ne 0 ]] || fail 'SIGTERM unexpectedly returned success'
[[ $signal_status -eq 143 ]] || fail "SIGTERM returned $signal_status instead of 143"
signal_output_text=$(<"$signal_output")
[[ $signal_output_text == *'received TERM before transaction commit'* ]] || fail 'SIGTERM rollback was not reported'
[[ ! -e "$XDG_STATE_HOME/omarchy/omarchy-display-order.display-order/order.json" ]] || fail 'SIGTERM left a new order.json'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'SIGTERM changed monitors.lua'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'SIGTERM did not restore live state'
assert_no_transaction_temps
lock_path="$XDG_RUNTIME_DIR/omarchy-display-order.display-order/reorder-displays.lockfile"
[[ -e "$lock_path" ]] || fail 'SIGTERM removed the advisory lock pathname'
if ! (exec 9>"$lock_path"; flock -n 9); then
  fail 'SIGTERM did not release the advisory lock FD'
fi
pass 'SIGTERM rolls back once, cleans temporary state, and releases the lock'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
export MOCK_LUAC_FAIL=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'monitor config sync failed'* ]] || fail 'config sync failure was not reported'
assert_order '["A","B"]'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'sync failure did not restore monitors.lua'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'sync failure did not restore live state'
assert_no_transaction_temps
pass 'config sync failure rolls back order, config, and live state'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
cat >"$test_root/fixtures/three-hotplug.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}},
  {"name":"C","width":800,"height":600,"refreshRate":60,"x":2000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":3}}
]
JSON
export MOCK_CHANGED="$test_root/fixtures/three-hotplug.json" MOCK_TOPOLOGY_CHANGE=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'topology changed before persistence'* ]] || fail 'topology change before persistence was not reported'
assert_order '["A","B"]'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'topology change did not restore live state'
assert_no_transaction_temps
pass 'topology changes before persistence abort and roll back the transaction'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
export MOCK_FAIL_ORDER_MV=1 MOCK_FAIL_RESTORE=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'rollback failed: could not restore the live display snapshot'* ]] || fail 'failed live rollback was not reported specifically'
assert_order '["A","B"]'
assert_no_transaction_temps
pass 'failed rollback reports the specific live snapshot failure'

new_case "$test_root/fixtures/disabled-mirrored.json"
run_fail --apply-and-save A B
[[ $LAST_OUTPUT == *'requires exactly all currently eligible monitors'* ]] || fail 'disabled/mirrored topology was not enforced'
assert_mock_log_has_no_eval
run_ok --apply-and-save A
[[ $LAST_OUTPUT == *'as one transaction'* ]] || fail 'the complete eligible order was not accepted'
pass 'disabled and mirrored monitors are excluded from transactional order input'

new_case "$test_root/fixtures/two.json"
mkdir -p "$XDG_STATE_HOME/omarchy/omarchy-display-order.display-order"
printf '%s\n' '{"not":"an order"}' >"$XDG_STATE_HOME/omarchy/omarchy-display-order.display-order/order.json"
run_fail --apply-saved
[[ $LAST_OUTPUT == *'saved display order is invalid'* ]] || fail 'invalid saved JSON was not rejected'
assert_mock_log_has_no_eval
pass 'invalid saved JSON is rejected before live changes'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
cat >"$test_root/fixtures/hotplug.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"C","width":800,"height":600,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
cp -- "$test_root/fixtures/hotplug.json" "$MOCK_STATE"
cp -- "$test_root/fixtures/hotplug.json" "$MOCK_ORIGINAL"
cp -- "$test_root/fixtures/hotplug.json" "$MOCK_APPLIED"
run_ok --apply-saved
[[ $LAST_OUTPUT == *'saved monitor is not currently eligible and will be skipped'* ]] || fail 'hotplug removal was not reported'
[[ $LAST_OUTPUT == *'newly eligible monitor appended'* ]] || fail 'hotplug addition was not reported'
pass 'hotplugged and disconnected monitors are handled without compositor state'

new_case "$test_root/fixtures/two.json"
run_ok --save-order B A
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
export HYPRLAND_INSTANCE_SIGNATURE=session-one
run_ok --startup-apply-saved
cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail 'first startup claim did not apply the saved order'
[[ $(startup_claim_count) -eq 1 ]] || fail 'first startup did not create exactly one claim'
: >"$MOCK_LOG"
run_ok --startup-apply-saved
assert_mock_log_empty
[[ $(startup_claim_count) -eq 1 ]] || fail 'same startup signature created another claim'
pass 'the same Hyprland signature applies startup order only once'

cp -- "$MOCK_ORIGINAL" "$MOCK_STATE"
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
rm -f -- "$MOCK_STATE.eval-count" "$MOCK_STATE.monitor-queries"
: >"$MOCK_LOG"
export HYPRLAND_INSTANCE_SIGNATURE=session-two
run_ok --startup-apply-saved
assert_mock_log_has_eval
[[ $(startup_claim_count) -eq 2 ]] || fail 'new startup signature did not create a new claim'
pass 'a new Hyprland signature can perform one startup apply'

new_case "$test_root/fixtures/two.json"
export HYPRLAND_INSTANCE_SIGNATURE=session-without-order
run_ok --startup-apply-saved
assert_mock_log_empty
[[ $(startup_claim_count) -eq 1 ]] || fail 'startup without order did not record its claim'
: >"$MOCK_LOG"
run_ok --startup-apply-saved
assert_mock_log_empty
pass 'startup without order records a terminal claim without touching Hyprland'

new_case "$test_root/fixtures/two.json"
run_ok --save-order B A
cp -- "$test_root/fixtures/two-reversed.json" "$MOCK_APPLIED"
export HYPRLAND_INSTANCE_SIGNATURE=session-explicit
run_ok --startup-apply-saved
cp -- "$test_root/fixtures/two.json" "$MOCK_STATE"
rm -f -- "$MOCK_STATE.eval-count" "$MOCK_STATE.monitor-queries"
: >"$MOCK_LOG"
run_ok --apply-saved
assert_mock_log_has_eval
pass 'explicit apply-saved remains repeatable after a startup claim'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
export HYPRLAND_INSTANCE_SIGNATURE=session-terminal
export MOCK_FAIL_APPLY=1
run_fail --startup-apply-saved
[[ $(startup_claim_count) -eq 1 ]] || fail 'terminal startup failure did not remain claimed'
export MOCK_FAIL_APPLY=0
cp -- "$MOCK_ORIGINAL" "$MOCK_STATE"
: >"$MOCK_LOG"
run_ok --startup-apply-saved
assert_mock_log_empty
pass 'terminal startup failure is not reexecuted on hot reload'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
unset HYPRLAND_INSTANCE_SIGNATURE
run_fail --startup-apply-saved
assert_mock_log_empty
[[ $(startup_claim_count) -eq 0 ]] || fail 'missing signature created a startup claim'
pass 'missing startup signature fails before any Hyprland call'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
export HYPRLAND_INSTANCE_SIGNATURE='unsafe/signature'
run_fail --startup-apply-saved
assert_mock_log_empty
[[ $(startup_claim_count) -eq 0 ]] || fail 'unsafe signature created a startup claim'
pass 'unsafe startup signature fails before any Hyprland call'

printf 'All reorder-displays tests passed.\n'
