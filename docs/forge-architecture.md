# Pulse Forge / AI 增强包开发工作台

Status: **design only**, not implemented. Proposed package ID: `strangelion.forge`.
The goal is to turn a natural-language request into an inspectable Zig extension project,
tested package and optional approved installation, while preserving Pulse's existing AI/MCP
authorization boundaries. Forge is not a replacement for Pulse AI, not a model provider by
itself, and not a promise that arbitrary requests can be implemented safely.

## 1. Upstream boundary and feasibility

Reference baseline: public Pulse commit
[`b324368`](https://github.com/jimmgreen/pulse/tree/b32436831a066e18448b2810bef4bf989024fc68),
Pulse 1.0.60 SDK Preview 3. The local 1.0.61 host exposes additional interfaces; see
[host compatibility](host-compatibility.md). Rediscover the installed host and recheck public
SDK source before implementing Forge. Do not infer capabilities from the version alone.

| Existing official tool | Responsibility | Boundary |
| --- | --- | --- |
| describe_extension_api | Discover schema, capabilities, native SDK metadata | Read only |
| validate_extension_manifest | Validate manifest text | No file access, install or execution |
| get_extension_template | Obtain built-in template where available | Feature detection required; not a native-code generator |
| native_sdk_describe | Independent author MCP SDK discovery | Not a grant of runtime permissions |
| native_project_create / native_project_build | Official author workspace creation and C++ build | C++ templates/toolchain; not verified for Zig |
| native_package_stage / native_package_install | Package, verify and install to author test store | Explicit native consent; no production install by default |
| native_host_diagnose / native_host_run | Compare host SDK and launch isolated profile | Launch does not prove DLL activation or UI correctness |

The public MCP tool catalog is defined in host code. The pinned SDK does not expose a
general AI/MCP tool-registration interface or access to the built-in assistant's credentials.
Native command registration is not proof that arbitrary typed AI tools can be registered.
The historical declarative/JavaScript runtime is not a supported substitute for the native SDK.

Three integration levels:

1. External Codex/Pi or another compatible MCP client uses official Pulse MCP for authorized
   context/actions and Forge's separate stdio author MCP for Zig engineering. This is the
   first viable target; no host modifications required.
2. A native Forge panel starts a user-configured, explicitly approved external Agent or
   connects to a separately configured model/Agent transport. Detect actual integration
   support; never copy Pulse's API keys, assume access to an existing subscription, or
   silently enable a paid model. If unavailable, export a task/prompt for external use.
3. Native Pulse assistant directly discovers/invokes Forge authoring tools. Requires a
   documented upstream extension point; currently not proven feasible on the public SDK.
   Do not hook DLLs, patch the host, modify private memory, intercept MCP traffic or bypass
   authorization. An upstream proposal may request typed tool registration, cancellation,
   scoped context, explicit install approval and owner-lifetime handling. Interface names
   such as pulse.ai.tools, pulse.ai.providers, pulse.ai.context and
   pulse.extensions.authoring are illustrative proposals, not shipped contracts.

Official references:
[AI/MCP](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/docs/ai/mcp.md),
[developer tool catalog](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/src/app/extensions/developer_tool_catalog.h),
[MCP tool registration](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/src/ai_host/mcp_tools.cpp),
[native author MCP](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/tools/extensions/native_author_mcp.py),
[native SDK](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/sdk/native/README.md).

## 2. Proposed components

```text
External Agent / optional native Forge panel
    -> typed author MCP / authenticated local IPC
    -> author runtime (projects, plans, jobs, diagnostics, permissions)
    -> isolated build/test worker
    -> official package tools + verified SDK
    -> exported package / explicit isolated preview / approved install
```

Zig-first. Implement the author runtime and standalone CLI/MCP service before the native
panel. Reuse the tested [Shared Runtime](shared-runtime.md), shared/process and public SDK
wrappers; extend only where the authoring workflow requires it. Runtime budgets and process
ownership are not a substitute for OS-enforced containment of generated code. Official Python author tools may remain build-time dependencies.
No Rust/Cargo, AGENTS.md, private SDK access or duplicate AI runtime. Do not create empty
directories now. A future layout may separate tools/forge, shared/authoring and extensions/forge;
select the actual boundaries when implementing. The trusted UI/DLL must never load arbitrary
generated code into its own production process.

## 3. Request-to-package pipeline

Example: “Create an extension that shows source-language proportions, file count and total
size for the selected folder and exports CSV.”

- Discover supported SDK, host version, toolchain, target architecture and authoring prerequisites.
  Detect an existing native equivalent before proposing a new extension.
- Interpret request into an explicit plan: package ID, allowed scope, UI, file reads/writes,
  external processes, network, dependencies, limitations and acceptance tests. Show unsupported
  requirements instead of inventing SDK APIs. Select a trusted template.
- Create a new dedicated project, pin SDK/toolchain and save revisioned changes. Show diffs;
  do not modify existing projects or user files without explicit consent.
- Generate source and tests; validate against public contracts and build in a restricted worker.
  Treat build scripts, generated code, dependencies and tool outputs as untrusted.
- Return structured diagnostics and permit bounded repair iterations. Retain failure evidence,
  support cancel/resume and require new approval if the permitted scope expands.
- Test parsers, ownership, ABI and lifecycle; inspect the compiled binary, package manifest,
  file paths, resources, dependencies and hashes. A successful build is not runtime safety.
- Export a verified .pulse-ext using official author CLI. A preview requires separate approval
  and adequate OS-level containment; production install/enable and release are separate decisions.
- Report exactly what ran, what failed, what remains unverified, and source/package hashes.

Track job states such as planned, awaiting_approval, generating, building, testing, packaging,
ready_for_review, failed, cancelled, previewed and installed. Persist only necessary project/job
metadata; store logs with size/age limits. Bind approvals to immutable plan and artifact hashes;
invalidate approvals when source, package or permissions change. Never silently install a
different rebuild after approval.

## 4. Proposed MCP contract

These names are proposals, not present in Pulse or Pulse Extras.

| Tool | Responsibility |
| --- | --- |
| forge_sdk_discover | Read verified host/SDK/toolchain capabilities |
| forge_project_create | Create new project in authorized author root |
| forge_project_inspect | Return bounded project metadata and diffs |
| forge_project_patch | Apply bounded revision-checked patch |
| forge_project_build | Enqueue approved build in restricted worker |
| forge_project_test | Execute approved fixture/test plan |
| forge_job_status / forge_job_cancel | Job state, progress, cancellation |
| forge_diagnostics | Bounded structured error and log pages |
| forge_package_verify | Validate package and artifact identity |
| forge_package_export | Export verified package through approved destination |
| forge_preview_start / forge_preview_stop | Start/stop a contained test session, only when supported and approved |
| forge_install_request | Request user approval; no unconditional production install |

Version tool schemas; use typed arguments, stable error codes, bounded responses, opaque job
IDs and explicit project identity. No generic shell, unrestricted arbitrary-path writes, private
credential read, hidden permission escalation or arbitrary remote-code execution tool. Tools
that change state require authorization independently of discovery. MCP request cancellation
must stop owned work and release resources; cancellation is not rollback. Stdio stdout carries
protocol only; diagnostics go to stderr or bounded logs. If local IPC is needed, authenticate
the user/instance, restrict access, avoid ambient privileged endpoints, and handle disconnects
and duplicate requests. Tool-returned data and project contents are not trusted instructions.

## 5. Security and resource model

Native DLLs run with the host process privileges. ReleaseSafe, static analysis, a C ABI harness,
and a separate Pulse profile are **not security sandboxes**. A fresh profile protects settings,
not the OS or user files. Windows Job Objects control owned processes/resources, not filesystem
or network permissions.

- Generate/build/test untrusted code only within a dedicated author workspace and appropriate
  OS-enforced isolation. Use Windows Sandbox/VM or an explicitly verified equivalent for
  untrusted execution, with no writable host mounts, user credentials or signing secrets.
  If sufficient containment is unavailable, export source/package for review and do not execute
  generated DLLs or arbitrary build scripts automatically.
- Restrict paths using real handle/canonical identity checks and reparse-point defenses.
  Reject traversal, symlink/junction escapes, archive traversal, unsafe DLL dependencies,
  path collisions and time-of-check/time-of-use substitutions. Use atomic writes and safe
  staging; never overwrite existing user data as an implicit side effect.
- Use a pinned trusted compiler, bounded argv, controlled environment, process-tree ownership,
  finite timeout, memory/disk/output limits, bounded queues and repair iterations. Explicitly
  authorize dependency acquisition and network access; prefer offline trusted dependencies.
  Untrusted code must not run on a privileged CI or developer host.
- Show the plan, diff, capabilities, risks, dependency provenance, test results and exact
  artifact hash before preview/install. Native permission declarations are not a hard sandbox.
  Require affirmative user action before production install/enable. Do not pass an AI-supplied
  boolean as substitute for consent or bypass Pulse's existing confirmation rules.
- Do not send source, selected files, paths, credentials or logs to a model unless explicitly
  authorized for the chosen provider; minimize context and redact secrets. No telemetry by
  default. Keep API keys in approved OS credential storage; do not read Pulse's private config.
- Native panel work is asynchronous, cancellable, and bounded; no model requests, compilation
  or long-running process waits on the UI thread. Respect SDK owner-thread and unload contracts.
  On closure/deactivation detach/cancel according to explicit job policy; drain every plugin
  callback and worker before unloading. Do not terminate unrelated processes.
- Keep Forge-generated local package IDs distinct from official/community publisher identities.
  No publisher impersonation, automatic public release or access to release signing keys.
  Registry acceptance must be confirmed independently, especially for authoring tooling that
  intentionally executes external code.

## 6. Acceptance and staged delivery

F0: after shared runtime hardening and a real extension/package flow, implement standalone
Zig author CLI and separate stdio MCP, with a trusted minimal template and export-only pipeline.
Test request schema, path confinement, stale revisions, cancellation, timeout, output bounds,
missing tools, unsupported SDK and package integrity. Prove actual generated projects compile.

F1: bounded Agent orchestration and diagnostics; generated fixture project with independent
expected behavior, test failure/repair, no network/secret access unless approved, and no
unapproved execution. Exercise injection, malicious build files, resource exhaustion,
path escapes, crash recovery and log redaction. Use deterministic fixtures for normal CI,
not paid live model calls; opt-in live-model acceptance is separate.

F2: native Forge panel with authorized external Agent integration, progress/cancel/review,
zh/en, theme/DPI/resize, isolated preview only after containment validation. Test shutdown,
unload and broken/missing Agent transport. Confirm actual UI and package behavior, not just PID.

F3: upstream proposal for typed AI tool registration and permission integration. Implement
only against a released/documented interface and revalidate host and registry acceptance.

Forge does not block the first VCS release or the other independent extensions. Each step
requires source, test commands/results, build and artifact hashes, known gaps and actual
host evidence where applicable. See [roadmap](roadmap.md), [testing](testing.md) and
[release design](release.md).
