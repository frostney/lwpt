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

The UTF-8 generator calls OpenSSL's PKCS#12 APIs directly so the passphrase
bytes match the server API instead of a shell locale. If OpenSSL 3 is not on
the dynamic-loader path, set `OPENSSL_CRYPTO_LIBRARY` to the absolute
`libcrypto` path before running it.

The `.cnf` files record the certificate extensions if the certificate chain
itself must be renewed. All keys and bundles are public test data, not
credentials. Never install the root in a trust store or use these identities
outside the test suite.
