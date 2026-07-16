# linkcheck

`linkcheck` validates Markdown links without adding a new LWPT subcommand or a
second runtime. Its public API is one operation, `TLinkChecker.Check`, which
returns a deterministic `TLinkCheckReport` suitable for human or JSON output.

Offline mode is the default. It checks relative files, directory indexes, and
GitHub-style heading anchors, including duplicate-heading suffixes. Online mode
is explicit, accepts only HTTPS links, and uses a bounded worker count plus the
canonical `httpclient` package's request I/O timeout.

## Run from an LWPT manifest

Declare a root-owned run script after `lwpt install` has linked the workspace
package:

```toml
[links]
script = ".lwpt/modules/linkcheck/scripts/link-check.pas"
args = ["--root", ".", "--allowlist", ".linkcheck-allowlist"]

[links-online]
script = ".lwpt/modules/linkcheck/scripts/link-check.pas"
args = ["--root", ".", "--allowlist", ".linkcheck-allowlist",
        "--online", "--jobs", "4", "--timeout-ms", "10000"]

[links-json]
script = ".lwpt/modules/linkcheck/scripts/link-check.pas"
args = ["--root", ".", "--allowlist", ".linkcheck-allowlist",
        "--format", "json"]
```

Then run the offline check, or opt into network access:

```console
lwpt run links
lwpt run links-online
lwpt run links-json
```

The allowlist is UTF-8 text with one exact target and rationale per line,
separated by a tab. Blank lines and lines beginning with `#` are ignored.
Entries without a rationale are configuration errors; accepted exclusions are
reported rather than silently dropped.

```text
https://example.invalid/retired<TAB>Retained as historical documentation
```
