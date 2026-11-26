# Unified integration report

Status: PR candidate. This report covers `integration/unified-extras`, which
merges the three experiment branches onto one branch. It does not claim
real-host acceptance, coexistence acceptance or performance acceptance;
those are listed as BLOCKED with their preconditions.

Statuses use PASS, FAIL, BLOCKED, NOT RUN, UNSUPPORTED.

## 1. Sources

| Ref | SHA |
| --- | --- |
| `main` (merge base) | `2759b51` |
| `experiment/shared-foundation` | `2e068d5` |
| `experiment/vcs-hardening` | `72ec41e` |
| `experiment/openpets-ipc` | `aad9050` |

Remote and local refs matched at the start of the work. `main` is an
ancestor of all three branches; the branches were 4 / 30 / 201 commits ahead
respectively.

## 2. Merges and conflicts

| Step | Commit | Notes |
| --- | --- | --- |
| Phase A base | `2e068d5` | shared foundation, taken as integration base |
| Phase B | `9f41543` | `merge: integrate VCS hardening onto shared foundation` |
| Phase C | `663b125` | `merge: integrate Companion IPC onto unified shared foundation` |
| Migration | `0e7ba9e` | `refactor(companion): consume shared fs, process and https primitives` |
| Diagnostics | `16d2024` | `fix(companion): report distinct package-stage creation failures` |
| Docs | `d1ea90c` | `docs(companion): record sandboxed-stage failure signature` |

Both merges used `--no-ff`, so the full branch history is preserved.

Phase B conflicts: `build.zig`, `docs/testing.md`. `shared/pulse/async_host.zig`
and `shared/pulse/context.zig` were byte-identical on both branches
(`6597afe0…`, `42fa6943…`), so no content decision was needed there.
`build.zig` was resolved as a union: the shared-foundation module set
(`task_progress`, `pickers`, `dialogs_v2`, `runtime_retention`) plus the VCS
set (`vcs_panel`, `vcs_host_query`, `vcs_approval`,
`vcs_windows_evidence`), one import per module, `all` grown from 36 to 40.
`docs/testing.md` kept the foundation review text and added a
`### VCS hardening candidate checks` heading.

Phase C conflicts: `build.zig`, `docs/shared-runtime.md`,
`docs/testing.md`. The conflict rewrite removed the `build.zig` tail and
duplicated `pickers` / `dialogs_v2` / `runtime_retention`; the tail was
rebuilt and the duplicates removed, then verified by the full test run
below. `Modules.all` is now `[42]std.Build.Module.Import`. Documentation
conflicts were resolved additively.

## 3. Shared modules that now have real consumers

| Shared module | Consumer |
| --- | --- |
| `shared/fs/private_root_win32.c` | `shared/companion/pet_private_root_win32.c` (lease, ACL approval, diagnostics root) |
| `shared/network/https_win32.c` | `shared/companion/pet_market_http_win32.c` (bounded market download) |
| `shared/process/image_win32.c` | `shared/companion/pet_supervisor_win32.c` (`pulse_image_pin`, `pulse_image_verify`) |
| `shared/process/job_win32.c` | `pet_supervisor_win32.c`, `pet_crash_capture_win32.c` |
| `shared/process/metrics_win32.c` | `pet_supervisor_win32.c` (`pet_group_sample`) |

Product policy stayed in the Companion layer: market host/admission rules
(`pet_market_http_valid`), per-kind size caps (320 MiB ZIP, 4 MiB others),
supervisor commit limits and error mapping remain Companion constants.
Companion keeps its own inventory, install transactions, recovery records and
long-term supervision; VCS keeps its own ancestor-path, ACL and approval
audit. No shared DLL, global allocator, cross-add-on authorization database or
resident service was introduced.

`shared/fs/identity_win32.h:pulse_file_observe` already had consumers
(`private_root_win32.c`, `image_win32.c`, native fixture). The remaining
`GetFileInformationByHandle` uses in Companion are product-specific
predicates (temporary-handle rules, multi-link rules, per-record checks) and
were not forced onto the canonical-root helper. This is P2 in section 10.

## 4. Duplicate code removed

`0e7ba9e`: −392 / +60 lines across 7 files.

- local WinHTTP session/request loop and header helpers replaced by
  `pulse_https_get`;
- local image pin/verify (~90 lines) replaced by the shared process module;
- two hand-rolled Job Object setups replaced by `pulse_job_configure`
  with identical flags and limits;
- the whole Companion private-root implementation replaced by a typed
  wrapper over the shared lease.

No stale references remain (`pin_image` / `verify_image` grep is empty), and
the build passes with the old translation units removed from the targets.

## 5. Safety review

`python scripts/safety_audit.py --details`: 92 files, 1767 REVIEW findings,
0 blocking. The inventory is lexical; it is not a memory-safety proof.

Findings on the files touched by this integration: 13, all in
`shared/companion/pet_import_helper.zig` and
`shared/companion/pet_market_http_win32.zig` (C files are outside the
inventory). Reviewed:

- `pet_import_helper.zig:23` `Pair = undefined` — both arrays are written in
  full (32 and 64 iterations) after a length and separator pre-check; no
  partial read path.
- `:44/:45/:57`, `:54`, `:169` — bounded slices of caller-owned output with
  length prefixes checked first; `Detail` fields carry explicit lengths and
  utf8 validation before use; the `[16]u8` id buffer is fully written by
  `bufPrint` before use.
