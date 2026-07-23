# Benchmark: Foundry Hosted Agents, .NET 10 LTS vs Python 3.12

> Extension to the [Foundry Hosted Agent IP Protection PoC](./README.md).
> This document contains only the fresh benchmark matrix collected after the
> .NET 10 LTS move and the shared Phase A / Phase B benchmark switch.

## Scope

We compare two Foundry hosted agents deployed in the same Foundry project,
region, quota, Key Vault configuration and container resource envelope:

| Aspect | `ippoc-agentcsharp` | `ippoc-agentpython` |
|---|---|---|
| Language | C# 14 | Python 3.12 |
| Runtime | .NET 10 LTS (`aspnet:10.0`) | CPython 3.12 (`python:3.12-slim`) |
| Server SDK | `Azure.AI.AgentServer.Responses` 1.0.0-beta.3 | `azure-ai-agentserver-responses` 1.0.0b8 |
| Model mode | `BENCHMARK_MODE=phase-b` | `BENCHMARK_MODE=phase-b` |
| No-model mode | `BENCHMARK_MODE=phase-a` | `BENCHMARK_MODE=phase-a` |
| Handler | [`ProtectedResponseHandler.cs`](src/AgentCSharp/ProtectedResponseHandler.cs) | [`protected_response_handler.py`](src/AgentPython/protected_response_handler.py) |

Python 3.12 is used deliberately as the production-representative baseline.
As of July 2026, Python 3.14 is the latest stable series, Python 3.15 is still
pre-release, and Python 3.13 is stable with growing adoption. For this article,
3.12 is the more useful comparison point because it remains the version many
teams actually run in production today; the benchmark is about realistic
hosted-agent deployment behavior, not testing the newest interpreter available.

## Modes

| Mode | Meaning | Expected response path |
|---|---|---|
| Phase A | No model call | Guardrails + opacity + deterministic `model_call=false` body |
| Phase B | Real model call | Guardrails + opacity + `gpt-5-mini` with `reasoning_effort=minimal` |

Phase A isolates hosted-agent and runtime overhead while preserving the same
opacity latency envelope. Phase B measures the full hosted-agent plus model
round trip. The benchmark does not compare model quality.

## Methodology

- Endpoint: Foundry hosted Responses protocol, `POST /responses`.
- Request body: `{ "input": "benchmark ping: what is the capital of France?", "store": false, "stream": false }`.
- Authentication: Azure AD token for `https://ai.azure.com`, cached and refreshed by [`scripts/benchmark.ps1`](scripts/benchmark.ps1).
- Runs: `N=10`, `N=100`, `N=1000` for both agents in Phase A and Phase B.
- Pacing: sequential runs use `-Parallel 1` and `-TargetRps 0.15` for both-agent interleaving.
- Retries: `-MaxRetries 5`; 401/403 refresh token once, 429/503 use bounded backoff.
- Artifacts: fresh outputs only under `out/bench/run-*/`.

## Run Commands

```powershell
# Phase B: with model
azd env set BENCHMARK_MODE phase-b
azd deploy ippoc-agentcsharp --no-prompt
azd deploy ippoc-agentpython --no-prompt
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 10   -Agent both -TargetRps 0.15 -Warmup 0 -MaxRetries 5
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 100  -Agent both -TargetRps 0.15 -Warmup 0 -MaxRetries 5
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 1000 -Agent both -TargetRps 0.15 -Warmup 0 -MaxRetries 5

# Phase A: no model
azd env set BENCHMARK_MODE phase-a
azd deploy ippoc-agentcsharp --no-prompt
azd deploy ippoc-agentpython --no-prompt
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 10   -Agent both -TargetRps 0.15 -Warmup 0 -MaxRetries 5
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 100  -Agent both -TargetRps 0.15 -Warmup 0 -MaxRetries 5
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 1000 -Agent both -TargetRps 0.15 -Warmup 0 -MaxRetries 5
```

## Results

### Phase B: with `gpt-5-mini`

#### N = 10

Run: [out/bench/run-20260718-100915/summary.md](out/bench/run-20260718-100915/summary.md)

