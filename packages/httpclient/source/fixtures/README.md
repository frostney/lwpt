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
| `localhost-wrong-purpose-identity.p12` | `test-only` | Rejection of a leaf with `clientAuth` instead of `serverAuth` |
| `localhost-incoherent-identity.p12` | `test-only` | Rejection of a leaf bundled with an unrelated root |
| `localhost-cycle-identity.p12` | `test-only` | Strict bundled certificate-cycle rejection |
| `localhost-leaf-ca-identity.p12` | `test-only` | Rejection of a leaf with `CA:TRUE` |
| `localhost-no-basic-constraints-identity.p12` | `test-only` | Conformant strict leaf without basic constraints |
| `localhost-non-ca-issuer-identity.p12` | `test-only` | Rejection of an issuer with `CA:FALSE` |
| `localhost-no-certsign-identity.p12` | `test-only` | Rejection of an issuer whose key usage omits `keyCertSign` |
| `localhost-pathlen-identity.p12` | `test-only` | Rejection of an intermediate below a `pathlen:0` root |
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
certificates with OpenSSL 3. The fixed future fixture must retain the exact
`2040-01-01T00:00:00Z` through `2041-01-01T00:00:00Z` validity window. From the
repository root, prepare private CA state and reproduce the future,
wrong-purpose, and no-basic-constraints leaf certificates as follows:

```sh
FIXTURE_ROOT="$PWD/packages/httpclient/source/fixtures"
FIXTURE_STATE="$(mktemp -d)"
export LWPT_TLS_FIXTURE_ROOT="$FIXTURE_ROOT"
export LWPT_TLS_FIXTURE_STATE="$FIXTURE_STATE"
mkdir "$FIXTURE_STATE/newcerts"
: > "$FIXTURE_STATE/index.txt"
printf '5000\n' > "$FIXTURE_STATE/serial.txt"

openssl req -new -key "$FIXTURE_ROOT/localhost-test-leaf-key.pem" \
  -subj /CN=localhost -out "$FIXTURE_STATE/localhost.csr"
openssl ca -batch -config "$FIXTURE_ROOT/invalid-dates-ca.cnf" \
  -extensions leaf_extensions -startdate 20400101000000Z \
  -enddate 20410101000000Z -in "$FIXTURE_STATE/localhost.csr" \
  -out "$FIXTURE_ROOT/localhost-future-leaf-cert.pem"
openssl x509 -req -in "$FIXTURE_STATE/localhost.csr" \
  -CA "$FIXTURE_ROOT/localhost-test-intermediate-cert.pem" \
  -CAkey "$FIXTURE_ROOT/localhost-test-intermediate-key.pem" \
  -set_serial 0x5001 -days 3650 -sha256 \
  -extfile "$FIXTURE_ROOT/wrong-purpose-leaf.cnf" \
  -extensions leaf_extensions \
  -out "$FIXTURE_ROOT/localhost-wrong-purpose-leaf-cert.pem"

: > "$FIXTURE_STATE/index.txt"
printf '5002\n' > "$FIXTURE_STATE/serial.txt"
openssl ca -batch \
  -config "$FIXTURE_ROOT/leaf-no-basic-constraints-ca.cnf" \
  -extensions leaf_extensions -days 3650 \
  -in "$FIXTURE_STATE/localhost.csr" \
  -out "$FIXTURE_ROOT/localhost-no-basic-constraints-leaf-cert.pem"
```

The other configuration files record the certificate extension selections.
The invalid issuer fixtures reuse the intermediate private key: one root-signed
issuer asserts `CA:FALSE`; another asserts `CA:TRUE` while omitting
`keyCertSign`; each matching leaf certificate is signed by that same key. The
path-length fixture uses the test root key for a `pathlen:0` root, then bundles
the intermediate it signs plus a leaf certificate below that intermediate.
Package generated leaf certificates with their matching issuer chain; package
the normal leaf certificate with the test root to produce the incoherent-chain
bundle, and the test root certificate plus key to produce the self-signed
development bundle.

