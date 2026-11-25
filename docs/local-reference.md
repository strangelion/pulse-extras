# Local SDK reference layout

All paths are relative to the pulse-extras repository root. These are local
reference materials, not tracked dependencies or replacements for the pinned
SDK. The existing .gitignore excludes /.local/, /.sdk-cache/ and /zig-out/.

## Required local reference

Extract the entire pulse-native-sdk-preview3-20261124.zip directly into:

```text
.local/reference/pulse-sdk/1.0.61-preview3-20261124/
  sdk/native/
  examples/native/
  tools/extensions/
  schemas/extensions/
  docs/
  bin/pulse_plugin_harness.exe
  native-sdk-manifest.json
```

The manifest must be at the extracted root, without another archive-name
directory in between. Preserve the complete tree and relative paths.
Optionally retain the original ZIP beside the extracted directory, at
.local/reference/pulse-sdk/pulse-native-sdk-preview3-20261124.zip.
The supplied archive SHA-256 is
`cdbe0f1d10c6ae4da8a71a7338c760c4c64c3d87522e47195b9cc749c9977ad2`.
Archive identity alone does not authenticate its publisher. Review provenance
before running included binaries or scripts.

Keep later SDK bundles in separate versioned directories. Do not overwrite
the existing .local/sdk/ checkout or .sdk-cache/include/pulse/; the latter
contains the published hash-pinned build headers. Keep the generated live
host snapshot at .local/host-sdk/. Do not commit or redistribute the local
unpublished SDK, harness, private profiles or acceptance outputs.

## Agent lookup guide

Read the relevant project docs and sdk/upstream.toml first. If the local
reference directory exists, consult these paths relative to its root:

| Task | Reference |
| --- | --- |
| Official author workflow | sdk/native/AGENTS.md; sdk/native/skills/pulse-plugin-author/SKILL.md |
| Exact ABI | sdk/native/include/pulse/abi.h; sdk/native/abi/windows-x64-msvc-preview3.json |
| Interface discovery | sdk/native/api-catalog.json; schemas/extensions/api_metadata.json |
| Native folder/file pickers and dialogs | sdk/native/include/pulse/pickers.h; sdk/native/include/pulse/dialogs.h; examples/native/archive-dialog/ |
| Task lifecycle, progress, diagnostics | sdk/native/include/pulse/tasks.h; sdk/native/include/pulse/dispatch.h; sdk/native/include/pulse/diagnostics.h |
| Native UI and theming | sdk/native/include/pulse/ui_model.h; sdk/native/include/pulse/icons.h; sdk/native/ui-model.schema.json; examples/native/reactive-panel/ |
| Directory and file operations | sdk/native/include/pulse/context.h; sdk/native/include/pulse/directories.h; sdk/native/include/pulse/fileops.h; examples/native/directory-workbench/ |
| Worker isolation and IPC | sdk/native/include/pulse/worker.hpp; sdk/native/samples/sandboxed-worker/ |
| Native packaging | docs/native-packages.md; schemas/extensions/manifest.schema.json; tools/extensions/pulse_ext.py |
| SDK verification and harness | tools/extensions/verify_sdk_bundle.py; tools/extensions/check_native_abi.py; bin/pulse_plugin_harness.exe |
| Optional author MCP | sdk/native/mcp.example.json; tools/extensions/native_author_mcp.py |

The uploaded bundle reports Pulse 1.0.61 / Preview 3 / ABI 1. Its C++
examples are references for Zig implementations, not mandatory dependencies.
Check actual declarations, struct layout, permissions and callback lifetime;
do not invent APIs or silently replace generated bindings. Use capability
detection for optional interfaces and preserve fallback behavior. Compare
against the live host contract as described in [host compatibility](host-compatibility.md).
If a local reference is absent, use the pinned published baseline and state
the limitation. CI must remain reproducible without the local reference.
Do not treat the presence of SDK files as proof of real-host acceptance.

## Optional local material

- .local/reference/openpets/: upstream reference checkout, with revision and license retained.
- .local/reference/pet-samples/: original local test packages, read-only inputs.
- .local/deps/: existing script-managed verified dependencies; do not mix with SDK references.
- .local/companion-smoke-XX/: separate isolated test output per run; keep recent relevant evidence, not unrelated user data.
- zig-out/test-assets/: disposable scripted downloads; not the sole copy of manually collected samples.

Do not change or move the actual managed pet library as part of organizing
developer references. Keep original inputs and generated test outputs separate.
