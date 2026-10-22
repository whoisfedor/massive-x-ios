# Unit-test safety and fixtures

The account vectors in `PublicMassaFixtures.swift` contain **published, deliberately insecure TEST-ONLY keys**: zero, ascending, descending and all-255 byte patterns. They are not owner wallets. Never fund these identities or replace them with a real secret. The YAML fixture uses publicly documented repeated test bytes and a public test password. These values are explicit test-data exceptions, not credentials for a service or real wallet.

Reference oracle: official `@massalabs/massa-web3` 5.4.0, revision `d48c0db559ff35e84b38c481a447345b540e22b7`:
https://github.com/massalabs/massa-web3/tree/d48c0db559ff35e84b38c481a447345b540e22b7
Operation-ID fixtures were produced offline using that SDK and the official protocol hash formula. The YAML fixture also references Massa Station revision `814e34eb6b19ae31927142e939faf466bdbbf978`. Header-only provenance edits do not alter fixture data. The SDK generator package and prior development receipts are not required to run these self-contained fixtures and are not included.

Retained tests cover key/address/signature compatibility, operation IDs, exact amounts, mocked transfer and recovery behavior, scoped removal authorization, bounded networking, presentation, localization and privacy. Their deterministic fixture bytes and memory stores must never be used with real funds. Some tests create disposable in-memory keys and isolated temporary files; tests do not broadcast transactions. The isolated runner is the supported safe entry point rather than launching tests against an installed wallet.

Live-indexer-derived history fixtures, their dependent suites and an unproven hardcoded UI-address fixture are intentionally omitted because they were not established to be unrelated to owner examples. The older UI automation suite is also omitted. This is selected unit coverage, not a complete security audit or a claim that every retained test has been rerun for this export.