When a committed PEM approaches expiry, renew it with a 3650-day window. Use
`openssl req -new` with the listed configuration to create each CSR, then use
`openssl x509 -req -days 3650 -sha256 -extfile <config> -extensions <section>`
with the listed signer. Regenerate from root or issuer to leaf so every
signature in the bundle matches:

| Bundle | Leaf configuration and signer | Bundled issuer configuration and signer |
| --- | --- | --- |
| `localhost-leaf-ca-identity.p12` | `leaf-ca-true.cnf` / test intermediate | Existing test intermediate |
| `localhost-no-certsign-identity.p12` | `leaf.cnf` / no-certsign issuer | `issuer-no-certsign.cnf` / test root |
| `localhost-non-ca-issuer-identity.p12` | `leaf.cnf` / non-CA issuer | `issuer-ca-false.cnf` / test root |
| `localhost-pathlen-identity.p12` | `leaf.cnf` / path-length intermediate | `intermediate.cnf` / `root-pathlen-zero.cnf` root |
| `localhost-self-signed-dev.p12` | `root.cnf` self-signed with the test root key | None |
| `localhost-wrong-purpose-identity.p12` | `wrong-purpose-leaf.cnf` / test intermediate | Existing test intermediate |

For self-signed roots, replace `openssl x509 -req` with
`openssl req -new -x509 -days 3650 -sha256`, using the configuration's
`x509_extensions` section. The public test keys are intentionally reused; set
explicit, unique serials with `-set_serial` whenever `openssl x509 -req` signs
a certificate.

Regenerate the strict PKCS#12 bundles from their committed PEM source material
with passphrase `test-only`:

```sh
FIXTURE_ROOT="${FIXTURE_ROOT:-$PWD/packages/httpclient/source/fixtures}"
cd "$FIXTURE_ROOT"
bundle() {
  output="$1"; leaf="$2"; chain="$3"
  if [ "$chain" = - ]; then
    openssl pkcs12 -export -inkey localhost-test-leaf-key.pem -in "$leaf" \
      -name "$output" -passout pass:test-only -out "$output"
  else
    openssl pkcs12 -export -inkey localhost-test-leaf-key.pem -in "$leaf" \
      -certfile "$chain" -name "$output" -passout pass:test-only \
      -out "$output"
  fi
}
bundle localhost-leaf-ca-identity.p12 localhost-leaf-ca-cert.pem \
  localhost-test-intermediate-cert.pem
bundle localhost-no-basic-constraints-identity.p12 \
  localhost-no-basic-constraints-leaf-cert.pem \
  localhost-test-intermediate-cert.pem
bundle localhost-no-certsign-identity.p12 \
  localhost-no-certsign-leaf-cert.pem localhost-no-certsign-issuer-cert.pem
bundle localhost-non-ca-issuer-identity.p12 \
  localhost-non-ca-issuer-leaf-cert.pem localhost-non-ca-issuer-cert.pem
bundle localhost-pathlen-identity.p12 localhost-pathlen-leaf-cert.pem \
  localhost-pathlen-intermediate-cert.pem
bundle localhost-wrong-purpose-identity.p12 \
  localhost-wrong-purpose-leaf-cert.pem localhost-test-intermediate-cert.pem
openssl pkcs12 -export -inkey test-root-key.pem -in test-root-cert.pem \
  -name localhost-self-signed-dev -passout pass:test-only \
  -out localhost-self-signed-dev.p12
```

After regeneration, confirm that every ordinary strict-policy fixture remains
valid for at least five years. The intentionally future-dated fixture is
excluded from this check:

```sh
FIXTURE_ROOT="${FIXTURE_ROOT:-$PWD/packages/httpclient/source/fixtures}"
cd "$FIXTURE_ROOT"
for bundle in localhost-leaf-ca-identity.p12 \
  localhost-no-basic-constraints-identity.p12 \
  localhost-no-certsign-identity.p12 \
  localhost-non-ca-issuer-identity.p12 localhost-pathlen-identity.p12 \
  localhost-self-signed-dev.p12 localhost-wrong-purpose-identity.p12; do
  openssl pkcs12 -in "$bundle" -passin pass:test-only -clcerts -nokeys | \
    openssl x509 -noout -dates -checkend 157680000
done
```

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
