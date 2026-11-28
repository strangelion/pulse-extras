# Share consolidated Windows host acceptance

**Status: NOT_RUN.** Use two Windows test profiles/devices and a trusted
LAN. Use separate Windows user profiles or disposable VMs to isolate desktop preferences and keep normal Pulse data untouched. The same revision and artifact
must be used on both devices. No automatic firewall/UPnP changes, no
public listener and no third-party overlay installations required for
this baseline. Use generated disposable files only.

## Preparation

1. Confirm the exact commit's Windows/Linux regression and inspect
   the dedicated network report. Download share-acceptance-inputs.
2. With the repository checked out at that commit, follow the verified
   packaging instructions in README.md and use stage_share_test.py.
   It stages a fresh candidate.pulse-ext and build-evidence.json.
3. Install and enable only in separate stores/profiles using the
   official Pulse author tool (see acceptance.md). Record Pulse version,
   commit, CI run IDs and package SHA-256.
4. Generate a disposable fixture on each machine with the command below.
   Select only the generated files and directories in Pulse.

    python tests/share/physical_fixture.py --out .local/share-fixture-a

Copy the manifest to the other device independently. Verify the received
tree using the same script (no overwriting, deletion or clipboard access):

    python tests/share/physical_fixture.py --verify <received-tree> --manifest <manifest.json>

## One-session checklist

| ID | Scenario | Expected |
| --- | --- | --- |
| H01 | Open Share directly and from Pulse with and without a selection | Same desktop UI, selection copied, no listener until explicit action |
| H02 | Discover, select address, pair and verify trust | Results or empty state shown, host code stays visible, join input masked, both approvals required |
| H03 | TCP and QUIC single file, both directions | Confirm offer, SHA-256 matches; no overwrite |
| H04 | TCP and QUIC folder/multi-selection | Empty directories and Unicode filenames preserved |
| H05 | Fixed 1/8/32 and adaptive channels | Correct bytes, bounded memory; no hang |
| H06 | Cancel or disconnect mid-transfer, explicitly resume | Existing verified blocks reused; whole-file digest correct |
| H07 | Reject offer, existing target, revoked peer | No undesired overwrite or new access |
| H08 | Outbox: enqueue several, restart, run, discard and prune | Pending records preserved; uncertain records not replayed |
| H09 | Manual text/image/file clipboard, folder/clipboard delivery | Explicit approval, correct content and valid local file references |
| H10 | Automatic text and image sessions | New changes only; local edit stops overwrite; cancel stops sync |
| H11 | Directory service: repeated listing, subtree download | Only selected root; read-only; stop releases listening port |
| H12 | Preference save/reload; panel resize; task progress and prompts | Values retained, no stale selection, responsive UI |
| H13 | Close Share with an active service, then restart | Helper processes, handles and sockets released; no automatic listener |
| H14 | Repeated transfers (20), idle and active CPU/RSS | Record actual peak/idle values and sustained growth trend |
| H15 | IPv6 or an existing private overlay, when available | Enter addresses and source restriction at pairing time, verify both fingerprints, then transfer using the routed actions |
| H16 | Tray Shelf | DEFERRED: public SDK adapter unavailable |

For each test record PASS/FAIL/NOT_RUN/ENVIRONMENT_ERROR, time, expected
vs actual result and relevant sanitized logs. Do not log clipboard text,
pairing code, actual identity keys or personal paths. Record failures
even when a subsequent retry passes. Use Task Manager/Resource Monitor
for host and helper CPU, private working set, handles and threads.
Network performance values depend on the hardware and route.

Do not claim real-host acceptance or release readiness from the existence
of this checklist. Send results for all cases together; only additional
tests required by observed defects should need another run.

## Preferred Action-built package

Use the existing Extension test package Action on main
with request share=0.1.0-rc.1. Download upstream-candidate-packages/share,
verify SHA256SUMS and use the official author tool with isolated stores.
This replaces local compilation/staging for the ordinary test path.
Record the exact package SHA-256 and actual installed host version;
the candidate is unsigned and not a stable release. Do not activate
strangelion.share-dev and strangelion.share simultaneously.

The workflow filename remains upstream-candidate.yml for existing links and SDK automation.
For a manually requested test package, run_regression defaults to false (package-only).
Enable it when a full regression is required. SDK update dispatches explicitly enable
full regression, and SDK pull requests always run full regression. A failed requested
regression blocks packaging. All packages still undergo official format verification
and digest checks; skipping regression is not proof of passing regression.
The existing upstream-candidate-packages artifact name is retained for compatibility.
