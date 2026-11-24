# Host SDK compatibility evidence

Captured 2026-11-24 on the development machine. This document records what the
installed Pulse host actually exposes, how that differs from the published SDK
revision pinned in `sdk/upstream.toml`, and why the build baseline stays on the
published revision for now.

## Host under test

| Field | Value |
| --- | --- |
| Binary | `C:\Program Files\Pulse\DialogBridge\07bd24ba98cd33130e4c4f5124c05898630a0f8da8a3f9ef61d74b8e72b6403f\pulse.exe` |
| Size | 18,428,928 bytes |
| SHA-256 | `c10bdf77c32c59f1e09ad9fd12f285105a084d1e15a280108381620621f1382a` |
| Product version | 1.0.61 (launcher and app agree) |
| ABI version | 1 |
| SDK preview | 3 (`sdkPreview`) |
| Interfaces | 23 |
| Embedded headers | 19 |
| Catalog SHA-256 | `31d204e96e831bd49d71c60a0f0831ae3f42ec2ae8416b1adb02699f09c8b755` |
| `contractIdentity.sha256` | `ce00eacfa5699d2dd5a67d54d6e26f5e4f717f6a87e277a1e5de2f4561a8e246` |

Discovery command (headless, no GUI, no native code executed):

```powershell
& "<pulse.exe>" --extension-api --extension-check
```

Exit code 0, 141,712 bytes of JSON on stdout, empty stderr. The response embeds
the full text and SHA-256 of every published interface header, so the snapshot
is self-verifying: `scripts/host_sdk.py extract` refuses the snapshot when any
header text does not match its declared digest.

Snapshot and drift check:

```powershell
python scripts/host_sdk.py extract --pulse "<pulse.exe>" --out .local/host-sdk
python scripts/host_sdk.py verify  --pulse "<pulse.exe>" --baseline .local/host-sdk
python scripts/host_sdk.py compare --baseline .local/host-sdk --against .local/sdk/sdk/native
```

## Drift against the published baseline (v1.0.60)

Published revision `b32436831a066e18448b2810bef4bf989024fc68` (tag `v1.0.60`,
current GitHub `main`) exposes 16 interfaces. The installed host exposes 23.

| Change | Detail |
| --- | --- |
| Added | `pulse.diagnostics` v1, `pulse.icons` v2, `pulse.pickers` v1, `pulse.search` v1, `pulse.shell` v1, `pulse.tray` v1, `pulse.workbench` v2 |
| Version bump | `pulse.commands` 1 -> 2, `pulse.dialogs` 1 -> 2 |
| Same version, new content | `pulse.tasks` (task actions, optional progress tail), `pulse.ui.model` (adds `PULSE_UI_MODEL_CANVAS = 41`, `COUNT` 41 -> 42) |
| Unchanged core | `abi.h`, entry point `PulsePluginEntryV1`, preview export `PulsePluginSdkPreview`, ABI version 1, SDK preview 3 |

No published branch matches the host: `main` has 16 interfaces and
`sdk/preview3-dialogs` has 20. The 1.0.61 SDK is therefore newer than any
public revision; the host binary is the only authoritative source.

## Decision

- **Build baseline stays on the published v1.0.60 SDK.** It is fetchable,
  hash-pinned, CI-reproducible and licensed for redistribution. No unpublished
  headers are vendored into the repository.
- **Runtime target includes the installed 1.0.61 host.** The host declares the
  append-only rule itself (`stability.prefixTableRule`: existing fields keep
  identical index, name, type, size and byte offset; new fields append at the
  tail with a larger `size` and `version`). Every changed table in 1.0.61 only
  appends fields or adds guarded optional tails, so V1 tables remain valid.
- **The extension asks for V1 tables** and treats newer interfaces through
  capability detection. Upgrading the pin is a separate, evidence-driven change
  once upstream publishes a matching revision.

## Host acceptance run (2026-11-24)

Package and host used for the run:

| Field | Value |
| --- | --- |
| Package | `strangelion.abi-probe` (manifest hash `e0216565eaed814b674cbc72ce9ab5bc033263b631e5b415d117f7a379c5a14d`) |
| Library SHA-256 | `d4d160d674cae00da3a3563ac435b75448b00667d9f687ef6040fcc0d8c3cb80` |
| Build | `zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe` |
| Store | isolated directory, installed with `pulse_ext.py install --allow-native` + `enable` |
| Profile | throwaway `LOCALAPPDATA` plus throwaway `PULSE_TEST_DATA_DIR` |
| Host process | `pulse.exe --test-instance --extension-store <store>` |

Harness: `python scripts/host_acceptance.py --store <store> --out <dir>`. It
opens the host, selects a row, presses the extension shortcut, captures the
screens, reads the DLL log written through `ABI_PROBE_LOG`, and closes the
window.

Observed evidence (all from the same process, thread id in parentheses):

