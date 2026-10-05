# Git-host fetch trust: destination policy and locked ref identity

> **Amended by [ADR-0051](./0051-registry-dependency-sources.md):** registry contacts are destinations too. Each registry request allows only the contact's own host, requires HTTPS, refuses non-global addresses, and follows no redirects, so a 3xx is a request-layer failure that advances to the next contact. Manifest-declared contacts are public-only under the same address rule; plain `http://localhost` is accepted only by the `lwpt-testing` build ([ADR-0044](./0044-test-seams-only-in-test-builds.md)). Archives are fetched only from the contact that produced the verified proof and must hash to the signed record's `archive` digest.
>
> **Lockfile schema v4 ([ADR-0052](./0052-lockfile-schema-v4-framed-tree-digest.md)):** the lock is now schema v4. `resolvedRefKind` is unchanged there; the references below to additive schema-v3 evidence and early schema-v3 locks describe the lock when this record was accepted.

## Executive Summary

- Every dependency request uses HTTPS on every hop, may reach only the hosts
  its source names, and must resolve to a globally reachable address on every
  hop. There is no exception for the root manifest, so self-hosted forges on
  private networks are currently unsupported.
- Addresses are classified in binary against the IANA special-purpose
  registries, and the classified address is the one dialled.
- A locked tag is immutable. If it moves, is re-published under another
  SemVer spelling, or is replaced by a branch, the install fails until
  `lwpt install --accept-moved-tags`. Branches keep moving.
- When the lock pins a commit or tag, a fresh download must reproduce the
  locked archive bytes, including when the ref listing fails and the lock is
  used as a fallback.

