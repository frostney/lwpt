#!/usr/bin/env bash
set -euo pipefail

poll_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_POLL_SECONDS:-5}"
poll_count="${LWPT_SCHEDULING_DIAGNOSTIC_POLL_COUNT:-30}"
sample_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_SAMPLE_SECONDS:-5}"
cleanup_grace_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_CLEANUP_GRACE_SECONDS:-2}"
scope="${LWPT_SCHEDULING_DIAGNOSTIC_SCOPE:-scheduling}"
tree_pid_file="${RUNNER_TEMP:-/tmp}/TestScheduling-tree.pids"
active_case_file="${RUNNER_TEMP:-/tmp}/TestScheduling-active-case.txt"
diagnostic_platform="${LWPT_SCHEDULING_DIAGNOSTIC_PLATFORM:-$(uname -s)}"
proc_root="${LWPT_SCHEDULING_DIAGNOSTIC_PROC_ROOT:-/proc}"
proc_read_seconds="${LWPT_SCHEDULING_DIAGNOSTIC_PROC_READ_SECONDS:-2}"
lwpt_pid=0

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
  kill -TERM -- "-$owned_pid" 2>/dev/null \
    || kill -TERM "$owned_pid" 2>/dev/null || true
  sleep "$cleanup_grace_seconds"
  kill -KILL -- "-$owned_pid" 2>/dev/null \
    || kill -KILL "$owned_pid" 2>/dev/null || true
  wait "$owned_pid" 2>/dev/null || true
}

capture_proc_file() {
  local capture_label="$1"
  local capture_path="$2"
  echo "[DEBUG-269] $capture_label"
  if [ -r "$capture_path" ]; then
    timeout "$proc_read_seconds" cat "$capture_path" || true
  else
    echo "unavailable: $capture_path"
  fi
}

capture_linux_process() {
  local process_pid="$1"
  local process_root="$proc_root/$process_pid"
  local task_pid
  local task_root
  capture_proc_file "PID $process_pid status" "$process_root/status"
  capture_proc_file "PID $process_pid wait channel" "$process_root/wchan"
  capture_proc_file "PID $process_pid syscall" "$process_root/syscall"
  echo "[DEBUG-269] PID $process_pid file descriptors"
  timeout "$proc_read_seconds" ls -la "$process_root/fd" 2>&1 || true
  for task_root in "$process_root"/task/[0-9]*; do
    if [ ! -d "$task_root" ]; then continue; fi
    task_pid="${task_root##*/}"
    capture_proc_file "PID $process_pid task $task_pid name" \
      "$task_root/comm"
    capture_proc_file "PID $process_pid task $task_pid status" \
      "$task_root/status"
    capture_proc_file "PID $process_pid task $task_pid wait channel" \
      "$task_root/wchan"
    capture_proc_file "PID $process_pid task $task_pid syscall" \
      "$task_root/syscall"
    capture_proc_file "PID $process_pid task $task_pid stack" \
      "$task_root/stack"
  done
}

sample_probe() {
  collect_process_tree_pids
  echo "[DEBUG-269] active test case"
  if [ -r "$active_case_file" ]; then
    cat "$active_case_file" || true
  else
    echo "unavailable: $active_case_file"
  fi
  echo "[DEBUG-269] bounded process-tree capture"
  ps -axo pid,ppid,pgid,stat,etime,wchan,command \
    || ps -axo pid,ppid,pgid,stat,etime,command
  while IFS= read -r process_pid; do
    if [ -z "$process_pid" ]; then continue; fi
    case "$diagnostic_platform" in
      Darwin)
        echo "[DEBUG-269] sampling PID $process_pid"
        sample "$process_pid" "$sample_seconds" 1 \
          -file "${RUNNER_TEMP:-/tmp}/TestScheduling-${process_pid}.sample.txt" \
          || true
        cat "${RUNNER_TEMP:-/tmp}/TestScheduling-${process_pid}.sample.txt" \
          || true
        ;;
      Linux) capture_linux_process "$process_pid" ;;
      *) echo "[DEBUG-269] unsupported sampling platform: $diagnostic_platform" ;;
    esac
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
      './build/lwpt test
         "source/*.Test.pas"
         "packages/*/source/*.Test.pas"
         "tests/integration/*.Test.pas"
         --jobs=1 --bail=1 --verbose &&
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

rm -f "$active_case_file"
TESTING_PASCAL_LIBRARY_ACTIVE_CASE_FILE="$active_case_file" python3 -c \
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
