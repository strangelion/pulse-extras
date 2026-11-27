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

Dynamic pairing controller: verify both approval directions, independent peer
labels, exclusive creation and clear reporting of asymmetric write failures.
The isolated controller tests are not acceptance of a native pairing page;
no short-code host command is enabled until private code I/O and helper pinning
are integrated and reviewed.

Connection candidate additions: use a fresh four-helper artifact and verify
all binary hashes and license notices. Test masked code input, countdown and
rotation, premature confirm/cancel, modal close, host disable/exit, and that
codes never appear in task snapshots, logs, settings or transfer history.
On two machines exercise LAN and private overlay pairing; routed transfers
must require a saved pin and the exact incoming TCP source. For an existing
TCP forward or manual mapping, select the actual proxy/source address and
verify TLS remains end-to-end. Confirm wrong source, wrong pin and
classical-only TLS are rejected; no automatic public listener, mapping,
discovery, trust or overwrite. Record actual group negotiation.

Verify the two discovery lists distinguish file reception and dynamic pairing.
Only the numeric endpoint and service type are advertised, never the short
code or certificate. Confirm the advertisement stops when the code clears;
numeric manual entry remains usable when multicast is unavailable.

## Planned content-sharing acceptance (stage 2)

See [roadmap](roadmap.md) for required implementation; all checks in this
section are NOT RUN until the features exist. Verify clipboard text/image,
ordinary CF_HDROP files/folders, cut-as-copy, busy clipboard, cancellation,
no automatic sync by default, no clipboard overwrite/echo loop or content
in logs. Test Tray Shelf only through a supported snapshot interface; record
SDK unavailable if absent. Optional host staging must report actual commit
outcome and preserve verified bytes/no-overwrite. Exercise block/whole-file
hash failures, changed source, interrupted resume, malformed paths, quota,
read-only grants/revocation, and global 1/2/4/8/16/32-channel resource budgets
under mixed jobs. Record measured throughput and peak/idle CPU, memory,
handles, sockets and disk I/O; do not infer performance from loopback CI.

Optional content feature settings: verify all optional switches default off;
master disable overrides type/direction toggles, untrusted peers and absent
per-peer grants fail, file references remain manual, and disabling auto-sync
drains watchers/tasks without erasing local content. Native settings and real
clipboard tests remain NOT RUN until the adapters are implemented.

## Connection-stage exit evidence

- Implementation baseline 72a207a: [CI 46034445254](https://github.com/strangelion/pulse-extras/actions/runs/46034445254)
  PASS, Windows and Linux regression jobs and regression gate passed.
  Individual official job log retrieval was unavailable during consolidation;
  do not infer the IPv6-specific case passed rather than skipped.
- QUIC feasibility 27ef92b: [CI 46034841201](https://github.com/strangelion/pulse-extras/actions/runs/46034841201)
  PASS, Windows job 140627523406 and Linux job 140627523124.
  Both logs show Go 1.27.4, quic-go v0.66.0 and TLS version 0x0304,
  X25519MLKEM768, ALPN pulse-share-batch/2 on both connections.

| QUIC probe case | Windows | Linux |
| --- | --- | --- |
| Real UDP loopback, hybrid TLS and pinned peers | PASS | PASS |
| Stream reset, reconnect and verified-block resume | PASS | PASS |
| Final whole-file SHA-256 and channel budget release | PASS | PASS |
| Wrong server pin | PASS (rejected) | PASS (rejected) |
| Wrong client pin | PASS (server rejected) | PASS (server rejected) |
| Classical-only group | PASS (rejected) | PASS (rejected) |
| Wrong ALPN | PASS (rejected) | PASS (rejected) |

Probe evidence is not a production QUIC backend or a benchmark. Dependency
evidence remains in the run artifacts subject to GitHub retention. Production
module and normal CI remain unchanged.

## Final network acceptance (stage 3)

| Case | Status |
| --- | --- |
| Native host pairing, persistent trust, revoke, private dialogs | NOT_RUN |
| Physical two-device IPv4/IPv6 transfers and native reconnect | NOT_RUN |
| CI namespaces, cross-subnet routing, NAT/port mapping | NOT_RUN |
| Real temporary WireGuard, Tailscale/Headscale, ZeroTier | NOT_RUN |
| Real FRP TCP and Nginx Stream passthrough | NOT_RUN |
| Network loss, delay, MTU, bandwidth, interruptions, UDP blocked | NOT_RUN |
| QUIC production integration, multistream performance and migration | NOT_RUN / conditional on integration |

Keep dedicated network suites separate from ordinary feature CI. Report
PASS / FAIL / SKIP / ENVIRONMENT_ERROR / NOT_RUN per scenario. Runner
capability and tooling limitations are not a pass. A loopback forward does
not establish compatibility with a named external tool. Native batch
integration and queue ownership remain stage 2 work; installed single-file
commands are not automatically resumed. No claim of external network or
physical device acceptance until actually exercised.

## Stage 2 QUIC / content source candidate

Matching CI must pass actual Windows QUIC file delivery and no-overwrite
integration as well as Go QUIC loopback, source selection tree and packet
admission tests. These checks are NOT_RUN until the new revision completes.
Physical native UI QUIC, IPv6 and overlay performance remain stage 3.
Native batch, clipboard, remote directories and shelf adapters are NOT_RUN
and not enabled by these core changes. Include both third-party notices in
acceptance package inventory. Do not imply the earlier probe validates this
new implementation.
