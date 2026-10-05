# Install lock ownership and reclamation

## Status

Accepted on 2026-10-05 by the maintainer. Issue
[#384](https://github.com/frostney/lwpt/issues/384), milestone 0.8.0. Amends
[ADR-0018](0018-install-transaction-module.md), which kept the install lock
private to the install transaction module.

## Executive Summary

- `LWPT.InstallLock` owns `.lwpt/install.lock`. The install transaction and
  `lwpt repair` both take it, so repair recovers an interrupted install and
  sweeps `.lwpt/tmp/` only while no install can run.
- The file's existence remains the mutual exclusion (`O_CREAT|O_EXCL`;
  Windows `CREATE_NEW`). A kernel record lock on the same file is the
  liveness signal: `fcntl` `F_SETLK` on byte 0 on Unix, `LockFileEx` on byte
  1024 on Windows.
- Repair takes over a lock file only when it can prove the owner dead: it
  holds the record lock, the file is still the one at the path, and the
  owner record says its owner held the record lock. Anything else fails with
  `EConcurrencyError`, changes nothing, and names the file to delete by hand
  once no install runs anywhere for the project.
- A filesystem without record locks fails closed for reclamation. Records
  written by 0.7.0 and earlier are never reclaimed automatically.

## Context

Before #384, `lwpt repair` deleted `.lwpt/install.lock` unconditionally,
then restored rollback snapshots and swept `.lwpt/tmp/` without holding it.
Run beside a live install, it removed that install's lock, let a second
install start, and rewrote committed state underneath both.

The lock's only content was the owner's PID. A PID cannot prove an owner
dead: `kill(pid, 0)` and `OpenProcess` answer only for the caller's PID
namespace and host, so a live owner in another container, or on another
client of a network filesystem, looks dead, and a reused PID makes a dead
owner look alive.

## Decision

### Ownership

`LWPT.InstallLock.TLWPTInstallLock` is the only code that creates, reads,
writes, or removes the lock file. `Create` (the install transaction) fails
fast with `EConcurrencyError` naming the recorded holder whenever the file
exists. `CreateReclaiming` (repair) takes the lock the same way when the
file is absent, and otherwise reclaims it only as described below. Repair
holds it around `RecoverInterruptedInstall` and the tmp sweep, and releases
it before the schema-v3 upgrade, whose install transaction takes it again.

### Acquisition

1. Create the file exclusively.
2. Take the record lock, waiting at most two seconds for a repair that is
   examining the file.
3. Check that the path still names the created file (`fstat` against
   `lstat`; on Windows, volume serial and file index). A file that was taken
   over, removed, or replaced meanwhile is not the owner's: it is closed
   without being removed and the command fails.
4. Write the owner record: the PID on line 1 (the only line older binaries
   read), `holder=install` or `holder=repair`, and `lock=record`. On a
   filesystem without record locks the owner proceeds, but omits
   `lock=record`.

Release removes the path, if it still names the owner's file, before the
record lock is released.

### Reclamation

Repair opens the existing file and waits at most 500 ms for its record lock.
It then refuses, changing nothing, when:

- the record lock is held: a live owner, named in the error;
- the filesystem keeps no record locks: nothing proves the owner dead, and
  nothing would keep a second repair out;
- locking fails for any other reason: the error and its code are reported;
- the record has no PID line: its creator may still be starting, and no age
  proves it died;
- the record lacks `lock=record`: written by 0.7.0 or earlier, or on a
  filesystem without record locks.

If its open file is no longer the one at the path, it starts over (at most
50 times). Otherwise the owner held the record lock when it wrote the record
and no longer holds it, so it has exited, whatever process its PID names
now, including repair's own PID. Repair adopts the file in place: it
rewrites the owner record while holding the record lock, so the path never
disappears and no install can create a lock meanwhile.

### Descriptor lifetime

`fcntl` record locks belong to the process, and closing any descriptor of
the file in that process releases them. A process therefore registers each
install-lock path before it opens the file, refuses a second acquisition of
a registered path before opening anything, and reads and writes the owner
record only through the locked descriptor. Diagnostic reads by a failing
contender use a read-only open in a process that holds no lock on that
path. Windows byte-range locks belong to the handle, so the identity check's
second handle is harmless there.

Every open of the lock file is a plain `open(2)` (`OpenProtectedDescriptor`),
never `SysUtils.FileOpen` or `TFileStream`, which take `flock(2)`. On Darwin
`flock` and `fcntl` locks share one lock list, so a `flock` on a held lock
file fails with `EAGAIN`; on Linux they are independent. Readers of a lock
file in tests follow the same rule. LWPT 0.7.0 is unaffected: its install
read the holder's PID through a plain `open(2)`, and its repair never opened
the file.

### Compatibility boundary

- 0.7.0 `lwpt repair` still deletes the lock file unconditionally; nothing
  in a newer binary can stop it. Do not run an older repair beside a newer
  install.
- A record without `lock=record` is never reclaimed. Once no install or
  repair runs anywhere for the project, including other hosts and
  containers sharing it, delete `.lwpt/install.lock` by hand and run
  `lwpt repair`.
- A lock file without an owner record (a creator that died in the
  microseconds between creating the file and writing its record) needs the
  same manual step.

## Considered options

- **PID liveness, with a start time to detect reuse.** Rejected: neither a
  PID nor a start time identifies a process across PID namespaces or hosts,
  and the start-time query differs on every platform.
- **Age-based reclamation of a file without an owner record.** Rejected: an
  age cannot prove that a creator died, and a delayed creator would then
  lock an unlinked file and run beside the next owner.
- **Delete and recreate a dead owner's file.** Rejected: between the delete
  and the create an install can take the lock, and a second repair can
  delete the new file. Adoption under the record lock has no such gap.
- **`flock` instead of `fcntl`.** Rejected: a `flock` is inherited by child
  processes and would outlive a crashed owner in a surviving child, and
  LWPT's other OS-held guards already use `fcntl`.

## Consequences

- Repair is safe to run at any time: against a live install or another
  repair it fails fast and changes nothing.
- Some crash residue needs a manual step: 0.7.0 records, records on
  filesystems without record locks, and files without an owner record. The
  error names the file and the precondition.
- The install lock is no longer an implementation detail of `LWPT.Install`;
  ADR-0018's "Lock is implementation detail" consequence is amended
  accordingly.
- `LWPT_TEST_HOLD_INSTALL_LOCK`, `LWPT_TEST_PAUSE_BEFORE_RECORD_LOCK`,
  `LWPT_TEST_RECORD_LOCK_UNSUPPORTED`, and `LWPT_TEST_RECORD_OWN_PID` exist
  only in the test build ([ADR-0044](0044-test-seams-only-in-test-builds.md)).
