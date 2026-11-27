# Share consolidated Windows host acceptance

**Status: NOT_RUN.** Use two Windows test profiles/devices and a trusted
LAN. Keep normal Pulse data untouched. The same revision and artifact
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
| H01 | Open panel, no selection; close/reopen | No listener until explicit action; layout usable |
| H02 | Private store/spool, dynamic pairing and trust | Masked code, both approvals, restart preserves trust |
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
| H13 | Cancel active services, disable plugin, exit/restart host | Helper processes, handles and sockets released |
| H14 | Repeated transfers (20), idle and active CPU/RSS | Record actual peak/idle values and sustained growth trend |
| H15 | Optional available IPv6/overlay route | Record actual environment; not mandatory to install vendor tools |
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
