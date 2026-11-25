# Local SDK reference layout

All paths are relative to the `pulse-extras` repository root. The local
Preview 3 bundle is a reference and verification aid, not a replacement for
the pinned, reproducible build SDK.

## Required local reference

Extract the entire `pulse-native-sdk-preview3-20261124.zip` directly into:

```text
.local/
  reference/
    pulse-sdk/
      1.0.61-preview3-20261124/
        native-sdk-manifest.json
        sdk/native/
        examples/native/
        tools/extensions/
        schemas/extensions/
        docs/
        bin/pulse_plugin_harness.exe
```

The manifest must be at the extracted root. Preserve the complete directory
tree and relative paths; do not add another archive-name directory between
the versioned directory and the manifest. Optionally keep the original ZIP
beside the extracted folder:

```text
.local/reference/pulse-sdk/pulse-native-sdk-preview3-20261124.zip
```

The supplied archive SHA-256 is
`cdbe0f1d10c6ae4da8a71a7338c760c4c64c3d87522e47195b9cc749c9977ad2`.
A matching digest establishes archive identity, not publisher authenticity;
review provenance before running bundled binaries or scripts.

Keep later SDK bundles in separate versioned directories. Do not overwrite
the existing `.local/sdk/` checkout or `.sdk-cache/include/pulse/`; the
latter contains the public, hash-pinned build headers. Keep the live host
snapshot at `.local/host-sdk/`. Never commit or redistribute the unpublished
local SDK bundle, harness executable, host profiles, or acceptance output.

## Agent lookup guide

Read the relevant project documents and `sdk/upstream.toml` first. If the
local reference exists, consult these paths relative to the versioned SDK root:

| Task | SDK reference |
| --- | --- |
| Agent rules and C++ authoring skill | `sdk/native/AGENTS.md`; `sdk/native/skills/pulse-plugin-author/SKILL.md` |
| Exact ABI and x64 layout | `sdk/native/include/pulse/abi.h`; `sdk/native/abi/windows-x64-msvc-preview3.json` |
| Interface discovery and stability | `sdk/native/api-catalog.json`; `schemas/extensions/api_metadata.json` |
| Native folder/file pickers and dialogs | `sdk/native/include/pulse/pickers.h`; `sdk/native/include/pulse/dialogs.h`; `examples/native/archive-dialog/` |
| Task lifecycle, progress, diagnostics | `sdk/native/include/pulse/tasks.h`; `sdk/native/include/pulse/dispatch.h`; `sdk/native/include/pulse/diagnostics.h` |
| Native UI and theming | `sdk/native/include/pulse/ui_model.h`; `sdk/native/include/pulse/icons.h`; `sdk/native/ui-model.schema.json`; `examples/native/reactive-panel/` |
| Directory and file operations | `sdk/native/include/pulse/context.h`; `sdk/native/include/pulse/directories.h`; `sdk/native/include/pulse/fileops.h`; `examples/native/directory-workbench/` |
| Worker isolation and IPC | `sdk/native/include/pulse/worker.hpp`; `sdk/native/samples/sandboxed-worker/` |
| Native packaging | `docs/native-packages.md`; `schemas/extensions/manifest.schema.json`; `tools/extensions/pulse_ext.py` |
| SDK verification and harness | `tools/extensions/verify_sdk_bundle.py`; `tools/extensions/check_native_abi.py`; `bin/pulse_plugin_harness.exe` |
| Optional author MCP | `sdk/native/mcp.example.json`; `tools/extensions/native_author_mcp.py` |

The uploaded bundle reports Pulse 1.0.61 / Preview 3 / ABI 1. Its C++20
examples are API references for this Zig/C implementation, not mandatory
dependencies. Verify declarations, packing, offsets, callback lifetimes,
thread affinity, permissions, and version negotiation before porting an API.
Do not invent declarations or silently replace generated pinned bindings.
The local host contract is recorded in
[host compatibility](host-compatibility.md). If the local bundle is absent,
use the pinned public baseline and state that limitation. CI must remain
reproducible without files under `.local/`.

## Optional local material

- `.local/reference/openpets/`: upstream reference checkout with revision
  and license recorded.
- `.local/reference/pet-samples/`: original local test packages; treat as
  read-only inputs.
- `.local/deps/`: existing script-managed, verified dependencies; do not
  mix them with SDK references.
- `.local/companion-smoke-XX/`: one fresh isolated output directory per host
  acceptance run. Retain relevant evidence, not unrelated user data.
- `zig-out/test-assets/`: disposable scripted downloads, never the only copy
  of manually collected samples.

Do not move, modify, or clean the actual managed pet library while organizing
developer references. Keep original inputs separate from generated test output.
