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

CI installs the pinned JJ binary from its official release and checks the recorded SHA-256. Linux CI installs Subversion through the runner's package manager and creates a local repository using svnadmin. The PULSE_REQUIRE_* environment flags prevent absent tools from silently skipping required integrations. Local runs may skip unavailable optional CLI tests; skipped tests are not integration evidence.

No remote VCS server, credentials or real user repositories are required. Host UI, packaging, cancellation/worker teardown, multi-provider cache correctness and performance tests still need dedicated coverage as the relevant features are implemented. A green workflow does not prove those untested properties.
