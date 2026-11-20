#!/usr/bin/env bash
# tests/fm-watch-check-interval.test.sh - the per-check cadence in bin/fm-watch.sh
# (state/<id>.check-interval, docs/configuration.md "Per-check interval") and the
# bin/fm-check-register.sh --interval and bin/fm-check-unregister.sh cleanup
# that go with it. Real watcher processes run registered custom checks that
# only append to a counter file, so a run is observable without a wake ending
# the watcher.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

REGISTER="$ROOT/bin/fm-check-register.sh"
UNREGISTER="$ROOT/bin/fm-check-unregister.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-check-interval)

# add_counting_check <state> <id> [output]: a registered custom check that
# appends one line to <state>/<id>.runs per run and prints <output> when given.
add_counting_check() {
  local state=$1 id=$2 output=${3:-}
  {
    printf '#!/usr/bin/env bash\n'
    printf 'date +%%s >> %q\n' "$state/$id.runs"
    [ -z "$output" ] || printf 'echo %q\n' "$output"
  } > "$state/$id.check.sh"
  chmod 0700 "$state/$id.check.sh"
  FM_STATE_OVERRIDE="$state" "$REGISTER" "$id" >/dev/null \
    || fail "could not register custom check $id"
}

runs_of() {  # <state> <id>
  local n=0
  [ ! -f "$1/$2.runs" ] || n=$(wc -l < "$1/$2.runs" | tr -d '[:space:]')
  printf '%s\n' "$n"
}

