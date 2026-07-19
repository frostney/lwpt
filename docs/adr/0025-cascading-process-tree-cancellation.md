# Cascade process-tree cancellation through nested LWPT invocations

## Executive Summary

- **Unix cancellation combines process groups with self-pipe signal
  forwarding.** Minimal SIGTERM and SIGINT handlers write to a nonblocking
  pipe; a dedicated thread terminates every registered child group, then
  re-delivers the original signal with its default disposition.
- **Windows cancellation uses explicit nested Job Object termination.** LWPT
  requires Windows 8 or later so a child can retain its enclosing job
  membership while joining an invocation-private inner job.
- **Cancellation completes only after the isolated tree is empty.** A
  successful SIGKILL or `TerminateJobObject` call is followed by a bounded
  membership poll; real API failures become scheduler failures after a
  best-effort direct-child fallback.

LWPT schedulers isolate each direct compiler or test process so cancellation
can terminate that process and the descendants it launches. A nested LWPT
invocation creates another isolation boundary for its own compiler. An outer
process-group signal cannot cross that boundary on Unix, so stopping only the
outer group can leave the nested compiler running after its scheduler dies.

## Considered options

- **Put all descendants in one ancestor-owned process group.** Rejected. A
  nested scheduler cannot safely assume ownership of or join a group created
  by an arbitrary parent, and the approach does not map to independently owned
  Windows jobs.
- **Walk the operating-system process table recursively.** Rejected. Parent
  relationships race with exit and re-parenting, permissions vary, and there
  is no portable snapshot that supplies the required ownership guarantee.
- **Forward termination at every LWPT boundary.** Chosen. Each invocation owns
  only its direct process trees and propagates cancellation through nested
  invocations, producing a top-down cascade without weakening isolation.

## Decision

`TLWPTProcessTree` lives in `LWPT.ProcessTree`, separate from the platform
identity table in `Platform`. Every successfully executing tree is represented
in a process-wide registry protected by an RTL critical section. Registration
begins immediately before process creation and is coordinated with a per-tree
termination lock, closing the interval in which a signal could arrive after a
child was spawned but before the registry could address its group or job.

On Unix, LWPT installs minimal SIGTERM and SIGINT handlers. The handler performs
one async-signal-safe `write` of the signal number to a nonblocking,
close-on-exec self-pipe; it does not take locks, allocate, raise exceptions,
sleep, or traverse the registry. A dedicated thread reads the pipe, holds the
registry stable, and invokes the ordinary bounded cancellation path for every
live tree. It then restores that signal's default disposition and sends the
same signal to the LWPT process, preserving shell-visible SIGINT/SIGTERM
behavior. The post-fork child hook restores default dispositions before
`exec`, so children do not inherit LWPT's forwarding policy during the fork
window; `exec` and close-on-exec finish that separation.

Unix process-tree cancellation sends SIGTERM to the process group, waits a
short grace period, sends SIGKILL if members remain, then polls
`kill(-pgid, 0)` until it returns ESRCH. EPERM proves that members still exist;
it is not treated as success. A bounded poll that expires is a cancellation
failure.

On Windows, each direct child is created suspended and assigned to an
invocation-private Job Object before it resumes. Windows 8 introduced nested
jobs, allowing a child inherited from an enclosing LWPT or host job to join
the inner job. Windows 8 or later is therefore the minimum supported runtime
for this ownership model. Cancellation explicitly calls `TerminateJobObject`
and polls `JobObjectBasicAccountingInformation.ActiveProcesses` until zero.
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is not used: closing an ownership handle
after successful execution must not introduce cancellation semantics.

Only an already-empty group or job is a successful no-op. Permission errors,
unexpected membership-query errors, termination API failures, and bounded
reap timeouts are surfaced into the build or test scheduler's failure state.
LWPT also attempts to terminate the direct child before reporting such a
failure, providing a limited fallback without claiming the full tree is gone.

## Consequences

- A terminal Ctrl-C, an explicit SIGTERM, numeric test bail, worker failure,
  and ancestor cancellation all follow the same child-tree ownership contract.
- Nested LWPT levels collapse from the outside inward: each signalled LWPT
  first reaps the process groups it owns, then exits under the original signal.
- Scheduler cancellation can take the configured grace period plus a bounded
  reap interval. Returning earlier would reintroduce the file-handle and rerun
  race this contract prevents.
- Windows hosts older than Windows 8 are unsupported. An access-denied job
  assignment reports the nested-job requirement instead of silently running a
  child outside cancellation ownership.
- Closing a Windows Job Object after normal completion is now observationally
  equivalent to releasing bookkeeping; descendants are terminated only by an
  explicit cancellation request.