| setting | value |
|---|---|
| n | 10 |
| parallel | 1 |
| target_rps | 0.15 |
| warmup | 0 |
| max_retries | 5 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 10 | 10 |
| n_success | 10 | 10 |
| n_failed | n/a | n/a |
| success_rate_pct | 100 | 100 |
| wallclock_s | 35,111 | 46,699 |
| throughput_rps | 0,285 | 0,214 |
| latency_ms_mean | 3486,45 | 4669,03 |
| latency_ms_stddev | 219,39 | 252,75 |
| latency_ms_min | 3334,33 | 4392,15 |
| latency_ms_p50 | 3388,85 | 4638,68 |
| latency_ms_p90 | 3748,48 | 4929,51 |
| latency_ms_p95 | 3886,8 | 5077,88 |
| latency_ms_p99 | 3997,47 | 5196,58 |
| latency_ms_max | 4025,13 | 5226,25 |
| response_bytes_mean | 825 | 830 |
| top_errors | n/a | n/a |

#### N = 100

Run: [out/bench/run-20260718-101150/summary.md](out/bench/run-20260718-101150/summary.md)

| setting | value |
|---|---|
| n | 100 |
| parallel | 1 |
| target_rps | 0.15 |
| warmup | 0 |
| max_retries | 5 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 100 | 100 |
| n_success | 99 | 99 |
| n_failed | 1 | 1 |
| success_rate_pct | 99 | 99 |
| wallclock_s | 364,836 | 467,137 |
| throughput_rps | 0,274 | 0,214 |
| latency_ms_mean | 3628,23 | 4666,31 |
| latency_ms_stddev | 711,84 | 371,63 |
| latency_ms_min | 3116,29 | 4136,06 |
| latency_ms_p50 | 3538,72 | 4597,36 |
| latency_ms_p90 | 3867,74 | 4942,49 |
| latency_ms_p95 | 3994,89 | 5366,6 |
| latency_ms_p99 | 4435,46 | 5748,28 |
| latency_ms_max | 10304,46 | 6854,01 |
| response_bytes_mean | 824 | 831 |
| top_errors | 1x http_500 | 1x http_500 |

#### N = 1000

Run: [out/bench/run-20260718-103717/summary.md](out/bench/run-20260718-103717/summary.md)

| setting | value |
|---|---|
| n | 1000 |
| parallel | 1 |
| target_rps | 0.15 |
| warmup | 0 |
| max_retries | 5 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 1000 | 1000 |
| n_success | 999 | 999 |
| n_failed | 1 | 1 |
| success_rate_pct | 99,9 | 99,9 |
| wallclock_s | 3552,526 | 4665,497 |
| throughput_rps | 0,281 | 0,214 |
| latency_ms_mean | 3548,64 | 4664,65 |
| latency_ms_stddev | 306,05 | 577,13 |
| latency_ms_min | 3040,44 | 4017,44 |
| latency_ms_p50 | 3511,81 | 4584,77 |
| latency_ms_p90 | 3801,09 | 5062,28 |
| latency_ms_p95 | 3933,12 | 5265,4 |
| latency_ms_p99 | 4263 | 5619,82 |
| latency_ms_max | 10385,49 | 13720,66 |
| response_bytes_mean | 824 | 832 |
| top_errors | 1x http_500 | 1x http_500 |

### Phase A: no model call

#### N = 10

Run: [out/bench/run-20260718-144815/summary.md](out/bench/run-20260718-144815/summary.md)

| setting | value |
|---|---|
| n | 10 |
| parallel | 1 |
| target_rps | 0.15 |
| warmup | 0 |
| max_retries | 5 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 10 | 10 |
| n_success | 10 | 10 |
| n_failed | n/a | n/a |
| success_rate_pct | 100 | 100 |
| wallclock_s | 33,41 | 47,702 |
| throughput_rps | 0,299 | 0,21 |
| latency_ms_mean | 3335,24 | 4769,67 |
| latency_ms_stddev | 174,1 | 433,01 |
| latency_ms_min | 3111,8 | 4234,2 |
| latency_ms_p50 | 3344,17 | 4690,94 |
| latency_ms_p90 | 3513,02 | 5383,79 |
| latency_ms_p95 | 3557,55 | 5451,58 |
| latency_ms_p99 | 3593,17 | 5505,8 |
| latency_ms_max | 3602,08 | 5519,36 |
| response_bytes_mean | 882 | 890 |
| top_errors | n/a | n/a |

#### N = 100

Run: [out/bench/run-20260718-145047/summary.md](out/bench/run-20260718-145047/summary.md)

