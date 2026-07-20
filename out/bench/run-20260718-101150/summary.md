# Benchmark run 2026-07-18 10:36:49 +02:00

| setting | value |
|---|---|
| powershell | 7.6.3 |
| n | 100 |
| target_rps | 0.15 |
| max_retries | 5 |
| project | https://ippocfoundryoqxs25zqctwd2.services.ai.azure.com/api/projects/ippoc-proj |
| host | AVAPC-075332338 |
| prompt | benchmark ping: what is the capital of France? |
| parallel | 1 |
| warmup | 0 |

| metric | csharp | python |
|---|---|---|
| n_total | 100 | 100 |
| n_success | 99 | 99 |
| n_failed | 1 | 1 |
| success_rate_pct | 99 | 99 |
| wallclock_s | 364,836 | 467,137 |
| throughput_rps | 0,274 | 0,214 |
| n_calls_retried | n/a | n/a |
| retries_total | n/a | n/a |
| latency_ms_mean | 3628,23 | 4666,31 |
| latency_ms_stddev | 711,84 | 371,63 |
| latency_ms_min | 3116,29 | 4136,06 |
| latency_ms_p50 | 3538,72 | 4597,36 |
| latency_ms_p90 | 3867,74 | 4942,49 |
| latency_ms_p95 | 3994,89 | 5366,6 |
| latency_ms_p99 | 4435,46 | 5748,28 |
| latency_ms_max | 10304,46 | 6854,01 |
| response_bytes_mean | 824 | 831 |
| tokens_in_avg | n/a | n/a |
| tokens_out_avg | n/a | n/a |
| tokens_total_sum | n/a | n/a |
| top_errors | 1x http_500 | 1x http_500 |

