# Native dependencies

These integrations provide two primitives Apple does not expose in the required form. No dependency downloads or Node runtime are required by the iOS build. This is not a claim of an independent security audit.

| Dependency | Pinned source | Reason | License |
| --- | --- | --- | --- |
| Official BLAKE3 C 1.8.7 | https://github.com/BLAKE3-team/BLAKE3/tree/f55849f89cd85083c1c9daa2c5de20766f309c00/c | Exact Massa address and message hash; CryptoKit has no BLAKE3 | Upstream CC0 / Apache 2.0 alternatives included |
| libbase58 | https://github.com/luke-jr/libbase58/tree/b1dd03fa8d1be4be076bb6152325c6b5cf64f678 | Existing Base58Check encoding/checksum implementation, avoiding a bespoke checksum | MIT, COPYING included |

Files are unchanged from these revisions. `SHA256SUMS` records the vendored sources and licenses. Verify with `shasum -a 256 -c Vendor/SHA256SUMS` from the root. Only the portable BLAKE3 backend is built; SIMD/assembly paths are disabled uniformly on simulator and device. libbase58's SHA-256 callback delegates to Apple's CommonCrypto. Ed25519 and secure key generation use Apple CryptoKit. `MassiveX/Core/MassaNative.c` contains bounded bridging code, not cryptographic primitives.

Before upgrading: review upstream changes and licenses, regenerate this checksum manifest, rebuild Debug and Release, regenerate official SDK fixtures independently, and rerun all interoperability/malformed-input tests. Do not replace the exact versioned-public-key hash with a bare Ed25519 key hash. The test vectors use the pinned official Massa SDK; see `MassiveXTests/README.md`.