# The watcher does bounded startup work before its first poll, so every wait
# below is on an observed event with a generous deadline, never a fixed sleep.
wait_runs() {  # <state> <id> <count> [limit-ticks]
  local state=$1 id=$2 want=$3 limit=${4:-600} i=0
  while [ "$i" -lt "$limit" ]; do
    [ "$(runs_of "$state" "$id")" -lt "$want" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Let <n> whole poll cycles complete; 1 if the watcher exited meanwhile.
settle_cycles() {  # <state> <pid> <n>
  local state=$1 pid=$2 n=$3 i=0
  while [ "$i" -lt "$n" ]; do
    wait_poll_cycle "$state" "$pid" || return 1
    i=$((i + 1))
  done
}

# Smallest gap in seconds between consecutive run stamps of <id>.
min_run_gap() {  # <state> <id>
  awk 'NR > 1 { g = $1 - prev; if (min == "" || g < min) min = g } { prev = $1 } END { print min }' "$1/$2.runs"
}

# Hold the shared sweep off: it is due whenever .last-check is missing or old.
hold_shared_sweep() {  # <state>
  touch "$1/.last-check"
}

test_fast_check_runs_within_its_interval_and_default_check_does_not() {
  local dir state fakebin out pid before after gap
  dir=$(make_case fast-vs-default); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_counting_check "$state" fast
  add_counting_check "$state" slow
  printf '2\n' > "$state/fast.check-interval"
  hold_shared_sweep "$state"
  before=$(file_mtime "$state/.last-check")
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_runs "$state" fast 3; then
    reap "$pid"; fail "a 2s per-check interval did not run the check 3 times: $(cat "$out")"
  fi
  settle_cycles "$state" "$pid" 2 || { reap "$pid"; fail "watcher exited on a silent check: $(cat "$out")"; }
  gap=$(min_run_gap "$state" fast)
  after=$(file_mtime "$state/.last-check")
  reap "$pid"
  [ "$gap" -ge 2 ] || fail "the fast check ran $gap s after its previous run, inside its 2s interval"
  [ "$(runs_of "$state" slow)" -eq 0 ] || fail "the default-cadence check ran while the shared sweep was not due"
  [ "$before" = "$after" ] || fail "the fast check moved .last-check, which would change the shared cadence"
  [ ! -s "$out" ] || fail "a silent fast check produced a wake: $(cat "$out")"
  pass "a check with its own interval runs on it while a default-cadence check and .last-check stay put"
}

test_fast_check_output_wakes_in_the_shared_format() {
  local dir state fakebin out pid
  dir=$(make_case fast-wake); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_counting_check "$state" ask 'question waiting'
  printf '2\n' > "$state/ask.check-interval"
  hold_shared_sweep "$state"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 300 || true
  grep -qxF "check: $state/ask.check.sh: question waiting" "$out" \
    || fail "fast check output did not wake in the shared check format: $(cat "$out")"
  pass "a fast check's output wakes with the same reason line a shared check uses"
}

test_missing_or_invalid_interval_keeps_the_shared_cadence() {
  local dir state fakebin out pid value i=0
  for value in abc 0 -5 1.5 ''; do
    i=$((i + 1))
    dir=$(make_case "invalid-interval-$i"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
    add_counting_check "$state" bad
    printf '%s\n' "$value" > "$state/bad.check-interval"
    # The shared sweep is due at startup (no .last-check), then not again.
    watch_bg "$state" "$fakebin" "$out"
    pid=$!
    if ! wait_runs "$state" bad 1; then
      reap "$pid"; fail "interval '$value' kept the check from the shared sweep"
    fi
    settle_cycles "$state" "$pid" 3 || { reap "$pid"; fail "watcher exited on a silent check: $(cat "$out")"; }
    reap "$pid"
    [ "$(runs_of "$state" bad)" -eq 1 ] \
      || fail "interval '$value' ran the check $(runs_of "$state" bad) times; the shared cadence runs it once"
    [ "$(grep -c 'ignoring invalid per-check interval for bad' "$state/.watch-triage.log")" -eq 1 ] \
      || fail "interval '$value' was not logged exactly once: $(cat "$state/.watch-triage.log" 2>/dev/null)"
  done
  dir=$(make_case missing-interval); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_counting_check "$state" plain
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_runs "$state" plain 1; then
    reap "$pid"; fail "a check with no interval file did not run on the shared sweep"
  fi
  settle_cycles "$state" "$pid" 3 || { reap "$pid"; fail "watcher exited on a silent check: $(cat "$out")"; }
  reap "$pid"
  [ "$(runs_of "$state" plain)" -eq 1 ] || fail "a check with no interval file did not keep the shared cadence"
  [ ! -e "$state/plain.check-last" ] || fail "a check with no interval file gained a per-check timestamp"
  pass "a missing, zero, negative, fractional, empty, or non-numeric interval keeps the shared cadence, logged once"
}

test_interval_is_floored_at_the_poll_and_read_per_cycle() {
  local dir state fakebin out pid
  dir=$(make_case floor-and-reload); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_counting_check "$state" fast
  hold_shared_sweep "$state"
  # Not a fast check yet, and the shared sweep is held off, so nothing runs.
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  settle_cycles "$state" "$pid" 3 || { reap "$pid"; fail "watcher exited on a silent check: $(cat "$out")"; }
  [ "$(runs_of "$state" fast)" -eq 0 ] || { reap "$pid"; fail "the check ran before it had an interval"; }
  # Written while the watcher runs, and below the 1s poll: picked up with no
  # restart, and floored at the poll, so it still never runs twice in a second.
  printf '1\n' > "$state/fast.check-interval"
  if ! wait_runs "$state" fast 3; then
    reap "$pid"; fail "an interval written to a running watcher was not picked up"
  fi
  reap "$pid"
  [ "$(min_run_gap "$state" fast)" -ge 1 ] || fail "a 1s interval ran the check twice within a second"
  pass "the interval is read every cycle, so a running watcher picks it up with no restart"
}

test_shared_sweep_does_not_rerun_a_fast_check() {
  local dir state fakebin out pid
  dir=$(make_case no-double-run); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_counting_check "$state" fast
  add_counting_check "$state" slow
  printf '999\n' > "$state/fast.check-interval"
  # No .last-check: the shared sweep is due at startup alongside the fast check.
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_runs "$state" slow 1 || ! wait_runs "$state" fast 1; then
    reap "$pid"; fail "the startup sweep did not run both checks"
  fi
  settle_cycles "$state" "$pid" 3 || { reap "$pid"; fail "watcher exited on a silent check: $(cat "$out")"; }
  reap "$pid"
  [ "$(runs_of "$state" fast)" -eq 1 ] || fail "the fast check ran $(runs_of "$state" fast) times at startup, expected once"
  [ "$(runs_of "$state" slow)" -eq 1 ] || fail "the shared sweep ran the default-cadence check $(runs_of "$state" slow) times"
  pass "a due shared sweep runs the default-cadence check and leaves the fast check to its own timer"
}

test_changed_fast_check_is_not_run() {
  local dir state fakebin out pid
  dir=$(make_case changed-bytes); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  add_counting_check "$state" fast
  printf '2\n' > "$state/fast.check-interval"
  hold_shared_sweep "$state"
  # Edited after registration: its trust binding no longer matches.
  printf '#!/usr/bin/env bash\necho tampered >> %q\n' "$state/fast.runs" > "$state/fast.check.sh"
  chmod 0700 "$state/fast.check.sh"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  settle_cycles "$state" "$pid" 4 || { reap "$pid"; fail "watcher exited: $(cat "$out")"; }
  reap "$pid"
  [ "$(runs_of "$state" fast)" -eq 0 ] || fail "a fast check whose bytes changed after registration still ran"
  pass "a fast check is held to the same trust binding as any custom check"
}

test_register_records_and_unregister_cleans_up() {
  local dir state rc
  dir=$(make_case register-cleanup); state="$dir/state"
  add_counting_check "$state" fast
  FM_STATE_OVERRIDE="$state" "$REGISTER" fast --interval 30 >/dev/null || fail "register --interval 30 failed"
  [ "$(cat "$state/fast.check-interval")" = 30 ] || fail "register did not record the interval"
  [ "$(file_mtime "$state/fast.check-interval")" ] || fail "interval file missing"
  for rc in 0 abc -3 1.5 ''; do
    if FM_STATE_OVERRIDE="$state" "$REGISTER" fast --interval "$rc" >/dev/null 2>&1; then
      fail "register accepted --interval '$rc'"
    fi
  done
  [ "$(cat "$state/fast.check-interval")" = 30 ] || fail "a refused registration changed the recorded interval"
  if FM_STATE_OVERRIDE="$state" "$REGISTER" fast --every 30 >/dev/null 2>&1; then
    fail "register accepted an unknown option"
  fi
  touch "$state/fast.check-last"
  FM_STATE_OVERRIDE="$state" "$UNREGISTER" fast >/dev/null || fail "unregister failed"
  for rc in check.sh check-trust check-interval check-last; do
    [ ! -e "$state/fast.$rc" ] || fail "unregister left state/fast.$rc behind"
  done
  pass "register --interval validates and records the cadence, and unregister removes it with the check"
}

test_unregister_refuses_an_unsafe_interval_artifact() {
  local dir state rc=0
  dir=$(make_case unsafe-interval); state="$dir/state"
  add_counting_check "$state" fast
  printf '30\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/fast.check-interval"
  FM_STATE_OVERRIDE="$state" "$UNREGISTER" fast >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "unregister followed a symlinked interval file"
  [ -e "$dir/elsewhere" ] || fail "unregister removed a symlink's target"
  [ -e "$state/fast.check.sh" ] || fail "a refused unregister still removed the check"
  pass "unregister refuses a symlinked interval file and removes nothing"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

fm_test_run \
  test_fast_check_runs_within_its_interval_and_default_check_does_not \
  test_fast_check_output_wakes_in_the_shared_format \
  test_missing_or_invalid_interval_keeps_the_shared_cadence \
  test_interval_is_floored_at_the_poll_and_read_per_cycle \
  test_shared_sweep_does_not_rerun_a_fast_check \
  test_changed_fast_check_is_not_run \
  test_register_records_and_unregister_cleans_up \
  test_unregister_refuses_an_unsafe_interval_artifact