- `pet_market_http_win32.zig:35/49/59` `ptrCast`/`alignCast` — the context is
  the address of a `getWith` stack local; the C transport is synchronous and
  stores no callback or context beyond the call, so the cast target is live
  for the whole callback window.

Native boundary rules applied to the migrated calls: handle ownership stays
with the Companion caller (no transfer into shared helpers); shared helpers
return status plus `os_error`, and the Companion maps them to its own errors;
no allocator crosses the C boundary.

## 6. Verification

Local, on `d1ea90c`:

| Check | Result |
| --- | --- |
| `zig fmt --check build.zig shared extensions` | PASS |
| `python -m unittest discover -s scripts -p "test_*.py"` | PASS (63 tests) |
| `python scripts/safety_audit.py --details` | PASS (0 blocking) |
| `zig build test --summary all` | PASS (145/145 steps) |
| `zig build test-vcs --summary all` | PASS (55/55) |
| `zig build test-companion --summary all` | PASS (83/83) |
| `zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe` | PASS (12/12, 5 DLLs) |
| Full Debug suite before the last two commits | PASS (662/664 tests, 2 skipped) |

The two skipped tests are the existing Windows-only skips; nothing was
converted to skip. Host-level CI for the current SHA is recorded in the PR
checks.

Fault-injection coverage is inherited, not rebuilt: 400 inline Zig tests
cover cancellation (20), drain (10), stale generations (8), malformed
input (10), truncation (8), cleanup failure (6) and repeated lifecycle (3),
plus the C ABI loader and the Windows native fixtures. Companion import
faults are exercised through `test-companion-import`, whose only local
failures are the fixture temp-directory errors described in section 7.

## 7. Companion install issue (PackageStagePendingCreateFailed)

Result: BLOCKED as a product bug; attributed to the execution environment.

Evidence:

- The stage path is `<private root>\pet-<id>.pending`, created by
  `CreateDirectoryW` in `shared/companion/pet_decode_win32.c`.
- A probe that runs `CreateDirectoryW`/`CreateFileW` under `%LocalAppData%`
  and `%TEMP%` returns Win32 5 for every variant, including a call with no
  security descriptor, while the same calls succeed inside the workspace.
  Four DACL variants (none, inherited, protected, no owner) all fail
  identically. The agent sandbox filters writes by path, not by ACL.
- The same cause explains the fixture failures in `test-companion-import`
  (`GetTempFileNameW`, Win32 5) and the earlier host smoke runs.

Product change kept from this investigation (`16d2024`): the pending-directory
failure now reports the raw Win32 code, an existing pending path is
distinguished from a denied creation, and outfits/activities creation
failures are no longer silent. `docs/companion-host-smoke.md` records the
sandbox signature and the probe that separates environment from defect.

Real-host functional acceptance (activation, market browse, import, recovery)
remains BLOCKED: it requires a normal user session, a dedicated Windows test
user or a VM, per the runbook; it was not executed here.

## 8. VCS real-host acceptance

NOT RUN. The candidate keeps its mock/controller/native-fixture coverage and
the locked-DLL loader check, but the real Pulse host walkthrough was not
executed in this environment.

## 9. Multi-add-on coexistence and performance

BLOCKED. Both require an isolated Windows user or VM (LocalAppData and HKCU
are not isolated by a Pulse profile). No measurements are reported; inventing
numbers would be worse than reporting the gap. Offline facts only: the
ReleaseSafe build produces `pulse_hello_panel.dll`, `pulse_vcs_panel.dll`,
`pulse_companion.dll`, `pulse_companion_runtime.dll` and `pulse_abi_probe.dll`
from one build graph, and no shared module adds a resident thread or service.

## 10. Remaining issues

- P0: none identified.
- P1: real-host Companion acceptance; VCS real-host acceptance; coexistence
  and performance acceptance. All blocked on an isolated Windows user/VM.
- P2: Companion's `GetFileInformationByHandle` predicates are not expressed
  through the shared identity helper; the CI package trigger is still
  hard-coded to `experiment/openpets-ipc` (manual `companion_test_package`
  input works on any branch).

## 11. Not executed / blocked

| Item | Status | Reason |
| --- | --- | --- |
| Real-host Companion D cases | BLOCKED | needs normal user/dedicated VM; sandbox denies %LocalAppData% writes |
| VCS real-host acceptance | NOT RUN | same precondition |
| Multi-add-on coexistence | BLOCKED | same precondition |
| Performance/resource matrix | BLOCKED | same precondition |
| ZLS | NOT RUN | not installed; pin compatibility unverified |
| ZLint | NOT RUN | not installed |
| Zwanzig | NOT RUN | not installed |
| Clang Static Analyzer | UNSUPPORTED | no analyzer binary in the pinned Zig 0.17.1 distribution |
| ASan (Windows, Linux) | UNSUPPORTED | `__asan_init` link failure with the pinned toolchain |
| TSan (Windows) | UNSUPPORTED | option rejected for the target |
| TSan (Linux) | NOT RUN | compile-only check succeeded; no Linux runner in this session |
| Application Verifier | NOT RUN | not installed |
| WinDbg | NOT RUN | not installed |

Zig was not downgraded for any tool.

## 12. Merge readiness

The branch merges the three experiments without dropping history, the shared
modules have real consumers, duplicate native code is gone, and the local
gate plus CI on the branch head are the evidence for this revision. Merging to
`main` is acceptable for the code paths covered by CI; the host-level
acceptance items in section 11 remain open and are not implied by this merge.