| setting | value |
|---|---|
| n | 100 |
| parallel | 1 |
| target_rps | 0.15 |
| warmup | 0 |
| max_retries | 5 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 100 | 100 |
| n_success | 100 | 100 |
| n_failed | n/a | n/a |
| success_rate_pct | 100 | 100 |
| wallclock_s | 342,325 | 457,794 |
| throughput_rps | 0,292 | 0,218 |
| latency_ms_mean | 3421,75 | 4577,6 |
| latency_ms_stddev | 725,15 | 310,63 |
| latency_ms_min | 2855,87 | 4055,01 |
| latency_ms_p50 | 3316,08 | 4518,39 |
| latency_ms_p90 | 3677,38 | 5034,09 |
| latency_ms_p95 | 3767,08 | 5141,17 |
| latency_ms_p99 | 4642,09 | 5403,97 |
| latency_ms_max | 10093,84 | 5583,04 |
| response_bytes_mean | 882 | 890 |
| top_errors | n/a | n/a |

#### N = 1000

Run: [out/bench/run-20260718-151536/summary.md](out/bench/run-20260718-151536/summary.md)

| setting | value |
|---|---|
| n | 1000 |
| parallel | 1 |
| target_rps | 0.15 |
| warmup | 0 |
| max_retries | 5 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 1000 | 1000 |
| n_success | 999 | 1000 |
| n_failed | 1 | n/a |
| success_rate_pct | 99,9 | 100 |
| wallclock_s | 3377,802 | 4560,496 |
| throughput_rps | 0,296 | 0,219 |
| latency_ms_mean | 3376,79 | 4560,19 |
| latency_ms_stddev | 419,93 | 431,42 |
| latency_ms_min | 2553 | 3834,03 |
| latency_ms_p50 | 3353,36 | 4505,58 |
| latency_ms_p90 | 3653,54 | 4980,04 |
| latency_ms_p95 | 3748,2 | 5214,12 |
| latency_ms_p99 | 4083,78 | 5600,4 |
| latency_ms_max | 11452,36 | 11726,09 |
| response_bytes_mean | 882 | 890 |
| top_errors | 1x http_500 | n/a |

## Notes

- All current C# results are from .NET 10 LTS, not .NET 9.
- Previous benchmark artifacts were removed before this run set.
- Python results use Python 3.12 because it is the production-representative baseline today, even though Python 3.14 is the newest stable series.
- Phase A and Phase B use the same deployed image family; only `BENCHMARK_MODE` changes.
- The long runs no longer show the previous AAD-token-expiry failure mode (`http_403` after token expiry). Remaining failures are isolated `http_500` responses from the hosted-agent path.
- Token usage is `n/a` in these summaries because the current Responses wire envelope does not expose model `usage` back to the harness.

## Appendix: Phase A with two client workers

This appendix is a small concurrency probe for the production baseline images,
not a replacement for the main sequential matrix. Both agents were redeployed
with `BENCHMARK_MODE=phase-a`, so the run does not call the model. The command
uses two client workers and no artificial pacing:

```powershell
azd env set BENCHMARK_MODE phase-a
azd deploy ippoc-agentcsharp --no-prompt
azd deploy ippoc-agentpython --no-prompt
pwsh -NoProfile -File ./scripts/benchmark.ps1 -N 20 -Agent both -Parallel 2 -TargetRps 0 -Warmup 0 -MaxRetries 5 -RequestTimeoutSec 30
```

Run: [out/bench/run-20260722-235524/summary.md](out/bench/run-20260722-235524/summary.md)

| setting | value |
|---|---|
| mode | Phase A, no model call |
| n | 20 |
| parallel | 2 |
| target_rps | 0 |
| warmup | 0 |
| max_retries | 5 |
| request_timeout_sec | 30 |

| metric | csharp | python |
|---|---:|---:|
| n_total | 20 | 20 |
| n_success | 20 | 20 |
| n_failed | n/a | n/a |
| success_rate_pct | 100 | 100 |
| wallclock_s | 65.533 | 83.995 |
| throughput_rps | 0.305 | 0.238 |
| latency_ms_mean | 6522.03 | 8352.04 |
| latency_ms_stddev | 445.86 | 805.27 |
| latency_ms_min | 5813.41 | 7319.34 |
| latency_ms_p50 | 6618.95 | 8232.15 |
| latency_ms_p90 | 6935.72 | 9134.78 |
| latency_ms_p95 | 7001.32 | 10253.49 |
| latency_ms_p99 | 7420.72 | 10297.4 |
| latency_ms_max | 7525.57 | 10308.38 |
| response_bytes_mean | 882 | 890 |
| top_errors | n/a | n/a |

