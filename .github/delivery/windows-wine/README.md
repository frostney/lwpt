# Local Win32 diagnostic

Run the repository's i386 Win32 compile and Wine smoke gate through the local
Docker-compatible engine (OrbStack on the maintainer Mac):

```sh
.github/delivery/windows-wine/run.sh
```

The first run downloads the pinned FPC 3.2.2 source archive, verifies its
SHA-256, builds the i386-win32 cross-toolchain, and initializes a reusable
32-bit Wine prefix. Docker layers and the named prefix volume make subsequent
runs local and cached. Build artifacts use a private temporary directory and
are removed when the command exits.

The gate cross-compiles the production binary and `TestScheduling.Test.exe`,
loads the PE binary under Wine, checks command dispatch, and proves the bounded
anonymous-pipe read/write capability probes used by process-tree channel
validation.

Wine 8 does not deliver this repository's `GenerateConsoleCtrlEvent` topology
through a `CREATE_NEW_CONSOLE` boundary. This gate therefore does not claim
the native Ctrl-C/Ctrl-Break callback and console-lifetime contract. Use it for
cheap Win32 compile, ABI, handle, and ordinary Wine-compatible diagnosis, then
run the focused scheduling test once on native Windows for final console proof.
