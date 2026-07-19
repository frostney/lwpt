# TLS server test certificate

`localhost-test-cert.pem` and `localhost-test-key.pem` are a throwaway,
self-signed pair generated only for deterministic loopback TLS tests. The
certificate is valid for `localhost` and `127.0.0.1`; the private key is not a
credential and must never be used outside the test suite.