With two client workers and no model call, both stacks complete 20/20 requests.
C# keeps the lower observed latency and higher throughput in this small run
(~0.305 rps vs ~0.238 rps). The absolute latencies are higher than the main
single-worker Phase A table because this probe intentionally overlaps requests;
it mainly shows that the same relative ordering remains visible under light
client concurrency.

For the Python baseline specifically, the following table compares a 20-sample
slice from the normal CPython 3.12 image with one client worker against the
20-call two-worker run above. Both rows use the production baseline image with
the regular GIL, not the no-GIL experiment.

| Python baseline slice | run | samples | parallel | target_rps | success | mean_ms | p50_ms | p95_ms | p99_ms | max_ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| CPython 3.12, GIL, first 20 Phase A calls from `N=100` | [out/bench/run-20260718-145047/python.csv](out/bench/run-20260718-145047/python.csv) | 20 | 1 | 0.15 | 20/20 | 4590.73 | 4602.88 | 5009.00 | 5176.76 | 5218.70 |
| CPython 3.12, GIL, Phase A two-worker probe | [out/bench/run-20260722-235524/python.csv](out/bench/run-20260722-235524/python.csv) | 20 | 2 | 0 | 20/20 | 8352.04 | 8232.15 | 10253.49 | 10297.40 | 10308.38 |

The matching C# production-baseline slice is shown below with the same shape,
so the concurrency effect is visible for both stacks. These rows are both .NET
10 LTS; the only difference is the client-side request shape.

| C# baseline slice | run | samples | parallel | target_rps | success | mean_ms | p50_ms | p95_ms | p99_ms | max_ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C# 14 / .NET 10, first 20 Phase A calls from `N=100` | [out/bench/run-20260718-145047/csharp.csv](out/bench/run-20260718-145047/csharp.csv) | 20 | 1 | 0.15 | 20/20 | 3295.11 | 3256.30 | 3606.20 | 3937.29 | 4020.06 |
| C# 14 / .NET 10, Phase A two-worker probe | [out/bench/run-20260722-235524/csharp.csv](out/bench/run-20260722-235524/csharp.csv) | 20 | 2 | 0 | 20/20 | 6522.03 | 6618.95 | 7001.32 | 7420.72 | 7525.57 |

The two-worker row is useful as a light concurrency probe, but not as a claim
that either runtime became intrinsically slower. It changes the client-side
shape of the test: requests overlap, there is no pacing, and the hosted-agent
path has more in-flight work at once. The fair reading is narrower: under this
two-worker probe both containers remain reliable, but per-call latency rises
because the bottleneck is the hosted-agent/proxy/opacity path rather than local
CPU execution. This is also the expected behavior for both GIL and no-GIL
runtimes: concurrency is not the same thing as making each individual request
faster. It can improve aggregate throughput when there is spare capacity, but it
can also increase per-request latency when the shared hosted path is already the
dominant cost.

## Appendix: Python free-threaded/no-GIL container

This appendix is an experimental control run, not the production baseline. The
Python agent was temporarily redeployed with a custom CPython free-threaded
build from [src/AgentPython/Dockerfile.nogil](src/AgentPython/Dockerfile.nogil):

| item | value |
|---|---|
| ACR image | `ippocacroqxs25zqctwd2.azurecr.io/agentpython:nogil-3.14.0-20260722` |
| digest | `sha256:f9a501c3687cec6d4506db6bec2904003430e26a1dcd3ba35287f87ce8548326` |
| Python build | CPython 3.14.0 configured with `--disable-gil` |
| Base image | `debian:bookworm-slim` |
| Deployment scope | temporary `ippoc-agentpython` redeploy only |

This is intentionally not a headline benchmark. Free-threaded CPython is still
much less representative of production Python deployments than regular CPython
3.12 with the GIL. The dependency ecosystem is also less mature for this path:
the attempted CPython 3.13 free-threaded image failed during build because CFFI
does not support that free-threaded runtime. Using CPython 3.14 solved the build,
but it also changed the interpreter version, base image, and wheel set, so it is
not an apples-to-apples runtime comparison with the production Python 3.12 image.

