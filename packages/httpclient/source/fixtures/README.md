# TLS server test identities

These throwaway identities exercise PKCS#12 loading and certificate-chain
delivery. The leaf has critical `CA:FALSE`, `serverAuth` extended-key usage,
and names `localhost` plus `127.0.0.1`. Its bundle carries the test
intermediate but not the root.

| Bundle | Passphrase | Purpose |
| --- | --- | --- |
| `localhost-test-identity.p12` | `test-only` | Normal server and chain tests |
| `localhost-empty-passphrase.p12` | empty | Empty-passphrase regression |
| `localhost-utf8-passphrase.p12` | `pässword` | UTF-8 passphrase regression |
| `localhost-future-identity.p12` | `test-only` | Strict validity-window rejection |
| `localhost-wrong-purpose-identity.p12` | `test-only` | Strict server-purpose rejection |
| `localhost-incoherent-identity.p12` | `test-only` | Strict bundled-chain rejection |
| `localhost-cycle-identity.p12` | `test-only` | Strict bundled certificate-cycle rejection |
| `localhost-leaf-ca-identity.p12` | `test-only` | Strict leaf `CA:FALSE` rejection |
| `localhost-non-ca-issuer-identity.p12` | `test-only` | Strict issuer `CA:TRUE` rejection |
| `localhost-no-certsign-identity.p12` | `test-only` | Strict issuer certificate-signing key-usage rejection |
| `localhost-pathlen-identity.p12` | `test-only` | Strict issuer path-length rejection |
| `localhost-self-signed-dev.p12` | `test-only` | Explicit permissive-development mode |

The committed PEM keys and certificates are the reproducible source material.
Regenerate the PKCS#12 bundles with OpenSSL 3 from this directory:

```sh
openssl pkcs12 -export -inkey localhost-test-leaf-key.pem \
  -in localhost-test-leaf-cert.pem \
  -certfile localhost-test-intermediate-cert.pem \
  -name localhost-test -passout pass:test-only \
  -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 \
  -out localhost-test-identity.p12
openssl pkcs12 -export -inkey localhost-test-leaf-key.pem \
  -in localhost-test-leaf-cert.pem \
  -certfile localhost-test-intermediate-cert.pem \
  -name localhost-empty-passphrase -passout pass: \
  -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 \
  -out localhost-empty-passphrase.p12
packages/httpclient/scripts/regenerate-utf8-pkcs12.pas
```

The strict-policy fixtures reuse the public test keys. Generate their CSRs and
certificates with OpenSSL 3, setting `LWPT_TLS_FIXTURE_ROOT` to this directory
and `LWPT_TLS_FIXTURE_STATE` to a private temporary directory containing an
empty `index.txt`, a writable `serial.txt`, and a `newcerts/` directory. The
`wrong-purpose-leaf.cnf`, `leaf-ca-true.cnf`, `issuer-ca-false.cnf`,
`issuer-no-certsign.cnf`, `root-pathlen-zero.cnf`, and `invalid-dates-ca.cnf`
define the invalid extensions and fixed future validity window. The invalid
issuer fixtures reuse the intermediate private key: one root-signed issuer
asserts `CA:FALSE`; another asserts `CA:TRUE` while omitting `keyCertSign`; each
matching leaf is signed by that same key. The path-length fixture uses the test
root key for a `pathlen:0` root, then bundles the intermediate it signs plus a
leaf below that intermediate. Package generated leafs with their matching
issuer chain as above; package the normal leaf with the test root to produce
the incoherent-chain bundle, and the test root certificate plus key to produce
the self-signed development bundle.

The cyclic bundle reuses the test intermediate key for Cycle A and the test
root key for Cycle B. Cycle A is signed by Cycle B, Cycle B is signed by Cycle
A, and the leaf is signed by Cycle A; both CA certificates are included in the
PKCS#12 bundle. This pins cycle rejection without relying on system trust.

The UTF-8 generator calls OpenSSL's PKCS#12 APIs directly so the passphrase
bytes match the server API instead of a shell locale. If OpenSSL 3 is not on
the dynamic-loader path, set `OPENSSL_CRYPTO_LIBRARY` to the absolute
`libcrypto` path before running it.

The `.cnf` files record the certificate extensions if the certificate chain
itself must be renewed. All keys and bundles are public test data, not
credentials. Never install the root in a trust store or use these identities
outside the test suite.
