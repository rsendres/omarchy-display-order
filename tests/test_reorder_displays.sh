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

apply_monitor_layout() {
  local layout_file=$1 current_state layout_state layout_tmp
  current_state=$(<"$MOCK_STATE")
  layout_state=$(<"$layout_file")
  layout_tmp="${MOCK_STATE}.monitor-layout"
  jq -n --argjson layout "$layout_state" --argjson current "$current_state" '
    $layout
    | map(. as $layout_monitor
      | ($current[] | select(.name == $layout_monitor.name)) as $live
      | .id = $live.id
      | .activeWorkspace = $live.activeWorkspace
      | .specialWorkspace = $live.specialWorkspace)
  ' >"$layout_tmp"
  mv -- "$layout_tmp" "$MOCK_STATE"
}

if [[ ${1:-} == -j && ${2:-} == monitors ]]; then
  if [[ ${MOCK_PRE_LAYOUT_REVALIDATION:-0} == 1 || ${MOCK_TOPOLOGY_CHANGE:-0} == 1 || ${MOCK_TOPOLOGY_CHANGE_BEFORE_WORKSPACE:-0} == 1 || ${MOCK_FINAL_WORKSPACE_VERIFY:-0} == 1 || ${MOCK_POST_SYNC_LAYOUT:-0} == 1 ]]; then
    query_count=0
    [[ -r ${MOCK_STATE}.monitor-queries ]] && query_count=$(<"${MOCK_STATE}.monitor-queries")
    query_count=$((query_count + 1))
    printf '%s\n' "$query_count" >"${MOCK_STATE}.monitor-queries"
    if [[ ${MOCK_TOPOLOGY_CHANGE:-0} == 1 && $query_count -eq 7 && -r ${MOCK_CHANGED} ]]; then
      cat "$MOCK_CHANGED"
      exit 0
    fi
    if [[ ${MOCK_PRE_LAYOUT_REVALIDATION:-0} == 1 && $query_count -eq 2 && -r ${MOCK_PRE_LAYOUT_STATE} ]]; then
      cat "$MOCK_PRE_LAYOUT_STATE"
      exit 0
    fi
    if [[ ${MOCK_TOPOLOGY_CHANGE_BEFORE_WORKSPACE:-0} == 1 && $query_count -ge 3 && -r ${MOCK_CHANGED} ]]; then
      cat "$MOCK_CHANGED"
      exit 0
    fi
    if [[ ${MOCK_FINAL_WORKSPACE_VERIFY:-0} == 1 && -e ${MOCK_STATE}.workspace-swapped && ! -e ${MOCK_STATE}.final-query-used && -r ${MOCK_FINAL_QUERY_STATE} ]]; then
      : >"${MOCK_STATE}.final-query-used"
      cat "$MOCK_FINAL_QUERY_STATE"
      exit 0
    fi
    if [[ ${MOCK_POST_SYNC_LAYOUT:-0} == 1 && -r ${MOCK_PERSISTED}
        && -r "$HOME/.config/hypr/monitors.lua"
        && $(<"$HOME/.config/hypr/monitors.lua") == *'BEGIN omarchy-display-order.display-order managed order'* ]]; then
      # A config reload changes monitor geometry, not the active normal
      # workspace identities already preserved by the live reorder.
      current_state=$(<"$MOCK_STATE")
      jq --argjson current "$current_state" '
        map(. as $persisted
          | ($current[] | select(.name == $persisted.name)) as $live
          | $persisted + {
              id: $live.id,
              activeWorkspace: $live.activeWorkspace,
              specialWorkspace: $live.specialWorkspace
            })
      ' "$MOCK_PERSISTED"
      exit 0
    fi
  fi
  cat "$MOCK_STATE"
  exit 0
fi
if [[ ${1:-} == -j && ${2:-} == workspaces ]]; then
  jq -c '[.[] | .activeWorkspace] | unique_by(.id)' "$MOCK_STATE"
  exit 0
fi
if [[ ${1:-} == -j && ${2:-} == activewindow ]]; then
  if [[ -n ${MOCK_ACTIVEWINDOW_JSON:-} ]]; then
    printf '%s\n' "$MOCK_ACTIVEWINDOW_JSON"
  else
    printf '%s\n' '{"address":"0xabc"}'
  fi
  exit 0
