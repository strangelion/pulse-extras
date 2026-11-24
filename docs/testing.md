# CI and local testing

The Zig regression workflow runs on Windows and Linux. It checks formatting, Python 3.12 script syntax, Zig unit tests, native provider integration tests, Windows x64 DLL builds, and (on Windows) pinned SDK binding regeneration and C ABI loader tests.

| Coverage | Windows | Linux |
| --- | --- | --- |
| SDK wrappers and ABI tests | Required | Required |
| Git temporary repository | Required | Required |
| Jujutsu 0.46.0 temporary repository and operation-log invariance | Required | Required |
| SVN local repository and working-copy status | Optional if installed locally | Required |
| Windows DLL build | Required | Required |
| C loader + binding regeneration | Required | Not run |
| Actual Pulse UI/host acceptance | Manual isolated host | Not run |

CI installs the pinned JJ binary from its official release and checks the recorded SHA-256. Linux CI installs Subversion through the runner's package manager and creates a local repository using svnadmin. The build script snapshots PATH and PULSE_REQUIRE_* flags from the build environment into a generated test-options module using Zig 0.17's supported build graph environment map. Test code does not fabricate platform-specific std.process.Environ blocks. The flags prevent absent tools from silently skipping required integrations. The SVN fixture path is passed through the same generated options module. Local runs may skip unavailable optional CLI tests; skipped tests are not integration evidence.

No remote VCS server, credentials or real user repositories are required. Host UI, packaging, cancellation/worker teardown, multi-provider cache correctness and performance tests still need dedicated coverage as the relevant features are implemented. A green workflow does not prove those untested properties.

## Zig installation cache

The workflow restores the original Zig archive with actions/cache v5. The locked sizes and SHA-256 digests in scripts/zig-downloads.json come from the official release index. Every restored archive is checked again before extraction and the extracted compiler version is verified. On a cache miss the archive is downloaded from the official origin, checked, extracted and saved immediately, before compilation or VCS integration tests. The cache key changes with the pinned release metadata, OS or architecture. Pull requests restore but do not save this cache. The installer reports cache hits/misses and download, verification, extraction and version-check timings separately. A corrupted cached archive is re-downloaded; if an immutable cache entry remains corrupted, delete that entry in GitHub Actions cache management. No extracted toolchain, user data, test fixture or release package is cached. Community mirrors and compiler caches are deliberately not enabled yet; mirror adoption requires official signature verification and compiler-cache adoption requires measurements.

## Reproducible SDK bindings

The generator normalizes standalone translate-c source-location comments for known SDK headers and the compiler's stdint.h. Absolute installation paths are not part of the ABI. All declarations, diagnostic expressions, header hashes, and source line/column numbers remain subject to exact comparison. A failed check prints a bounded unified diff to identify any remaining differences without weakening the gate.
