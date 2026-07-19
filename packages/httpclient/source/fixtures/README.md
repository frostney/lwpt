# TLS server test identity

`localhost-test-identity.p12` is a throwaway, self-signed PKCS#12 identity
generated only for deterministic in-memory TLS tests. Its passphrase is
`lwpt-test-only`. The leaf is valid for seven days, has critical `CA:FALSE`,
has only the `serverAuth` extended-key usage, and names `localhost` plus
`127.0.0.1`.

The bundle and its private key are public test data, not credentials. Never
install its certificate in a trust store or use the identity outside this test
suite.
