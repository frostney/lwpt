# Cascade process-tree cancellation through nested LWPT invocations

## Executive Summary

- **Unix cancellation combines process groups with self-pipe signal
  forwarding.** Minimal SIGTERM and SIGINT handlers write to a nonblocking
  pipe. A dedicated thread reaps every registered child group before
  re-delivering the signal, using an accelerated path when an ancestor
  forwarded the signal.
- **Windows cancellation combines console-control forwarding with nested Job
  Object termination.** A minimal Ctrl-C/Ctrl-Break callback wakes a dedicated
  thread, which terminates registered jobs before the LWPT process exits.
- **Cancellation completes only after the isolated tree is empty.** A
  successful SIGKILL or `TerminateJobObject` call is followed by a bounded
  membership poll and, on Windows, a direct process-exit barrier. Real API
  failures become scheduler failures after a best-effort direct-child fallback.
- **Nested LWPT completion is positively acknowledged.** A token-bound,
  versioned status-pipe protocol distinguishes a registered nested LWPT from
  an arbitrary child and reports reaped or failed teardown before the ancestor
  accepts cancellation as complete.

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

Forwarding is installed only on the `build` and `test` dispatch paths, before
either command can create a managed tree. Commands such as `--version`, help,
format, and install do not create the pipe or forwarding thread and cannot fail
because those resources are unavailable.

Every managed tree receives a random 128-bit channel token and two inherited
anonymous pipes. The child-to-parent status pipe carries one bounded
`LWPT-ACK/1` hello frame when a nested LWPT installs forwarding, then exactly
one terminal `REAPED` or `FAILED` frame during cancellation. Frames must match
the inherited token; unknown versions, tokens, and frame kinds do not register
a child. A process that never sends hello remains an arbitrary child and is
never ACK-gated. The parent-to-child pipe carries one bounded cancel frame with
the root-authored absolute monotonic descendant and acknowledgement deadlines.
On Unix this deadline frame accompanies SIGINT/SIGTERM propagation; on Windows
it is also the cooperative cancellation request. The channel is internal,
inherited only through the process tree, and introduces no manifest or public
command surface.

Unix process-tree cancellation sends SIGTERM to the process group, waits a
short grace period, sends SIGKILL if members remain, then polls
`kill(-pgid, 0)` until it returns ESRCH. EPERM proves that members still exist;
it is not treated as success. A bounded poll that expires is a cancellation
failure.

That graceful path applies to direct scheduler cancellation, including numeric
test bail and worker or build failure, and to an external signal received by a
top-level LWPT. A registered nested LWPT receives the cancel frame before its
process group receives SIGTERM. It immediately fans the same absolute
deadlines to all registered nested children, hard-kills arbitrary children,
and acknowledges its direct parent only after every owned tree and descendant
ACK succeeds. A missing, failed, or late ACK makes the owner SIGKILL the group
and report cancellation failure. Per-tree locks cover process state and signal
operations but not sleep intervals, so an ancestor request can pre-empt a
concurrent graceful cancellation.

On Windows, each direct child is created suspended and assigned to an
invocation-private Job Object before it resumes. Windows 8 introduced nested
jobs, allowing a child inherited from an enclosing LWPT or host job to join
the inner job. Windows 8 or later is therefore the minimum supported runtime
for this ownership model. A typed Windows state object owns the Job Object
handle and its assign, query, terminate, wait, and cleanup operations;
`TLWPTProcessTree` retains only orchestration and direct-child fallback.
Cancellation explicitly calls `TerminateJobObject`, polls
`JobObjectBasicAccountingInformation.ActiveProcesses` until zero, and waits
for the direct child's process handle to become signaled under the same
deadline. The accounting value is membership evidence, not a process-exit
completion barrier; returning before the handle is signaled can expose
`STILL_ACTIVE` and retained child file handles to the caller.
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` is not used: closing an ownership handle
after successful execution must not introduce cancellation semantics.

Windows installs a `SetConsoleCtrlHandler` callback on the same build/test
dispatch paths. Because Windows invokes the callback on an operating-system
thread, the callback only signals a Win32 event and returns handled. An
FPC-created forwarding thread performs registry traversal, Job Object
termination, reporting, and process exit. Both Ctrl-C and Ctrl-Break take this
path. The callback has no pipe, registry, allocation, or Job Object work.
For a registered nested LWPT, the owner writes the cancel frame through the
paired control pipe instead of immediately terminating its Job Object. The
nested control thread fans cancellation through its own jobs and writes the
terminal status frame. A missing, failed, or late terminal frame escalates to
`TerminateJobObject`. Nested console callbacks acknowledge the broadcast but
leave pipe, registry, and Job Object work to that control thread.

The root fixes the descendant-reap deadline at 100 ms and the ancestor ACK
deadline at 250 ms. Every level forwards those absolute `GetTickCount64`
values unchanged, so depth cannot restart either allowance. Each level fans
out before it waits, aggregating completion hop by hop. Hard escalation retains
the existing 3,000 ms membership/process-exit verification bound.

Only an already-empty group or job is a successful no-op. Permission errors,
unexpected membership-query errors, termination API failures, and bounded
reap timeouts are surfaced into the build or test scheduler's failure state.
LWPT also attempts to terminate the direct child before reporting such a
failure, providing a limited fallback without claiming the full tree is gone.
Direct cancellation errors are retained as build cancellation failures or test
`tjsWorkerError` states. Signal-forwarding cleanup attempts every registered
tree, reports the first real failure at that LWPT level, and exits unsuccessfully
instead of disguising the error as successful cleanup.

## Consequences

- A terminal Ctrl-C or Ctrl-Break, Unix SIGINT or SIGTERM, numeric test bail,
  worker failure, and ancestor cancellation all follow the same child-tree
  ownership contract.
- On Unix, a top-level signal permits one grace interval for nested LWPT to
  forward it; registered inner levels confirm descendant teardown before that
  outer grace expires.
- Scheduler cancellation can take the configured grace period plus a bounded
  reap interval. Returning earlier would reintroduce the file-handle and rerun
  race this contract prevents.
- Windows hosts older than Windows 8 are unsupported. An access-denied job
  assignment reports the nested-job requirement instead of silently running a
  child outside cancellation ownership.
- Closing a Windows Job Object after normal completion is now observationally
  equivalent to releasing bookkeeping; descendants are terminated only by an
  explicit cancellation request.
- Nested LWPT teardown failure is visible at every ownership boundary. Missing,
  malformed, token-mismatched, failed, and late acknowledgements fail closed
  and trigger owner-local hard escalation; arbitrary child programs retain the
  ordinary group/job cancellation path without an acknowledgement requirement.