Issue [#303](https://github.com/frostney/lwpt/issues/303) found that a
Git-host dependency could resolve to content other than what its name and
lockfile suggest. Redirects were followed to any host. A tag that moved
upstream was silently re-pinned. A locked commit could acquire different
bytes without the lock noticing. This ADR records the trust rules that
`lwpt install`, its `add` / `remove` frontends, and `outdated` / `update`
apply to every outbound dependency request. Test-only seams are covered
separately by [ADR-0044](./0044-test-seams-only-in-test-builds.md).
Commit-SHA reachability (issue item 1) is outside this ADR.

## Destination policy

`packages/httpclient` gained a per-request `THTTPRequestOptions.Destination`
(package 0.5.0). It is applied to the initial request and to every redirect
hop in a fixed order:

1. **Scheme.** With `RequireHTTPS`, any hop that is not `https` is refused,
   so a redirect cannot downgrade to plaintext.
2. **Host.** `AllowedHosts` is a case-insensitive exact allowlist. It is
   checked before any name resolution, so a refused host causes no DNS
   lookup and no connection.
3. **Address.** The host is parsed as an address literal or resolved once
   into a binary IPv4 address. Every IPv4-mapped, IPv4-compatible, and NAT64
   well-known-prefix spelling is rewritten to its embedded IPv4 address. The
   bytes are classified against named blocks transcribed from the IANA IPv4
   and IPv6 Special-Purpose Address Registries (entries whose "Globally
   Reachable" value is False or N/A), plus multicast, reserved, and all IPv6
   outside `2000::/3`. The registries' globally reachable exceptions, such as
   `192.0.0.9`, `192.0.0.10`, and the anycast and ORCHIDv2 blocks inside
   `2001::/23`, stay public. The connection dials exactly the classified
   address, and TLS still verifies the certificate against the host name. A
   policy-checked request never dials IPv6: a genuine IPv6 destination is
   refused.

`LWPT.FetchPolicy` derives each dependency's policy. Every network source
requires HTTPS and a globally reachable address on every hop:

| Source | Allowed hosts |
| --- | --- |
| `owner/repo`, `github:` | `github.com`, `codeload.github.com` |
| `gitlab:` | `gitlab.com` |
| `bitbucket:` | `bitbucket.org` |
| `[sources.<name>]` | Hosts of its `archive` and `git` templates |
| Direct `https://` URL | Any |

The address rule applies to every source, whichever manifest declares it.
Transitive manifests can declare `[sources]` tables and direct-URL
dependencies: the resolver passes each child manifest's custom sources along
with its requirements. A fetched package could otherwise make LWPT contact
services on the user's network. The maintainer chose one rule for all
sources over a root-manifest exception. Self-hosted forges and archive hosts
on private networks are currently unsupported. The follow-up is
[#313](https://github.com/frostney/lwpt/issues/313): an opt-in in user-level
configuration, never in a manifest, so a fetched package can never grant
itself private access. Until it lands, the denial above stays unconditional.

A custom-source template may not use `{ref}` in its host, because the
allowlist is derived from the templates before any ref is known. `{user}` and
`{repository}` may appear in the host and are rendered from the dependency's
locator. Built-in forge origins are defined once, in `LWPT.FetchPolicy`, and
URL construction and the allowlist both read them.

## Locked ref identity

The lock records `resolvedRefKind` (`tag` or `branch`) for every dependency
selected from a named Git ref. This is additive schema-v3 evidence, following
the `resolvedCommit` precedent in
[ADR-0031](./0031-fixed-point-single-version-resolution.md). The field is
omitted for SHA pins and non-Git sources, and for a named ref whose kind is
still unknown because its lock predates the field and it has been seen only
as a branch (see "Lock without `resolvedRefKind`" below).

When resolution selects the same ref name as the lock, the following rules
apply:

- **Tag moved.** The lock recorded a tag, and the host now advertises it at a
  different commit. The install fails, naming the dependency, the tag, and
  the old and new commits.
- **Equivalent SemVer spelling.** `v1.0.0` and `1.0.0` are the same tag, so a
  locked `v1.0.0` re-published as `1.0.0` at another commit is a moved tag.
- **Tag replaced by a branch.** The install fails, even at the same commit,
  because the ref would otherwise start moving silently.
- **Branch.** A locked branch may move, and a branch replaced by a same-named
  tag is accepted.
- **Tag and branch with one name.** When a tag and a branch share the
  selected name and commit, advertisement order does not decide the kind: a
  locked branch stays a branch, and otherwise the tag wins. A locked tag that
  is still advertised is therefore never reported as replaced.
- **Lock without `resolvedRefKind`.** A changed commit fails when the ref
  now resolves as a tag (a moved tag). It also fails when the ref resolves as
  a branch, because the lock cannot prove the ref was a branch. The failure
  is closed rather than open. Without `--accept-moved-tags`, an unknown kind
  is never promoted to `branch`: an install that sees a branch at the locked
  commit succeeds but keeps the kind unknown, so a later move still fails.
  Promotion to `tag` happens automatically, because it only tightens the
  rule.
- **Any requirement.** The rule applies whenever the same tag is selected
  again, even after the manifest requirement changed, for example from `^1.0`
  to exact `v1.2.3`. This is deliberately stronger than "only while the
  requirement is unchanged": a tag names one reviewed commit regardless of
  which requirement selects it.

Archive identity backs these rules and covers locks that record no commit.
When the lock pins the selected commit, a download must reproduce the lock's
`archiveHash`. The same applies when the lock has no `resolvedCommit` but
pins the same ref name. The check runs before the bytes are written, admitted
to the per-user cache, or extracted, on every path that supplies archive
bytes. That includes a resolver candidate fetched earlier in the same install
for another dependency naming the same source and commit, online or with
`--offline`, where the offline form refuses and points to an online install.
This covers:

- a locked commit whose forge now serves different bytes;
- another dependency aliasing the same repository and commit, whose fetch
  would otherwise be reused unchecked;
- the listing-failure fallback, which reuses the locked identity;
- a tag moved behind an early schema-v3 lock, reported as a moved tag.

Direct-URL archives are not verified this way; their content identity remains
the lock's `archiveHash` under `--frozen` and `--offline`.

`lwpt install --accept-moved-tags` is the single reviewed escape hatch. It
skips both checks for one online install, which then records the new
identity. The flag cannot be combined with `--frozen` or `--offline`, which
list no refs. `add`, `remove`, and `update` share the install transaction.
They refuse a moved ref and point to `lwpt install --accept-moved-tags`
instead of accepting it themselves.

## Considered options

- **Deny every non-global destination for every source.** *Chosen* by the
  maintainer. It is the simplest rule and closes the transitive pivot
  completely. The cost is that self-hosted forges on private networks are
  unsupported for now.
- **Trust the root manifest's own custom sources and direct URLs.** These
  would have been allowed to start on a private network, but never to move
  from a public hop to a private one. Transitive declarations would still
  have been denied. This keeps self-hosted forges working, but it adds a
  trust distinction to the resolver, and any manifest-level trust lets the
  project's own dependency graph widen it. Rejected.
- **A manifest-level opt-in naming permitted hosts or CIDRs.** Rejected for
  the same reason. Private access, when it lands, belongs to user-level
  configuration ([#313](https://github.com/frostney/lwpt/issues/313)).
- **Keep the textual classifier from GocciaScript's HTTPClient.** It missed
  expanded IPv4-mapped IPv6, several non-global IPv4 blocks, and most of
  `fe80::/10`, and a classified string could be resolved again at connect
  time. Rejected in favour of binary classification and dialling the exact
  classified address.
- **Infer ref kind from the current advertisement.** Rejected. It cannot
  tell a deleted tag replaced by a branch from a branch that moved.

## Consequences

- A dependency hosted on a private network, whether behind a custom source
  or a direct URL, fails to install with `fetch destination not allowed`.
- LWPT dials only IPv4 when a destination policy is active. An IPv6-only
  forge would need connect support first.
- Existing locks gain `resolvedRefKind = "tag"` on their next online install
  that sees a tag. A ref seen only as a branch keeps an unknown kind until
  one `--accept-moved-tags` records it, which a moved branch in such a lock
  requires anyway.
- A forge that regenerates archives for unchanged commits makes installs fail
  until the change is reviewed and accepted.
- The HTTPClient classifier helpers are test-only (`HTTPCLIENT_TESTING`).
  `HTTPURLHost` is the one new public helper, so the policy and the request
  share one URL parser.
