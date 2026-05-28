# HTTP registry spike — archived

This is a point-in-time snapshot of the HTTP registry consumer that lived
in the LWPT spike. The `skHttp` source kind was deferred to v2 per
[ADR-0004](../adr/0004-http-registry-deferred-to-v2.md); the v2
workstream will re-derive the consumer against a written spec rather
than carrying this unvalidated code forward.

This file is **not maintained**. It records what was removed and why,
and gives the v2 implementer a working sketch to study.

## What the spike implemented

A flat HTTP registry where each package published an index at:

```text
<registry>/<name>/index.toml
```

Shaped as:

```toml
versions = ["0.1.0", "0.2.0", "1.0.0", "1.1.0"]
```

LWPT would `GET` that index, filter by the dependency's semver range,
pick the highest satisfying version, then fetch:

```text
<registry>/<name>/<version>/<name>.tar.gz
```

…and extract it like any other source kind.

Manifest shape:

```toml
[dependencies]
some-lib = { version = "^1.2.0", source = "http",
             registry = "https://example.com/packages" }
# or the bare-string shorthand:
some-lib = "^1.2.0"   # implied source = "http", default registry
```

## Why it didn't ship in v1

1. **Never live-tested.** `PickFromIndex` was tested against in-memory
   `index.toml` fixtures; `NegotiateVersion` was never validated against
   a live HTTP server.
2. **No publishing tooling.** There was no `lwpt publish`, no spec for
   the `index.toml` shape, no example registry, no integrity model
   (sha256 in index? out-of-band? both?).
3. **Untested code rots.** Shipping the consumer without the publisher
   side means early adopters either roll their own registry (and the
   spec emerges by accident) or use a different source kind.
4. **A central registry is a permanent commitment.** Hosting,
   moderation, name-squatting policy, ownership transfer, takedowns,
   legal handling — none of which LWPT has funding or timeline for.

See ADR-0004 for the full reasoning.

## Removed code (verbatim from the spike's `LwptkCore.pas`)

### `skHttp` enum member

Removed from `TSourceKind`:

```pascal
TSourceKind = (skGitHub, skRelease, skHttp, skLocal);
```

Now `(skGitHub, skRelease, skLocal)`.

### `StrToSourceKind` — `'http'` branch

```pascal
else if S = 'http'    then Result := skHttp
```

Now raises `EManifestError` naming the deferral.

### Default source kind in `LoadManifest`

Manifests without an explicit `source` defaulted to `'http'`:

```pascal
D.SrcKind  := StrToSourceKind(TomlStr(DepNode, 'source', 'http'));
```

Now `source` is required for inline-table deps; bare-string shorthand
also raises `EManifestError` (it relied on the http default).

### `FetchURL` — `skHttp` branch

```pascal
skHttp:
  { negotiated: Version is the concrete version chosen from the index }
  Result := IncludeHTTPPathDelimiter(Dep.SrcSlug) +
            Dep.Name + '/' + Version + '/' + Dep.Name + '.tar.gz';
```

### `NegotiateVersion` — registry round-trip

```pascal
function NegotiateVersion(const Dep: TDependency): string;
var
  URL    : string;
  Resp   : THTTPResponse;
  NoHdr  : THTTPHeaders;
  Body   : string;
  i      : Integer;
begin
  URL := IncludeHTTPPathDelimiter(Dep.SrcSlug) + Dep.Name + '/index.toml';
  NoHdr := nil;
  Resp := HTTPGet(URL, NoHdr);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    raise Exception.CreateFmt(
      'registry index for "%s" not found: HTTP %d at %s',
      [Dep.Name, Resp.StatusCode, URL]);

  SetLength(Body, Length(Resp.Body));
  for i := 0 to High(Resp.Body) do
    Body[i + 1] := Chr(Resp.Body[i]);

  Result := PickFromIndex(Body, Dep.Range, Dep.Name);
end;
```

### `PickFromIndex` — version selection

```pascal
function PickFromIndex(const IndexBody, Range: string;
  const PkgName: string = 'package'): string;
var
  Reader : TTomlReader;
  Root, Arr : PTomlNode;
  i, n : Integer;
  Versions : array of string;
begin
  Result := '';
  Reader := TTomlReader.Create(IndexBody);
  try
    Root := Reader.Parse;
  finally
    Reader.Free;
  end;
  try
    Arr := TomlGet(Root, 'versions');
    if (Arr = nil) or (Arr^.Kind <> tkArray) then
      raise Exception.CreateFmt(
        'registry index for "%s" has no versions array', [PkgName]);

    { collect the published versions, hand them to the vendored semver
      port's MaxSatisfying — a full node-semver implementation, so this
      correctly handles prerelease tags, compound ranges and || unions }
    SetLength(Versions, 0);
    for i := 0 to High(Arr^.Children) do
      if Arr^.Children[i]^.Kind = tkStr then
      begin
        n := Length(Versions);
        SetLength(Versions, n + 1);
        Versions[n] := Arr^.Children[i]^.Str;
      end;

    Result := MaxSatisfying(Versions, Range, DefaultSemverOptions);
    if Result = '' then
      raise Exception.CreateFmt(
        'no version of "%s" satisfies range "%s"', [PkgName, Range]);
  finally
    FreeTomlNode(Root);
  end;
end;
```

### Resolver hook in `ResolveGraph` (removed branch)

```pascal
if Item.Dep.SrcRef <> '' then
  R.Nodes[idx].Version := Item.Dep.SrcRef
else if (Item.Dep.SrcKind = skHttp) and (not Offline) then
begin
  WriteLn('  negotiating ', Item.Dep.Name, ' ', Item.Dep.Range, ' ...');
  R.Nodes[idx].Version := NegotiateVersion(Item.Dep);
  WriteLn('    -> selected ', R.Nodes[idx].Version);
end
else
  R.Nodes[idx].Version := Item.Dep.Range;
```

Now: `else R.Nodes[idx].Version := Item.Dep.Range;` (the negotiation
branch is gone).

## What the v2 workstream needs to produce

1. **`docs/registry-spec.md`** — the authoritative spec for what a
   registry must serve:
   - URL layout (`<registry>/<name>/index.toml`,
     `<registry>/<name>/<version>/<name>.tar.gz`).
   - `index.toml` schema (versions array, optionally a per-version
     metadata table with sha256, dependencies, deprecation flag, etc.).
   - HTTP semantics (status codes, redirects, conditional GET, ETag).
   - Integrity model (sha256 in index vs. out-of-band).
2. **Re-derived consumer** (`NegotiateVersion`, `PickFromIndex`) against
   the spec, using `ELWPTError` and friends instead of bare `Exception`.
3. **Mock registry fixture** — a static `tests/fixtures/registry/`
   directory served by the test's mock HTTP server, to validate the
   consumer without standing up real infrastructure.
4. **Decide separately** whether to ship `lwpt publish` and/or stand up
   a central registry host. Either is a separate ADR.

## Migration for spike-era consumers

Any manifest using `source = "http"` or the bare-string shorthand
`pkg = "^1.0.0"` now fails with a clear error. Migrate to one of:

```toml
[dependencies]
horse  = { source = "github",   repo = "HashLoad/horse",  ref = "v3.0.0" }
horse  = { source = "gitlab",   repo = "owner/horse",     ref = "v3.0.0" }
horse  = { source = "bitbucket",repo = "owner/horse",     ref = "v3.0.0" }
asset  = { source = "release",  repo = "owner/repo",
           ref = "v1.0.0", asset = "package.tar.gz" }
local  = { source = "local",    path = "../local-pkg" }
```