The workload itself is another reason not to over-read no-GIL results. Removing
the GIL is most relevant for CPU-bound Python threads. This benchmark is dominated
by hosted-agent/proxy/network latency and the deliberate opacity delay, with very
little local Python CPU work. A no-GIL image can therefore be a useful objection
handler, but it should remain a side control rather than the main story.

CPython 3.13 free-threaded was also attempted first, but the dependency graph
failed during image build because CFFI does not support the free-threaded build
of CPython 3.13. The experiment therefore uses CPython 3.14 free-threaded,
where the dependency set installed successfully with `cp314t` wheels.

The benchmark harness was extended with `-RequestTimeoutSec` and sequential
progress logging so long hosted-agent runs cannot sit silently forever on a
stalled HTTP call. The production endpoint was restored afterwards to
`agentpython:v12` with `BENCHMARK_MODE=phase-b`.

### Mini comparison: completed `N=10` runs only

This section intentionally keeps only completed `N=10` runs. It is a mini probe,
not a statistical benchmark, but even with 10 calls the direction is visible:
the free-threaded Python image does not change the latency story, and the C#
production baseline remains the lower-latency reference on the same hosted-agent
path. The incomplete `N=100` and `N=1000` no-GIL attempts are omitted here to
avoid mixing completed summaries with progress-only logs.

### Phase B: with `gpt-5-mini`

| runtime | run | samples | parallel | target_rps | success | wallclock_s | throughput_rps | mean_ms | p50_ms | p95_ms | p99_ms | max_ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C# 14 / .NET 10 | [out/bench/run-20260718-100915/summary.md](out/bench/run-20260718-100915/summary.md) | 10 | 1 | 0.15 | 10/10 | 35.111 | 0.285 | 3486.45 | 3388.85 | 3886.80 | 3997.47 | 4025.13 |
| CPython 3.12, GIL | [out/bench/run-20260718-100915/summary.md](out/bench/run-20260718-100915/summary.md) | 10 | 1 | 0.15 | 10/10 | 46.699 | 0.214 | 4669.03 | 4638.68 | 5077.88 | 5196.58 | 5226.25 |
| CPython 3.14 free-threaded/no-GIL | [out/bench/run-20260722-181047/summary.md](out/bench/run-20260722-181047/summary.md) | 10 | 1 | 0.15 | 10/10 | 64.373 | 0.155 | 4757.49 | 4643.59 | 5434.28 | 5658.17 | 5714.14 |

### Phase A: without model call

| runtime | run | samples | parallel | target_rps | success | wallclock_s | throughput_rps | mean_ms | p50_ms | p95_ms | p99_ms | max_ms |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| C# 14 / .NET 10 | [out/bench/run-20260718-144815/summary.md](out/bench/run-20260718-144815/summary.md) | 10 | 1 | 0.15 | 10/10 | 33.410 | 0.299 | 3335.24 | 3344.17 | 3557.55 | 3593.17 | 3602.08 |
| CPython 3.12, GIL | [out/bench/run-20260718-144815/summary.md](out/bench/run-20260718-144815/summary.md) | 10 | 1 | 0.15 | 10/10 | 47.702 | 0.210 | 4769.67 | 4690.94 | 5451.58 | 5505.80 | 5519.36 |
| CPython 3.14 free-threaded/no-GIL | [out/bench/run-20260722-200153/summary.md](out/bench/run-20260722-200153/summary.md) | 10 | 1 | 0.15 | 10/10 | 64.773 | 0.154 | 4731.54 | 4635.14 | 5356.38 | 5499.76 | 5535.60 |

The completed no-GIL mini probe does not materially change the latency story for
this hosted-agent workload: Python stays around the same 4.7s band in both Phase
A and Phase B, while the C# reference remains lower in the same environment.
That is consistent with the benchmark being dominated by hosted-agent/proxy/
network latency and the deliberate opacity delay, not by Python CPU parallelism
where removing the GIL would be expected to help. In that context, seeing
similar or slightly higher per-call latency in the free-threaded run is not
surprising: removing the GIL does not remove the hosted-agent round trip, and
concurrent execution is not a guarantee of lower latency for each request.
