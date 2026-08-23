# Registry implementation fixtures

## Executive Summary

- `localhost-native-identity.p12` is a public test identity for the registry
  lifecycle E2E test, protected only by the test password `test-only`.
- Its leaf, intermediate, root, and private key derive from the committed
  HTTPClient test PKI. They are not credentials and must never be deployed.
- The bundle uses PKCS#12 algorithms accepted by Security.framework while its
  short-lived leaf satisfies Apple's native SSL server policy.

The leaf was issued from the committed HTTPClient intermediate with the
extensions in `packages/httpclient/source/fixtures/leaf.cnf`, a 397-day
validity period, and serial `0x7001`. The PKCS#12 bundle contains the leaf,
intermediate, and test root so native validation can use only the supplied
chain. Regenerate it when its leaf expires; keep the password and source PKI
test-only.
