# Extension capabilities and performance evidence / 扩展功能与实测数据

This is an evidence index, not a release guarantee. Each result belongs to
its exact commit, runner and workload. Planned features are not measured
features. No benchmark row is copied forward to a newer build without
re-running the workload.

## Extension status

| Extension / component | Demonstrated capability | Evidence | Performance status |
| --- | --- | --- | --- |
| ABI probe (test only) | Native install, activate/deactivate, unload, command dispatch on Pulse 1.0.61 | [Host acceptance](host-compatibility.md) | Lifecycle acceptance; no throughput or load baseline |
| Hello Panel | Workspace/sidebar command and context panel on Pulse 1.0.61 | [Host compatibility](host-compatibility.md) | UI behavior only; no measured latency or memory baseline |
| VCS | Read-only Git, Jujutsu and Subversion providers, temporary repository integration | [Provider status](vcs-architecture.md), [CI](testing.md) | No comparable repository-scale throughput/latency benchmark |
| Companion | Classic V1/V2 WebP standalone runtime, event bridge, contained multi-instance model, verified staged import | [Runtime](openpets-spike.md), [Manager](companion-manager.md), [real import CI](https://github.com/strangelion/pulse-extras/actions/runs/45581496727) | 100 independent processes measured below; not 100 host-supervised instances |
| Companion market | V3 directory parsing and strict ZIP admission; actual online install and native page runtime wiring not complete | [Manager](companion-manager.md) | Download/installation throughput not measured |
| Convert / Inspect / Data / DevKit / Compare | Planned | [Scope](product-scope.md), [Roadmap](roadmap.md) | Not measured |
| Forge | Design only | [Design](forge-architecture.md) | Not measured |
| Shared Runtime | Ownership, quota, cancellation, process and teardown primitives | [Runtime](shared-runtime.md) | Not a separate shipping extension; no cross-extension load baseline |

## Companion: paired 100-process baseline

Source: [run 45564689154](https://github.com/strangelion/pulse-extras/actions/runs/45564689154),
commit [17a5642](https://github.com/strangelion/pulse-extras/commit/17a5642725236a263378e9f20da04cff5c2df2af),
2026-11-25 UTC, two successful Windows jobs
([mixed](https://github.com/strangelion/pulse-extras/actions/runs/45564689154/job/139036536662),
[synthetic](https://github.com/strangelion/pulse-extras/actions/runs/45564689154/job/139036537010)).
Values transcribed from the jobs' emitted summary JSON, not estimated from
the configured budgets. Both ran on hosted Windows runners with 4 logical
CPUs, ReleaseSafe, 100% scale, hidden windows, 30 seconds and 31 samples
after all children reported first-frame readiness. Mixed uses static
libwebp and two original solid-color fixture sources (50 V1 package and
50 V2 raw atlas); synthetic uses the synthetic V2 atlas. The two jobs use
separate runners, not a controlled A/B comparison.

| Metric | Synthetic hidden | Mixed hidden |
| --- | ---: | ---: |
| Requested / started / ready | 100 / 100 / 100 | 100 / 100 / 100 |
| Distinct source slots | 1 | 2 |
| All ready (seconds) | 2.828 | 2.906 |
| Sampling duration / samples | 30 s / 31 | 30 s / 31 |
| Graceful / forced / failed | 100 / 0 / 0 | 100 / 0 / 0 |
| Shutdown reports | 100 | 100 |
| Peak aggregate private bytes | 1,584,615,424 | 1,461,501,952 |
| Peak aggregate working set (bytes) | 2,240,479,232 | 2,127,847,424 |
| Peak sum of per-process peak working sets (bytes) | 2,240,479,232 | 2,173,259,776 |
| Max individual private bytes | 15,896,576 | 15,872,000 |
| Peak aggregate page fault count | 554,664 | 595,777 |
| Peak handles | 10,806 | 10,650 |
| Peak threads | 400 | 400 |
| Peak GDI objects | 200 | 200 |
| Peak USER objects | 300 | 300 |
| Peak sampled CPU (% of one core) | 10.9375% | 9.375% |
| Peak sampled CPU (% of machine) | 2.734375% | 2.34375% |
| Cumulative CPU (seconds) | 3.734375 | 3.109375 |
| Read bytes / operations | 0 / 0 | 32,500 / 400 |
| Write bytes / operations | 2,500 / 100 | 2,500 / 100 |
| Initial available physical bytes | 14,310,268,928 | 14,315,057,152 |
| Final available physical bytes | 14,329,864,192 | 14,294,908,928 |
| Max tracked heap peak (bytes) | 14,057,472 | 15,932,243 |
| Sum of individual tracked heap peaks (bytes) | 1,405,747,200 | 1,449,453,300 |
| Tracked heap denials | 0 | 0 |

For orientation, divide bytes by 1,048,576 for MiB or 1,073,741,824 for
GiB. Mixed peak aggregate private memory is about 1.36 GiB; working set
about 1.98 GiB; the maximum individual private memory is about 15.14 MiB.
Dividing the aggregate private-byte peak by 100 gives about 13.94 MiB per
process at that sample, not a measured maximum for every process. A summed
working set can include shared pages multiple times. Individual peak
values need not occur simultaneously. CPU is summed child CPU, not total
host utilization; sampled peaks do not describe instantaneous render
latency. Available physical memory includes unrelated OS activity.

### Mixed source allocation attribution

| Source | Instances | Max tracked heap peak (bytes) | Sum of individual peaks (bytes) |
| --- | ---: | ---: | ---: |
| Source 0: V2 raw WebP | 50 | 15,932,243 | 796,612,150 |
| Source 1: V1 package | 50 | 13,056,823 | 652,841,150 |

### Steady-state trend

First/last up-to-five-sample medians from the emitted summary, not the
first and last raw samples. Negative deltas show the measured change
during this short observation period, not proof of absence of leaks.

| Metric | Synthetic first | Synthetic last | Synthetic delta | Mixed first | Mixed last | Mixed delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Private bytes | 1,584,615,424 | 1,574,866,944 | -9,748,480 | 1,461,501,952 | 1,451,655,168 | -9,846,784 |
| Working set (bytes) | 2,240,397,312 | 2,235,613,184 | -4,784,128 | 2,127,089,664 | 2,122,932,224 | -4,157,440 |
| Handles | 10,806 | 10,806 | 0 | 10,650 | 10,650 | 0 |
| Threads | 400 | 103 | -297 | 400 | 100 | -300 |
| GDI objects | 200 | 200 | 0 | 200 | 200 | 0 |
| USER objects | 300 | 300 | 0 | 300 | 300 | 0 |

### Earlier checkpoints and failures

| Run | Workload | Outcome / selected measurements |
| --- | --- | --- |
| [45558274357](https://github.com/strangelion/pulse-extras/actions/runs/45558274357), ca607d3 | 100 synthetic hidden | 100 ready/graceful; 2.797 s ready; private 1,584,070,656 B; WS 2,239,983,616 B |
| [45560501033](https://github.com/strangelion/pulse-extras/actions/runs/45560501033) | 100 synthetic + 100 mixed WIC | Synthetic passed; mixed 0/100 ready, WIC 0x88982f8b; do not treat as a successful benchmark |
| [45562943899](https://github.com/strangelion/pulse-extras/actions/runs/45562943899) | 100 mixed static WebP | 100 ready/graceful, 2.781 s, private 1,463,508,992 B |
| [45563839194](https://github.com/strangelion/pulse-extras/actions/runs/45563839194), c63271d | 100 mixed static WebP after allocator routing | 100 ready/graceful; 3.203 s; private 1,461,940,224 B; WS 2,127,077,376 B; 0 denials; peak machine CPU 2.34375% |
| [45564689154](https://github.com/strangelion/pulse-extras/actions/runs/45564689154), 17a5642 | 100 synthetic and 100 mixed | Detailed paired baseline above |
| [45581496727](https://github.com/strangelion/pulse-extras/actions/runs/45581496727), af52c35 | Real approved helper import + durable reload | Full regression passed; not a 100-process workload |
| [45582694160](https://github.com/strangelion/pulse-extras/actions/runs/45582694160), 419a106 | Automatic 2-child codec/import preflight | Passed; not a 100-process workload |

WIC failures remain part of the evidence. The static decoder profile
does not establish WIC compatibility. The 100-process harness launches
independent processes, not children owned by one Pulse host/supervisor.
The fixtures have simple pixel content, not 100 unique complex pets.
Hidden rendering does not measure visible compositor cost, frame-time
percentiles, GPU or VRAM, interaction latency, or long-term stability.

## Capacity is not benchmark evidence

| Limit | Meaning |
| --- | --- |
| 2,147,483,647 | Configured signed integer maximum; not preallocated |
| 1024 | Logical/native storage slots; not measured simultaneous processes |
| 128 MiB | Provisional per-supervised-child committed-memory ceiling |
| 48 MiB | Per-child tracked allocator quota; not OS private bytes or working set |
| 512 | Managed inventory record capacity |
| 100 | Current full independent-child benchmark workload |

Effective admission depends on backend slots, configured count, aggregate
commit reservations and physical/commit headroom. 1024 simultaneous
128 MiB reservations would require 128 GiB of reservation budget, not
necessarily that much physical memory. The separate native supervisor
tests exercise small real child groups, logical quota and confirmed reap.
No 1024-real-process or INT_MAX capacity claim.

## Reproduce and preserve measurements

On Windows with the pinned Zig and Python versions:

```powershell
zig build pet-demo -Doptimize=ReleaseSafe --summary all
python tests/companion/pet_stress.py --count 100 --seconds 30 --output zig-out/stress-synthetic
python scripts/install_pet_webp.py
python scripts/install_pet_webp.py --check
zig build pet-demo -Doptimize=ReleaseSafe -Dpet-libwebp=true --summary all
python tests/companion/pet_stress_fixtures.py zig-out/bench-fixtures
python tests/companion/pet_stress.py --count 100 --seconds 30 --package zig-out/bench-fixtures/fixture-v1 fixture-v1 --webp 2 zig-out/bench-fixtures/fixture-v2.webp --output zig-out/stress-mixed
```

Use fresh output paths, never overwrite another run's results. The separate
Companion stress benchmark workflow allows manual profile/count/duration
selection; push runs perform only the lightweight probe. Logs and artifacts
contain summary JSON, sampled resource CSV and shutdown diagnostics; see
[workflow](../.github/workflows/pet-stress.yml). Artifact retention is
currently 14 days; this checked-in table preserves selected numerical
results, not the full raw traces. For subsequent benchmark checkpoints,
record the date, exact revision/run/job, runner/CPU, decoder, visibility,
source mix, scale, duration, readiness, resources, failures, raw artifact
reference and limitations. Do not publish user assets, personal paths,
credentials or raw logs containing private content.

## Next performance evidence to collect

- Companion: diverse permitted WebP packages; repeated cold/warm startup,
  actual 100-child manager workload, visible desktop frame time (p50/p95/p99),
  GPU/VRAM where available, 30-minute/2-hour soak, repeated start/stop and
  import/cancel recovery. No automatic heavy CI expansion.
- Market: bounded download throughput, cache hit rate, archive expansion
  and import duration/peak memory, cancelled and corrupt package recovery.
- VCS: fixed synthetic repositories at multiple sizes; cold/warm status
  latency, cancellation, memory and unchanged repository state.
- Native UI: settings open/search/scroll latency, host/child process memory
  separately, multiple extensions loaded/unloaded, resource drain.

Use reproducible workloads and report failures as well as successes. Do
not invent scores for planned extensions or set hard performance gates
from a single observation. Compare like-for-like runner and workload
before claiming improvements.

The optional decoder uses `.local/deps/libwebp-1.6.0` and its pinned archive,
not `zig-out/deps`. The installer is repeatable and can stage from the verified
local archive without network access. Builds with `-Dpet-libwebp=true` check
both the archive and source tree before compilation and never download. If a
staged source differs, move it aside and rerun the installer; a corrupt archive
must likewise be moved aside before downloading again. The default WIC build
requires neither Python for this check nor libwebp.