| Step | Evidence |
| --- | --- |
| DLL loaded from the installed package | `entry tid=3348` |
| `pulse.commands` V1 table accepted | `query pulse.commands=0` |
| Command registered | `query register=0` |
| Host surfaces the command | context menu shows `Pulse ABI Probe: Ping` with `Ctrl+Shift+F9` |
| Shortcut dispatches to the plugin | `invoke id=536870912 tid=3348` |
| Screenshots | `<out>/01-launch.bmp` … `<out>/05-context-menu.bmp` |

The host assigns its own namespace to the command id (`536870912` = `0x20000000`
for this package); the plugin never sees its `strangelion.*` string again at
invocation time.

### Full lifecycle run (2026-11-24, second pass)

A command-only package is invoked without `activate`, so the lifecycle needed a
run where the package is opened from its entry. That run is the authoritative
one:

| Field | Value |
| --- | --- |
| Library SHA-256 | `54fad95a0feb4c79dcda2730c8ed373bd82b4718049d8634dc546f306ff7b714` |
| Manifest SHA-256 | `6434ea0c9a5a574e8054107c601bd241297323f50b482f3cc7def056cd8a85ea` |
| Store | isolated `.local/store4` (`pulse_ext.py install --allow-native` + `enable`) |
| Profile | throwaway `LOCALAPPDATA` and `PULSE_TEST_DATA_DIR`, one host process |
| Host | `pulse.exe --test-instance --extension-store <store>` (1.0.61) |

Complete log of the run (`.local/manual2/probe.log`, one process, one thread):

```
entry tid=41584
query pulse.commands=0 tid=41584
query register=0 tid=41584
activate tid=41584
deactivate tid=41584
destroy tid=41584
```

- `activate` fired when the package was opened from the extension card.
- `deactivate` and `destroy` fired when the package was disabled with the card's
  switch, i.e. through `SetPackageEnabled(false)` → `StopPackage` →
  `Session::Stop` → `Drain` → `Module::Close`.
- Unload was checked directly: while the host kept running, the installed
  library file could be opened for read and renamed (`MoveFileEx` returns 1),
  so the image was no longer mapped after `destroy`.

Two findings from this pass:

- An earlier run appeared to skip `deactivate`. That run had **two** host
  processes appending to the same `ABI_PROBE_LOG` file with
  `GENERIC_WRITE` + `SetFilePointerEx(FILE_END)`, which is not atomic; lines
  were lost. The probe now opens the log with `FILE_APPEND_DATA` so appends are
  atomic, and the single-process run above shows the complete sequence.
- Closing the window is not an exit: with "keep running in the background"
  enabled the last window hides to the tray (`CloseMainWindow` →
  `HideMainWindowToTray`). Full exit is the palette/tray command, which posts
  `WM_EXIT_PULSE` (`WM_APP + 72` = `0x8048`) to the window.

### UI panel run (2026-11-24, third pass)

`strangelion.hello-panel` (library `pulse_hello_panel.dll`, manifest revision
`441a22c9…`) was installed into an isolated store and opened from the command
palette row `strangelion.hello-panel · Pulse Hello Panel`, which is the same
path a user takes. The host then called, in order:

```
entry tid=29144
ui.commands=0 tid=29144
register=0 tid=29144
activate tid=29144
ui.model=0 tid=29144
ui.model.create=0 tid=29144
ui.model.subscribe=0 tid=29144
ui.mount=0 tid=29144
panel-open tid=29144
deactivate tid=29144
panel-close tid=29144
destroy tid=29144
```

The panel rendered inside the main window (title, two text rows and a button in
Pulse's own style; screenshot kept in the run archive), and `WM_EXIT_PULSE`
produced `deactivate` → panel close → `destroy`. Two host rules cost real
debugging time and are worth recording:

- Every `PulseUiModelNode` needs a unique `id` matching `[A-Za-z0-9._-]{1,64}`;
  a missing id rejects the whole tree with `PULSE_ERROR_ARGUMENT`.
- The tree, its nodes and the declared command ids must stay alive for the
  duration of the `create` call. Building them in a helper frame that returns
  the `PulseUiModelTree` by value leaves dangling pointers and fails validation.

Not claimed:

- Crash containment, hang isolation, or thread guarantees for plugin code.
- That the palette hotkey (`Ctrl+Shift+K`) is usable in every environment: it is
  taken by the Microsoft Pinyin IME soft-keyboard hotkey on this machine
  (`RegisterHotKey` returns `ERROR_HOTKEY_ALREADY_REGISTERED` = 1409).
- Panel behaviour beyond one stack/text/button tree: virtual lists, data tables,
  secondary sidebar placement and DPI/theme variants are still unimplemented.

## Gaps (explicit)

- Mechanical proof of the append-only claim (field-offset prefix check between
  the two header sets): **NOT VERIFIED** yet; planned as a scripted check using
  the Zig-bundled Clang AST dump.
