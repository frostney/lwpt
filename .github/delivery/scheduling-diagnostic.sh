#!/usr/bin/env bash
set -euo pipefail

poll_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_POLL_SECONDS:-5}"
poll_count="${LWPT_SCHEDULING_DIAGNOSTIC_POLL_COUNT:-18}"
sample_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_SAMPLE_SECONDS:-5}"
cleanup_grace_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_CLEANUP_GRACE_SECONDS:-2}"
scope="${LWPT_SCHEDULING_DIAGNOSTIC_SCOPE:-scheduling}"
pid_file="${RUNNER_TEMP:-/tmp}/TestScheduling.pids"
tree_pid_file="${RUNNER_TEMP:-/tmp}/TestScheduling-tree.pids"
lwpt_pid=0

collect_test_pids() {
  pgrep -f '[T]estScheduling.Test' > "$pid_file" || true
}

collect_process_tree_pids() {
  : > "$tree_pid_file"
  pending_pids="$lwpt_pid"
  while [ -n "$pending_pids" ]; do
    next_pids=""
    for process_pid in $pending_pids; do
      if kill -0 "$process_pid" 2>/dev/null; then
        echo "$process_pid" >> "$tree_pid_file"
        child_pids="$(pgrep -P "$process_pid" || true)"
        if [ -n "$child_pids" ]; then
          next_pids="$next_pids $child_pids"
        fi
      fi
    done
    pending_pids="$next_pids"
  done
}

terminate_probe() {
  owned_pid="$lwpt_pid"
  if [ "$owned_pid" -le 0 ]; then
    owned_pid="$(jobs -pr | tail -1 || true)"
  fi
  if [ -z "$owned_pid" ]; then return; fi
  collect_test_pids
  kill -TERM -- "-$owned_pid" 2>/dev/null \
    || kill -TERM "$owned_pid" 2>/dev/null || true
  sleep "$cleanup_grace_seconds"
  kill -KILL -- "-$owned_pid" 2>/dev/null \
    || kill -KILL "$owned_pid" 2>/dev/null || true
  wait "$owned_pid" 2>/dev/null || true
}

sample_probe() {
  collect_test_pids
  collect_process_tree_pids
  echo "[DEBUG-208] bounded process-tree capture"
  ps -axo pid,ppid,pgid,stat,etime,wchan,command \
    || ps -axo pid,ppid,pgid,stat,etime,command
  while IFS= read -r process_pid; do
    if [ -n "$process_pid" ]; then
      echo "[DEBUG-208] sampling PID $process_pid"
      sample "$process_pid" "$sample_seconds" 1 \
        -file "${RUNNER_TEMP:-/tmp}/TestScheduling-${process_pid}.sample.txt" \
        || true
      cat "${RUNNER_TEMP:-/tmp}/TestScheduling-${process_pid}.sample.txt" \
        || true
    fi
  done < "$tree_pid_file"
}

finish_if_complete() {
  if kill -0 "$lwpt_pid" 2>/dev/null; then
    process_state="$(ps -p "$lwpt_pid" -o stat= 2>/dev/null || true)"
    if [ -n "$process_state" ] && [[ "$process_state" != *Z* ]]; then
      return 1
    fi
  fi
  set +e
  wait "$lwpt_pid"
  result=$?
  set -e
  trap - EXIT INT TERM
  exit "$result"
}

trap terminate_probe EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$scope" in
  default)
    test_command=(
      /bin/bash -c
      './build/lwpt test --jobs=1 --bail=1 --verbose &&
       for _ in 1 2; do
         ./build/lwpt test tests/integration/TestScheduling.Test.pas \
           --jobs=1 --bail=1 --verbose || exit $?;
       done'
    )
    ;;
  scheduling)
    test_command=(
      ./build/lwpt test tests/integration/TestScheduling.Test.pas
    )
    ;;
  *) echo "unsupported scheduling diagnostic scope: $scope" >&2; exit 2 ;;
esac

python3 -c \
  'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
  "${test_command[@]}" \
  --jobs=1 --bail=1 --verbose &
lwpt_pid=$!

for _ in $(seq 1 "$poll_count"); do
  finish_if_complete || true
  sleep "$poll_seconds"
done

# The process may have exited during the final sleep. This check owns the
# deadline boundary and prevents a successful late completion being reported
# as a timeout.
finish_if_complete || true

echo "::error::$scope diagnostic exceeded its bounded runtime"
sample_probe
exit 1
