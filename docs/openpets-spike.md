# OpenPets interoperability spike / 兼容性实验

Experimental branch only. No shipping extension or network access is added.
Baseline [OpenPets 2f02bb0](https://github.com/OpenPetsHQ/openpets/tree/2f02bb04d872dec6923a47572343305235c63482), MIT. Reference contract, no copied upstream implementation:
[client protocol](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/packages/client/src/protocol.ts),
[server handler](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/apps/desktop/src/local-ipc-request-handler.ts),
[IPC docs](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/docs/ipc.md).

Observed: v1 JSON-line protocol; Windows named pipe, Unix socket, optional TCP.
Max message 16 KiB; discovery includes endpoint, protocol, token, PID/platform.
The app generates base64url token; hello/status and leased pet.react use the
result envelopes exercised in the tests. Lease TTL is 15s, not a permanent claim.
No generic command execution is needed.

## Experiment

shared/companion/openpets_protocol.zig implements a bounded pure wire codec
for hello/status/leased react only. No transport, filesystem access, IPC endpoint
ownership, lease acquisition or live OpenPets calls. Strict ASCII atom subset,
request-ID and response shape checks, no arbitrary speech, media, install or
remote transport. Tests use synthetic fixtures matching the pinned handler;
they do not establish interoperability with a running server. Error details are
not propagated or logged. No new dependencies/submodules.

Run `zig test shared/companion/openpets_protocol.zig` or the existing full
`zig build test --summary all`. The module is included in the test source list,
not compiled into a shipping DLL. Zig 0.17.1 and live OpenPets are unavailable in
the authoring environment; GitHub CI is required before merge. No test result is
claimed here.

## Next gate

After codec checks pass, verify against a real approved Windows OpenPets
instance. Add safe discovery validation (trusted owner/ACL, reparse defense,
bounded reads, never log token), local named-pipe transport only with
finite connection/read/write/cancel deadlines and owned handles, test with
an isolated mock named pipe, then actual hello/status. Only then implement
explicit lease acquire/heartbeat/release and leased reactions with user approval;
no automatic default-pet override or LAN/remote mode. Use shared runtime once
its lifecycle is validated; do not run blocking work on Pulse UI thread.
Consider compatibility of data-only pet packages (bounded parsing/decoding,
asset licensing) separately. Native rendering needs actual host SDK verification.
Do not port Electron/JS plugins, general Agent systems or claim full compatibility.
An optional backend is preferable to an OpenPets clone; a separate native
backend is justified only by measured usability and resource gains.
