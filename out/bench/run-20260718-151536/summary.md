# Benchmark run 2026-07-18 19:19:14 +02:00

| setting | value |
|---|---|
| max_retries | 5 |
| host | AVAPC-075332338 |
| project | https://ippocfoundryoqxs25zqctwd2.services.ai.azure.com/api/projects/ippoc-proj |
| parallel | 1 |
| powershell | 7.6.3 |
| n | 1000 |
| target_rps | 0.15 |
| warmup | 0 |
| prompt | benchmark ping: what is the capital of France? |

| metric | csharp | python |
|---|---|---|
| n_total | 1000 | 1000 |
| n_success | 999 | 1000 |
| n_failed | 1 | n/a |
| success_rate_pct | 99,9 | 100 |
| wallclock_s | 3377,802 | 4560,496 |
| throughput_rps | 0,296 | 0,219 |
| n_calls_retried | n/a | n/a |
| retries_total | n/a | n/a |
| latency_ms_mean | 3376,79 | 4560,19 |
| latency_ms_stddev | 419,93 | 431,42 |
| latency_ms_min | 2553 | 3834,03 |
| latency_ms_p50 | 3353,36 | 4505,58 |
| latency_ms_p90 | 3653,54 | 4980,04 |
| latency_ms_p95 | 3748,2 | 5214,12 |
| latency_ms_p99 | 4083,78 | 5600,4 |
| latency_ms_max | 11452,36 | 11726,09 |
| response_bytes_mean | 882 | 890 |
| tokens_in_avg | n/a | n/a |
| tokens_out_avg | n/a | n/a |
| tokens_total_sum | n/a | n/a |
| top_errors | 1x http_500 | n/a |

