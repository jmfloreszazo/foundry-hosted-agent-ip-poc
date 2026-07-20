# Benchmark run 2026-07-18 14:45:37 +02:00

| setting | value |
|---|---|
| warmup | 0 |
| target_rps | 0.15 |
| powershell | 7.6.3 |
| project | https://ippocfoundryoqxs25zqctwd2.services.ai.azure.com/api/projects/ippoc-proj |
| prompt | benchmark ping: what is the capital of France? |
| n | 1000 |
| max_retries | 5 |
| host | AVAPC-075332338 |
| parallel | 1 |

| metric | csharp | python |
|---|---|---|
| n_total | 1000 | 1000 |
| n_success | 999 | 999 |
| n_failed | 1 | 1 |
| success_rate_pct | 99,9 | 99,9 |
| wallclock_s | 3552,526 | 4665,497 |
| throughput_rps | 0,281 | 0,214 |
| n_calls_retried | n/a | n/a |
| retries_total | n/a | n/a |
| latency_ms_mean | 3548,64 | 4664,65 |
| latency_ms_stddev | 306,05 | 577,13 |
| latency_ms_min | 3040,44 | 4017,44 |
| latency_ms_p50 | 3511,81 | 4584,77 |
| latency_ms_p90 | 3801,09 | 5062,28 |
| latency_ms_p95 | 3933,12 | 5265,4 |
| latency_ms_p99 | 4263 | 5619,82 |
| latency_ms_max | 10385,49 | 13720,66 |
| response_bytes_mean | 824 | 832 |
| tokens_in_avg | n/a | n/a |
| tokens_out_avg | n/a | n/a |
| tokens_total_sum | n/a | n/a |
| top_errors | 1x http_500 | 1x http_500 |

