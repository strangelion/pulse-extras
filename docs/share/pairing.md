# Dynamic pairing code — implementation contract

Status: local policy and RFC-vector tests implemented. No network pairing
listener, PAKE adapter, UI code display or new trust path is enabled yet.
Manual certificate fingerprint pairing remains the only available enrollment.
Do not release a short-code flow until the integration gates below pass.

## Identity and lifetime

- Existing ECDSA device identity remains DPAPI-protected. Preserve existing
  exact certificate SHA-256 trust records and pinned TLS 1.3 transport.
- Network interface addresses are only connection hints. MAC, hardware ID,
  time, host name and public fingerprints are not secret key material.
- A new explicit pairing window uses 32 random bytes in memory, with
  HMAC-SHA256 TOTP dynamic truncation (RFC 6238), eight decimal digits,
  60-second time steps and a maximum 180-second overall lifetime.
- The displaying device is the time authority; the other user enters the
  displayed code. No synchronized client clock or seed distribution.
  Monotonic elapsed time prevents wall-clock rollback from extending the
  window. Time-step boundary may shorten the first code lifetime.
- Reserve an attempt before invoking PAKE, serialize attempts, count all
  failures across code rotations, cap at five. No previous-step fallback.
  Expire an in-flight attempt at its code boundary. Success, exhaustion,
  cancellation, panel close and deactivation close the window. The seed
  is cleared on explicit close/expiry observation; do not claim Go string
  memory zeroization. The future adapter must enforce timer-driven close.
- Prefer an ephemeral seed over a persistent DPAPI seed: restarting pairing
  must generate a new secret. Do not persist, log, broadcast or put a code
  into process arguments, ordinary task progress, settings or history.

## PAKE dependency decision and open gate

Use a reviewed balanced PAKE implementation; do not create elliptic curve
protocols or use an unauthenticated TLS connection carrying a raw code or
code-derived MAC. Such constructions can expose the short code to active
or offline guessing.

Candidates inspected 2026-11-27:

- https://pkg.go.dev/github.com/backkem/spake2-go implements RFC 9382 and
  reports official vector testing, but explicitly states no formal security
  review/audit. Not approved for default pairing.
- https://github.com/1Password/cpace reports a Cure53 audit and tracks
  revision 6 of the CPace draft. Candidate for a separate bounded native
  adapter; verify audit scope, exact revision, current advisories, license,
  dependency lock, vectors, Windows build/ABI and lifecycle cost before
  selecting it. No Rust dependency is introduced in this commit.

A vetted Go dependency is preferable if it meets the same criteria.
RFC 9382 is informational, not itself proof that a library is reviewed.
See https://www.rfc-editor.org/rfc/rfc9382 and
https://www.rfc-editor.org/rfc/rfc6238 for specifications.

## Integration requirements

Separate pairing from the file-transfer protocol and from UDP discovery.
Explicit opt-in, on-link address binding and a bounded listener only. Pairing
messages must be versioned, bounded and rejected on malformed input. Discovery
is untrusted and never grants permissions. No automatic downgrade to a raw
PIN protocol.

The PAKE must mutually confirm its session key and authenticate both exact
certificate fingerprints, roles and protocol context. Authenticate and bind
proof of possession of the corresponding certificate private keys before
enrollment. An untrusted response, a public fingerprint or a matching
transport address is not sufficient. Use the selected library's prescribed
key-confirmation mechanism, not a new homemade protocol.

After authenticated identity binding, show both device identities and require
explicit user consent. Save only the verified peer pin using the existing
exclusive-write policy. On interrupted enrollment either side may have no
record or a partial bilateral result; report it and never silently overwrite.
The dynamic code is not a file approval. Existing per-file confirmation and
no-overwrite commit remain mandatory. Session-only pairing and permanent
pairing must have distinguishable UI and lifetime.

The UI needs a private display path for codes and a separate local input path
for user-entered codes; current generic task status/history cannot carry them.
Default mode can change only once the actual host integration is accepted.

## Acceptance gates

Local policy: RFC 6238 SHA-256 vectors, rotation, expiration, concurrent
attempt rejection, stale attempt ID, successful consumption, attempt limit,
independent seeds and explicit close.

Future integration: correct and incorrect codes, expiry during handshake,
replay, mismatched identities, role confusion, interrupted pairing, rejection
on either end, rate limits across rotations, no code in logs/settings/argv,
two-device enrollment and restart, revocation, existing manual pairing and
TLS transfer regression. CI must run exact locked dependency tests and
Windows integration; real Pulse UI and two-PC acceptance remain required.

## Experimental authentication adapter

The branch now contains a separate Rust executable under shared/share/pake,
using 1Password/cpace at 7e2e42c7d359969f4356292c2bd2cf3ff6eeeecc (MIT OR Apache-2.0).
The lockfile is derived from the upstream dependency lock with the exact git
revision and wrapper package recorded; Cargo --locked must validate it.
The helper implements no network or file operations, accepts one bounded
local stdin exchange, and returns only confirmation status, never a key.
Go integration binds both ordered certificate pins and a TLS 1.3 exporter
into the library's channel identifier; a separate pairing ALPN prevents
confusion with the file-transfer protocol. CI runs actual two-process adapter
exchanges over TLS loopback for matching code, wrong code and wrong certificate
context. The experimental adapter is not packaged or invoked by the normal
LAN tool or Pulse host. No trust-store write or new listener is enabled.

The upstream README reports a 2022 Cure53 review of the library, but the
report was not independently retrieved in this session and its scope cannot
be assumed to include this exact revision or our wrapper. The library tracks
CPace draft 06, not later draft 21 (April 2026). Do not advertise current-draft
interoperability. CI uses runner-installed Rust for this experiment; pin the
toolchain and audit the dependency tree before inclusion in acceptance packages.
Still required: pair-window integration, private code display/input, explicit
bilateral enrollment consent, verified helper packaging and resource lifecycle,
additional replay/interruption tests, and physical two-PC acceptance.
