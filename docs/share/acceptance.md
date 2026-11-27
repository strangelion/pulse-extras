# P2 installed acceptance runbook

Status: NOT RUN on physical devices. Passing CLI loopback or official package
verification does not demonstrate host integration. Do not publish a preview
or merge based on this checklist alone.

Use two disposable Windows test profiles and a trusted LAN. Keep daily Pulse
stores, user data, and other extensions untouched. No automatic firewall
change is made. If the OS or local network refuses the connection, record the
blocker; do not weaken the system's network policies.

## Package and install

Build an isolated candidate using scripts/stage_share_test.py as documented
in README.md. Record commit, CI run, Pulse version and host SHA-256, package
SHA-256, manifest and four member digests from build-evidence.json. Verify
both machines use the same package. Use the official tool and a separate
store/profile (see docs/vcs-acceptance-runbook.md). Explicitly allow the native
test package only in the isolated store.

    python <pulse_ext.py> --pulse <Pulse.exe> --json install <candidate.pulse-ext> --store <isolated-store> --allow-native
    python <pulse_ext.py> --pulse <Pulse.exe> --json enable strangelion.share-dev --store <isolated-store> --allow-native
    python <pulse_ext.py> --pulse <Pulse.exe> --json run --store <isolated-store> --profile <new-profile>

## Acceptance cases

| Case | Evidence / expected behavior |
| --- | --- |
| Activation and zero-selection menu | Panel opens without starting a child or listening |
| Ordinary file selection | Panel displays exact selected file; folders not admitted to send |
| Private directories | New store and spool are created; existing ordinary ACL rejected in managed mode |
| Identity and pairing | Fingerprints independently compared on both devices; saved trust survives process restart |
| Discovery | Show actual peer endpoint; discovery alone never grants trust; numeric address fallback |
| IPv4 / IPv6 send in both directions | Per-file approval; SHA-256 before/after matches |
| Reject offer / wrong peer pin | No output file; no silently approved connection |
| Existing destination | Original content and digest unchanged |
| Progress and refresh | Observe byte counts, current prompt, and terminal status |
| Cancel during listen / receive / local commit | No silent publication; uncertain result reported honestly |
| Disable / close / reopen / exit | Child process count returns to baseline when cancelled or host exits |
| Abrupt exit | Inspect spool journal; no deletion or retry based only on name |
| Revoke | Future connection denied; no claim that active transfer rolled back |
| Repeated 20 transfers | Record idle/peak process memory, handles, threads, CPU and throughput; no sustained growth trend |

Use generated disposable data only (empty file, Unicode filename, multi-chunk
file and 128 MiB file). Record each case PASS/FAIL/NOT RUN and relevant logs.
The manual Refresh button remains required. Forced termination recovery is
read-only and native destination-stage automatic recovery is not implemented.
Report these limitations; never claim automatic restart recovery or stable
release readiness. P3 multi-file, resume, and P4 directory access are separate.

Windows CI verifies managed-mode saved-peer loopback (including protected
store/spool admission). This is still distinct from the installed host test.

For the UI revision, recheck all three tabs, visible labels and placeholders,
button availability during work, progress refresh, manual fallback, host settings
save/reload and reopening without losing drafts. Test opt-in discovery and
explicit receive separately. Do not treat the UI revision as accepted based on
the earlier 9cd77d2 screenshot or CI results.

Verify independent creation of identity and spool directories, retained query
results, and bounded session history. History is not persistent across plugin
restart. A discovery result must still be entered as an explicit reviewed address.

Check selectable local addresses, discovered endpoints and saved peers; ensure
selection alone never initiates a network operation. Change the bind/store and
verify old query choices cannot be applied. Test cancel and close during native
folder selection, and verify suggested private paths are not created until
explicitly requested.

Save defaults from the main panel and confirm the host's result in its
settings page; reopen the extension and verify values are retained. Test a
failed query followed by a successful query and confirm stale entries are not
selectable. Native folder picker fallback remains manual on unsupported hosts.
