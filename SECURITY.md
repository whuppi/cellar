# Security Policy

Covers the `cellar` core (the Flutter front door has its own policy at [whuppi/cellar_flutter](https://github.com/whuppi/cellar_flutter/blob/dev/SECURITY.md)).

## Reporting a vulnerability

Report privately via [GitHub Security Advisories](https://github.com/whuppi/cellar/security/advisories/new). Do not open a public issue.

## What's in scope

- **The encryption seam misbehaving** — cellar ships no cryptography, but it routes bytes through the caller's `FileEncryptor`. If the pipeline ever writes plaintext where the configuration said encrypt, returns ciphertext as if it were plaintext instead of throwing `EncryptionKeyMissingError`, or skips chunk-MAC verification on a read path, that's a security report.

- **Tenant scoping leaks** — `keyPrefix` is a tenant boundary. Any operation that lets one scoped cellar read, list, or overwrite another scope's objects (other than the documented `wipePartition` cross-tenant wipe) is a security issue.

- **Key-grammar bypass** — the key validator exists to make path traversal impossible. A key or prefix that reaches the filesystem with `..`, absolute segments, or Windows-reserved names got past a security control.

## What's NOT in scope

- **Crashes or hangs from corrupted stored data** — these are bugs, not vulnerabilities. Report them as [regular issues](https://github.com/whuppi/cellar/issues).

- **The strength of your crypto** — cellar is bring-your-own-encryption; the cipher, key management, and key storage are the caller's. A weak `FileEncryptor` implementation is not a cellar vulnerability.

- **OS-level access to the storage directories** — cellar stores app-private data where the caller points it. An attacker with filesystem access to those directories is outside the model; at-rest protection is what the encryption seam is for.

- **Network attacks** — cellar makes no network requests; a remote backend you implement owns its own transport security.

## Operational notes (known, accepted)

- **CI runs Chrome with `--no-sandbox`** — standard for CI runners (no SUID sandbox available); only the repo's own test suites are ever loaded, and the runner is ephemeral.

- **Same-key concurrent writes are the caller's to serialize** — cellar takes no locks by design; a data race on one key corrupts that object only, and the atomic-write rule keeps crash-safety intact.

## Response

Valid reports are fixed and shipped as patch versions.