fi
if [[ ${1:-} == -j && ${2:-} == clients ]]; then
  printf '%s\n' "${MOCK_CLIENTS_JSON:?}"
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
  workspace_swap_failed=false
  partial_swap_triggered=false
  while IFS= read -r dispatch; do
    if [[ $dispatch == *'legacy.swap_monitors'* ]]; then
      if [[ $dispatch =~ monitor1[[:space:]]*=[[:space:]]*\"([^\"]+)\".*monitor2[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        monitor1=${BASH_REMATCH[1]}
        monitor2=${BASH_REMATCH[2]}
        printf 'swap_monitors monitor1=%s monitor2=%s\n' "$monitor1" "$monitor2" >>"${MOCK_WORKSPACE_LOG:?}"
        if [[ ${MOCK_FAIL_WORKSPACE_SWAP:-0} == 1 ]]; then
          workspace_swap_failed=true
          continue
        fi
        partial_swap_now=false
        if [[ ${MOCK_PARTIAL_WORKSPACE_SWAP:-0} == 1
            && ! -e ${MOCK_STATE}.partial-swap-used
            && $partial_swap_triggered == false ]]; then
          partial_swap_triggered=true
          partial_swap_now=true
          : >"${MOCK_STATE}.partial-swap-used"
        elif [[ $workspace_swap_failed == true ]]; then
          continue
        fi
        swap_tmp="${MOCK_STATE}.workspace-swap"
        jq --arg monitor1 "$monitor1" --arg monitor2 "$monitor2" '
          . as $monitors
          | ($monitors | map(select(.name == $monitor1)) | first) as $first
          | ($monitors | map(select(.name == $monitor2)) | first) as $second
          | map(
              if .name == $monitor1 then
                .activeWorkspace = $second.activeWorkspace
              elif .name == $monitor2 then
                .activeWorkspace = $first.activeWorkspace
              else . end
            )
        ' "$MOCK_STATE" >"$swap_tmp"
        mv -- "$swap_tmp" "$MOCK_STATE"
        : >"${MOCK_STATE}.workspace-swapped"
        if [[ $partial_swap_now == true ]]; then
          workspace_swap_failed=true
        fi
      else
        printf 'workspace_dispatch %s\n' "$dispatch" >>"${MOCK_WORKSPACE_LOG:?}"
      fi
    elif [[ $dispatch == *'hl.dsp.workspace.change_id'* ]]; then
      if [[ $dispatch =~ workspace[[:space:]]*=[[:space:]]*([0-9]+).*id[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
        old=${BASH_REMATCH[1]}
        new=${BASH_REMATCH[2]}
        printf 'change_id workspace=%s id=%s\n' "$old" "$new" >>"${MOCK_WORKSPACE_LOG:?}"
        change_tmp="${MOCK_STATE}.workspace-change-id"
        jq --argjson old "$old" --argjson new "$new" '
          map(if .activeWorkspace.id == $old then
                .activeWorkspace.id = $new | .activeWorkspace.name = ($new | tostring)
              else . end)
        ' "$MOCK_STATE" >"$change_tmp"
        mv -- "$change_tmp" "$MOCK_STATE"
      else
        printf 'malformed change_id dispatch: %s\n' "$dispatch" >&2
        exit 1
      fi
    elif [[ $dispatch =~ workspace[[:space:]]*= ]]; then
      printf 'workspace_dispatch %s\n' "$dispatch" >>"${MOCK_WORKSPACE_LOG:?}"
    fi
  done <<<"$lua"
  if [[ $workspace_swap_failed == true ]]; then
    printf '%s\n' 'mock workspace swap failure' >&2
    exit 1
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
      apply_monitor_layout "$MOCK_APPLIED"
      if [[ ${MOCK_PAUSE_AFTER_APPLY:-0} == 1 ]]; then
        : >"${MOCK_STATE}.pause-ready"
        while [[ -e ${MOCK_STATE}.pause-ready ]]; do sleep 0.02; done
      fi
    else
      apply_monitor_layout "$MOCK_ORIGINAL"
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

normalize_workspace_json() {
  local source=$1 output=$2
  jq '
    def with_workspace_name:
      (. // {id: 0, name: ""})
      | .name = (.name // (if (.id // 0) == 0 then "" else (.id | tostring) end));
    to_entries
    | map(.key as $index
      | .value
      | .id = (.id // $index)
      | .activeWorkspace = (.activeWorkspace | with_workspace_name)
      | .specialWorkspace = (.specialWorkspace | with_workspace_name)
    )
  ' "$source" >"$output"
}

set_applied_fixture() {
  normalize_workspace_json "$1" "$MOCK_APPLIED"
}

set_fixture() {
  local fixture=$1
  export MOCK_STATE="$test_root/state.json"
  export MOCK_ORIGINAL="$test_root/original.json"
  export MOCK_APPLIED="$test_root/applied.json"
  export MOCK_LOG="$test_root/hyprctl.log"
  export MOCK_WORKSPACE_LOG="$test_root/workspace-dispatch.log"
  normalize_workspace_json "$fixture" "$MOCK_STATE"
  cp -- "$MOCK_STATE" "$MOCK_ORIGINAL"
  : >"$MOCK_LOG"
  : >"$MOCK_WORKSPACE_LOG"
  rm -f -- "$MOCK_STATE.eval-count" "$MOCK_STATE.monitor-queries" "$MOCK_STATE.order-mv-failed" "$MOCK_STATE.autoreload-restore-failed" "$MOCK_STATE.final-query-used" "$MOCK_STATE.workspace-swapped" "$MOCK_STATE.partial-swap-used"
  printf '%s\n' false >"$MOCK_STATE.autoreload"
  cp -- "$MOCK_STATE" "$MOCK_APPLIED"
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

set_individual_scale_fixture() {
  local dir=$1
  cat >"$dir/two-individual-scales.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1.5,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
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

set_workspace_fixture() {
  local dir=$1
  cat >"$dir/workspace-two-base.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"1"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"2"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-two-arbitrary.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-three-cycle.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":9,"name":"nine"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":3,"name":"three"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"C","width":1000,"height":800,"refreshRate":60,"x":2000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":12,"name":"twelve"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-three-partial.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"one"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":3,"name":"three"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"C","width":1000,"height":800,"refreshRate":60,"x":2000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"two"},"specialWorkspace":{"id":-99,"name":"special:keep"}}
]
JSON
  cat >"$dir/workspace-one.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-special-changed.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":-99,"name":"special:visible"}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-two-named.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"project"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"mail"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-pre-topology.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"C","width":800,"height":600,"refreshRate":60,"x":2000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":12,"name":"extra"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-pre-order.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-pre-special.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":-99,"name":"special:appeared"}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-pre-identity.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":8,"name":"changed"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
  cat >"$dir/workspace-final-bad.json" <<'JSON'
[
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":99,"name":"wrong-b"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":98,"name":"wrong-a"},"specialWorkspace":{"id":0,"name":""}}
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
  export MOCK_ACTIVEWINDOW_JSON='{"address":"0xabc"}'
  export MOCK_CLIENTS_JSON='[{"address":"0xabc","monitor":0}]'
  export MOCK_FAIL_APPLY=0 MOCK_FAIL_RESTORE=0 MOCK_FAIL_ORDER_MV=0 MOCK_LUAC_FAIL=0 MOCK_TOPOLOGY_CHANGE=0 MOCK_TOPOLOGY_CHANGE_BEFORE_WORKSPACE=0 MOCK_PRE_LAYOUT_REVALIDATION=0 MOCK_FINAL_WORKSPACE_VERIFY=0 MOCK_FAIL_WORKSPACE_SWAP=0 MOCK_PARTIAL_WORKSPACE_SWAP=0 MOCK_POST_SYNC_LAYOUT=0 MOCK_PAUSE_AFTER_APPLY=0 MOCK_FAIL_AUTORELOAD_RESTORE_ONCE=0
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
  local fixture=$1 output=$2 names_json raw_output
  shift 2
  names_json=$(jq -cn --args '$ARGS.positional' "$@")
  raw_output="${output}.raw.$$"
  jq -c --argjson order "$names_json" '
    . as $monitors
    | reduce $order[] as $name ({x: 0, out: []};
        ($monitors[] | select(.name == $name)) as $monitor
        | .out += [$monitor + {x: .x}]
        | .x += ($monitor.width / $monitor.scale)
      )
    | .out
  ' "$fixture" >"$raw_output"
  normalize_workspace_json "$raw_output" "$output"
  rm -f -- "$raw_output"
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

workspace_dispatch_count() {
  [[ -s "$MOCK_WORKSPACE_LOG" ]] || { printf '0\n'; return; }
  wc -l <"$MOCK_WORKSPACE_LOG"
}

assert_no_workspace_dispatches() {
  [[ $(workspace_dispatch_count) -eq 0 ]] || fail "workspace dispatches were issued: $(<"$MOCK_WORKSPACE_LOG")"
}

assert_workspace_dispatches_are_swaps() {
  local line
  while IFS= read -r line; do
    [[ $line == 'swap_monitors monitor1='* ]] || fail "unexpected workspace dispatch: $line"
    [[ $line == *' monitor2='* ]] || fail "malformed workspace swap dispatch: $line"
  done <"$MOCK_WORKSPACE_LOG"
}

assert_active_workspace() {
  local monitor=$1 expected_id=$2 expected_name=$3
  jq -e --arg monitor "$monitor" --arg name "$expected_name" --argjson id "$expected_id" '
    any(.[]; .name == $monitor
      and .activeWorkspace.id == $id
      and .activeWorkspace.name == $name)
  ' "$MOCK_STATE" >/dev/null || fail "active workspace on $monitor was not $expected_id/$expected_name"
}

assert_special_workspace() {
  local monitor=$1 expected_id=$2 expected_name=$3
  jq -e --arg monitor "$monitor" --arg name "$expected_name" --argjson id "$expected_id" '
    any(.[]; .name == $monitor
      and .specialWorkspace.id == $id
      and .specialWorkspace.name == $name)
  ' "$MOCK_STATE" >/dev/null || fail "special workspace on $monitor was not $expected_id/$expected_name"
}

assert_no_monitor_eval() {
  local line
  while IFS= read -r line; do
    if [[ $line == eval\ * && $line == *hl.monitor* ]]; then
      fail "monitor eval was issued: $line"
    fi
  done <"$MOCK_LOG"
}

assert_interactive_reorder_animation_suppression() {
  local monitor_eval tag
  monitor_eval=$(awk '
    function finish() {
      if (in_eval && block ~ /hl.monitor/) {
        count++
        if (count == 1) print block
      }
      in_eval = 0
      block = ""
    }
    /^eval / { finish(); in_eval = 1; block = $0; next }
    /^-j / { finish(); next }
    in_eval { block = block "\n" $0 }
    END { finish(); if (count != 1) exit 1 }
  ' "$MOCK_LOG") || fail 'expected exactly one monitor eval for interactive reorder suppression'

  [[ $monitor_eval == *'local displayOrderNoAnimationRule = hl.window_rule({'* ]] \
    || fail 'interactive monitor eval did not create a named dynamic window rule'
  [[ $monitor_eval == *'name = "omarchy_display_order_no_animation"'* ]] \
    || fail 'interactive monitor eval did not name the temporary window rule'
  [[ $monitor_eval == *'displayOrderNoAnimationRule:set_enabled(false)'* \
      && $monitor_eval == *'displayOrderNoAnimationRule:set_enabled(true)'* ]] \
    || fail 'interactive monitor eval did not dynamically scope the rule'
  [[ $monitor_eval == *'no_anim = true'* ]] \
    || fail 'interactive monitor eval did not enable no_anim on the temporary rule'
  [[ $monitor_eval == *'hl.timer(function()'* && $monitor_eval == *"end,{timeout=150,type='oneshot'})"* ]] \
    || fail 'interactive monitor eval did not schedule the compositor cleanup timer'
  [[ $monitor_eval == *'hl.monitor'* ]] \
    || fail 'interactive monitor eval did not contain monitor mutations'

  tag=$(awk -F'"' '/match = \{ tag = / { print $2; exit }' <<<"$monitor_eval")
  [[ $tag == omarchy_display_order_reorder ]] \
    || fail "interactive monitor eval did not use a safe temporary tag: $tag"
  [[ $monitor_eval == *"hl.dsp.window.tag"* ]] \
    || fail 'interactive monitor eval did not use the window tag dispatcher'
  [[ $monitor_eval == *"hl.dispatch(hl.dsp.window.tag({ window = \"address:0xabc\", tag = \"+$tag\" }))"* ]] \
    || fail 'interactive monitor eval did not add the temporary tag to targets'
  [[ $monitor_eval == *"hl.dispatch(hl.dsp.window.tag({ window = \"address:0xabc\", tag = \"-$tag\" }))"* ]] \
    || fail 'interactive monitor eval did not schedule removal of the temporary tag'
  [[ $monitor_eval == *'window = "address:0xabc"'* ]] \
    || fail 'interactive monitor eval did not target the captured client address'
}

assert_no_interactive_reorder_animation_suppression() {
  local log
  log=$(<"$MOCK_LOG")
  [[ $log != *'hl.window_rule'* && $log != *'hl.timer(function()'* \
      && $log != *'hl.dsp.window.tag'* ]] \
    || fail 'non-interactive eval unexpectedly contained reorder animation suppression'
}

assert_monitor_state_matches_ignoring_workspaces() {
  local actual_file=$1 expected_file=$2 actual expected
  actual=$(jq -c 'map(del(.activeWorkspace, .specialWorkspace, .id))' "$actual_file")
  expected=$(jq -c 'map(del(.activeWorkspace, .specialWorkspace, .id))' "$expected_file")
  [[ $actual == "$expected" ]] || fail "monitor layout/state was $actual, expected $expected"
}

assert_focus_monitor() {
  local expected=$1 line
  while IFS= read -r line; do
    [[ $line == *"hl.dsp.focus({ monitor = \"$expected\" })"* ]] && return 0
  done <"$MOCK_LOG"
  fail "focus fallback did not target monitor $expected"
}

assert_window_focus_dispatch_count() {
  local expected=$1 line count=0
  while IFS= read -r line; do
    if [[ $line == *"hl.dsp.focus({ window = \"$expected\" })"* ]]; then
      count=$((count + 1))
    fi
    [[ $line != *'hl.dsp.focus({ monitor ='* ]] || fail "active client focus fell back to a monitor: $line"
  done <"$MOCK_LOG"
  [[ $count -eq 1 ]] || fail "expected exactly one focus dispatch for $expected, got $count"
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
set_individual_scale_fixture "$test_root/fixtures"
set_3_monitor_fixture "$test_root/fixtures"
set_disabled_mirrored_fixture "$test_root/fixtures"
set_workspace_fixture "$test_root/fixtures"

new_case "$test_root/fixtures/workspace-two-base.json"
make_applied_layout "$test_root/fixtures/workspace-two-base.json" "$MOCK_APPLIED" B A
run_ok --apply-live B A
assert_interactive_reorder_animation_suppression
assert_active_workspace B 1 1
assert_active_workspace A 2 2
[[ $(workspace_dispatch_count) -eq 3 ]] || fail 'base workspace cycle did not use a temporary change-id'
[[ $(<"$MOCK_WORKSPACE_LOG") == *change_id* ]] || fail 'base workspace reorder did not use change_id'
pass 'base workspaces are renumbered through change_id'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
run_ok --apply-live B A
assert_active_workspace B 4 chat
assert_active_workspace A 7 dev
assert_no_workspace_dispatches
pass 'arbitrary workspace ids are not renumbered'

new_case "$test_root/fixtures/workspace-three-cycle.json"
make_applied_layout "$test_root/fixtures/workspace-three-cycle.json" "$MOCK_APPLIED" C A B
run_ok --apply-live C A B
assert_active_workspace C 12 twelve
assert_active_workspace A 9 nine
assert_active_workspace B 3 three
assert_no_workspace_dispatches
pass 'non-base workspace cycles are not renumbered'

new_case "$test_root/fixtures/workspace-three-partial.json"
make_applied_layout "$test_root/fixtures/workspace-three-partial.json" "$MOCK_APPLIED" B A C
run_ok --apply-live B A C
assert_active_workspace B 3 three
assert_active_workspace A 1 one
assert_active_workspace C 2 two
assert_special_workspace C -99 special:keep
assert_no_workspace_dispatches
pass 'mixed workspace IDs remain untouched'

new_case "$test_root/fixtures/workspace-one.json"
make_applied_layout "$test_root/fixtures/workspace-one.json" "$MOCK_APPLIED" A
run_ok --apply-live A
assert_active_workspace A 7 dev
assert_no_workspace_dispatches
pass 'one-monitor reorder performs zero workspace changes'

new_case "$test_root/fixtures/workspace-two-named.json"
make_applied_layout "$test_root/fixtures/workspace-two-named.json" "$MOCK_APPLIED" B A
run_ok --apply-live B A
assert_active_workspace B 4 mail
assert_active_workspace A 7 project
assert_no_workspace_dispatches
pass 'named workspaces are preserved without renumbering'

new_case "$test_root/fixtures/two-reversed.json"
run_ok --save-order B A
export HYPRLAND_INSTANCE_SIGNATURE=startup-no-workspace-dispatch
run_ok --startup-apply-saved
assert_no_interactive_reorder_animation_suppression
assert_no_workspace_dispatches
pass 'startup apply performs zero workspace dispatches when visual slots are already correct'

new_case "$test_root/fixtures/two-individual-scales.json"
run_ok --save-order A B
cat >"$test_root/fixtures/workspace-scale-applied.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":2,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1,"name":"base-one"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":500,"y":0,"scale":1.5,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2,"name":"base-two"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
set_applied_fixture "$test_root/fixtures/workspace-scale-applied.json"
run_ok --set-scale 2
assert_no_interactive_reorder_animation_suppression
assert_window_focus_dispatch_count 'address:0xabc'
assert_no_workspace_dispatches
pass 'set-scale performs zero workspace dispatches'

new_case "$test_root/fixtures/workspace-special-changed.json"
make_applied_layout "$test_root/fixtures/workspace-special-changed.json" "$MOCK_APPLIED" B A
run_ok --apply-live B A
assert_no_workspace_dispatches
pass 'visible special workspace skips renumbering but applies geometry'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
cat >"$test_root/fixtures/workspace-topology-changed.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":7,"name":"dev"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":1000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":4,"name":"chat"},"specialWorkspace":{"id":0,"name":""}},
  {"name":"C","width":800,"height":600,"refreshRate":60,"x":2000,"y":0,"scale":1,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":12,"name":"extra"},"specialWorkspace":{"id":0,"name":""}}
]
JSON
export MOCK_CHANGED="$test_root/fixtures/workspace-topology-changed.json" MOCK_TOPOLOGY_CHANGE_BEFORE_WORKSPACE=1
run_fail --apply-live B A
assert_no_workspace_dispatches
pass 'topology changes before workspace swaps suppress all workspace dispatches'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
export MOCK_ACTIVEWINDOW_JSON='{}'
run_ok --apply-live B A
pass 'reorder succeeds without an active window'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
export MOCK_PRE_LAYOUT_STATE="$test_root/fixtures/workspace-pre-topology.json" MOCK_PRE_LAYOUT_REVALIDATION=1
run_fail --apply-live B A
assert_no_monitor_eval
assert_no_workspace_dispatches
pass 'pre-layout topology revalidation aborts before monitor evaluation'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
export MOCK_PRE_LAYOUT_STATE="$test_root/fixtures/workspace-pre-order.json" MOCK_PRE_LAYOUT_REVALIDATION=1
run_fail --apply-live B A
assert_no_monitor_eval
assert_no_workspace_dispatches
pass 'pre-layout monitor-order revalidation aborts before monitor evaluation'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
export MOCK_PRE_LAYOUT_STATE="$test_root/fixtures/workspace-pre-special.json" MOCK_PRE_LAYOUT_REVALIDATION=1
run_ok --apply-live B A
assert_no_workspace_dispatches
pass 'pre-layout special workspace skips renumbering'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
export MOCK_PRE_LAYOUT_STATE="$test_root/fixtures/workspace-pre-identity.json" MOCK_PRE_LAYOUT_REVALIDATION=1
run_ok --apply-live B A
assert_no_workspace_dispatches
pass 'non-base workspace changes do not block geometry'

new_case "$test_root/fixtures/workspace-two-arbitrary.json"
make_applied_layout "$test_root/fixtures/workspace-two-arbitrary.json" "$MOCK_APPLIED" B A
export MOCK_FAIL_ORDER_MV=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'persistence failed after live apply'* ]] || fail 'persistence failure was not reported'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'persistence failure did not restore the live state'
assert_no_workspace_dispatches
pass 'persistence failure restores geometry without workspace movement'

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
  assert_monitor_state_matches_ignoring_workspaces "$MOCK_STATE" "$MOCK_APPLIED"
  assert_autoreload_state false
done
pass 'repeated two-monitor apply-and-save commits order, config, and live state'

new_case "$test_root/fixtures/two.json"
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
  assert_monitor_state_matches_ignoring_workspaces "$MOCK_STATE" "$MOCK_APPLIED"
  assert_autoreload_state false
done
pass 'all three-monitor apply-and-save permutations commit order, config, and live state'

new_case "$test_root/fixtures/two.json"
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
assert_monitor_state_matches_ignoring_workspaces "$MOCK_STATE" "$MOCK_APPLIED"
assert_autoreload_state false
pass 'post-sync verification accepts persisted base/y differences while enforcing order and eligibility'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
set_applied_fixture "$test_root/fixtures/two.json"
run_ok --apply-saved
assert_monitor_state_matches_ignoring_workspaces "$MOCK_STATE" "$MOCK_APPLIED"
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
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
set_applied_fixture "$test_root/fixtures/two-reversed.json"
original_config=$(<"$HOME/.config/hypr/monitors.lua")
export MOCK_LUAC_FAIL=1
run_fail --apply-and-save B A
[[ $LAST_OUTPUT == *'monitor config sync failed'* ]] || fail 'config sync failure was not reported'
assert_order '["A","B"]'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'sync failure did not restore monitors.lua'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'sync failure did not restore live state'
assert_no_transaction_temps
pass 'config sync failure rolls back order, config, and live state'

new_case "$test_root/fixtures/two-individual-scales.json"
run_ok --save-order A B
cat >"$test_root/fixtures/two-individual-scales-applied.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":2,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":500,"y":0,"scale":1.5,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
set_applied_fixture "$test_root/fixtures/two-individual-scales-applied.json"
export MOCK_ACTIVEWINDOW_JSON='{}'
run_ok --set-scale 2
cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail 'scale change did not preserve the other monitor scale'
assert_no_workspace_dispatches
assert_focus_monitor A
grep -Fxq 'local omarchy_monitor_scale = 1' "$HOME/.config/hypr/monitors.lua" || fail 'individual scale change modified the global scale variable'
[[ $(<"$HOME/.config/hypr/monitors.lua") == *$'    scale = 2'* ]] || fail 'managed config did not persist the focused monitor scale'
[[ $(<"$HOME/.config/hypr/monitors.lua") == *$'    scale = 1.5'* ]] || fail 'managed config did not persist the other monitor scale'
managed_config=$(awk '/^-- BEGIN omarchy-display-order.display-order managed order$/{inside=1} inside{print} /^-- END omarchy-display-order.display-order managed order$/{inside=0}' "$HOME/.config/hypr/monitors.lua")
[[ $managed_config != *omarchy_monitor_scale* ]] || fail 'managed config still references the global scale variable'
pass 'set-scale changes only the focused scale and persists individual managed scales'

new_case "$test_root/fixtures/two-individual-scales.json"
run_ok --save-order A B
original_config=$(<"$HOME/.config/hypr/monitors.lua")
set_applied_fixture "$test_root/fixtures/two-individual-scales-applied.json"
export MOCK_LUAC_FAIL=1
run_fail --set-scale 2
[[ $LAST_OUTPUT == *'monitor config sync failed after scale apply'* ]] || fail 'scale config failure was not reported'
cmp -s -- "$MOCK_STATE" "$MOCK_ORIGINAL" || fail 'scale config failure did not restore live state'
[[ $(<"$HOME/.config/hypr/monitors.lua") == "$original_config" ]] || fail 'scale config failure changed monitors.lua'
rollback_monitor_line=$(awk '/^eval hl\.monitor/{count++; if (count == 2) {print NR; exit}}' "$MOCK_LOG")
autoreload_restore_line=$(awk '/disable_autoreload = false/{print NR; exit}' "$MOCK_LOG")
[[ -n $rollback_monitor_line && -n $autoreload_restore_line && $rollback_monitor_line -lt $autoreload_restore_line ]] || fail 'autoreload was restored before scale rollback completed'
assert_no_transaction_temps
pass 'individual scale persistence failure rolls back live state and config'

new_case "$test_root/fixtures/two-individual-scales.json"
run_ok --save-order A B
run_ok --sync-config
cat >"$test_root/fixtures/only-a.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":1,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}}
]
JSON
cp -- "$test_root/fixtures/only-a.json" "$MOCK_STATE"
cp -- "$test_root/fixtures/only-a.json" "$MOCK_ORIGINAL"
set_applied_fixture "$test_root/fixtures/only-a.json"
rm -f -- "$MOCK_STATE.eval-count" "$MOCK_STATE.monitor-queries"
: >"$MOCK_LOG"
cat >"$test_root/fixtures/only-a-applied.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":2,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}}
]
JSON
set_applied_fixture "$test_root/fixtures/only-a-applied.json"
run_ok --set-scale 2
managed_config=$(awk '/^-- BEGIN omarchy-display-order.display-order managed order$/{inside=1} inside{print} /^-- END omarchy-display-order.display-order managed order$/{inside=0}' "$HOME/.config/hypr/monitors.lua")
[[ $managed_config == *$'    output = "B",'* ]] || fail 'scale change discarded the disconnected monitor rule'
[[ $managed_config == *$'    scale = 1.5'* ]] || fail 'scale change discarded the disconnected monitor scale'
cat >"$test_root/fixtures/two-individual-scales-reconnected.json" <<'JSON'
[
  {"name":"A","width":1000,"height":800,"refreshRate":60,"x":0,"y":0,"scale":2,"transform":0,"focused":true,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":1}},
  {"name":"B","width":1000,"height":800,"refreshRate":60,"x":500,"y":0,"scale":1.5,"transform":0,"focused":false,"disabled":false,"mirrorOf":"none","activeWorkspace":{"id":2}}
]
JSON
cp -- "$test_root/fixtures/two-individual-scales-reconnected.json" "$MOCK_STATE"
rm -f -- "$MOCK_STATE.monitor-queries"
: >"$MOCK_LOG"
run_ok --sync-config
managed_config=$(awk '/^-- BEGIN omarchy-display-order.display-order managed order$/{inside=1} inside{print} /^-- END omarchy-display-order.display-order managed order$/{inside=0}' "$HOME/.config/hypr/monitors.lua")
[[ $managed_config == *$'    output = "B",'* && $managed_config == *$'    scale = 1.5'* ]] || fail 'reconnected monitor did not retain its individual scale'
pass 'scale changes preserve disconnected managed rules through reconnection'

new_case "$test_root/fixtures/two.json"
run_ok --save-order A B
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
set_applied_fixture "$test_root/fixtures/hotplug.json"
run_ok --apply-saved
[[ $LAST_OUTPUT == *'saved monitor is not currently eligible and will be skipped'* ]] || fail 'hotplug removal was not reported'
[[ $LAST_OUTPUT == *'newly eligible monitor appended'* ]] || fail 'hotplug addition was not reported'
pass 'hotplugged and disconnected monitors are handled without compositor state'

new_case "$test_root/fixtures/two.json"
run_ok --save-order B A
set_applied_fixture "$test_root/fixtures/two-reversed.json"
export HYPRLAND_INSTANCE_SIGNATURE=session-one
run_ok --startup-apply-saved
cmp -s -- "$MOCK_STATE" "$MOCK_APPLIED" || fail 'first startup claim did not apply the saved order'
assert_no_workspace_dispatches
[[ $(startup_claim_count) -eq 1 ]] || fail 'first startup did not create exactly one claim'
: >"$MOCK_LOG"
: >"$MOCK_WORKSPACE_LOG"
run_ok --startup-apply-saved
assert_mock_log_empty
assert_no_workspace_dispatches
[[ $(startup_claim_count) -eq 1 ]] || fail 'same startup signature created another claim'
pass 'the same Hyprland signature applies startup order only once'

cp -- "$MOCK_ORIGINAL" "$MOCK_STATE"
set_applied_fixture "$test_root/fixtures/two-reversed.json"
rm -f -- "$MOCK_STATE.eval-count" "$MOCK_STATE.monitor-queries"
: >"$MOCK_LOG"
: >"$MOCK_WORKSPACE_LOG"
export HYPRLAND_INSTANCE_SIGNATURE=session-two
run_ok --startup-apply-saved
assert_mock_log_has_eval
assert_no_workspace_dispatches
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
set_applied_fixture "$test_root/fixtures/two-reversed.json"
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
