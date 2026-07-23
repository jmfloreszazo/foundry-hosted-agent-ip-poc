<#
.SYNOPSIS
    Benchmark harness for the two Foundry Hosted Agents (C# on .NET 10 vs
    Python on 3.12). Fires N stateless POSTs to /responses against each agent,
    captures per-call metrics (wall latency, status, response size, token
    counters if the wire returns them, error text) and writes both a raw CSV
    per agent and an aggregated summary in Markdown + JSON.

.DESCRIPTION
        - Both agents expose the same OpenAI Responses wire surface. In Phase A,
            they return the same canned response and the benchmark measures hosting
            overhead. In Phase B, they call the same gpt-5-mini deployment and the
            benchmark measures hosting plus model round-trip latency, NOT model
            quality.
        - Uses one cached Azure AD token (resource https://ai.azure.com) and
            refreshes it before expiry. 401/403 responses force one immediate token
            refresh before the call is counted as failed.
    - Sequential by default (clean per-call baseline). Use -Parallel N > 1 to
      measure throughput under concurrency.
    - Warm-up iterations are executed but NOT included in the aggregates so the
      JIT / cold-start of the container does not skew percentiles.

.PARAMETER N
    Measured iterations per agent (default: 100). Set 1000 for the headline run.

.PARAMETER Agent
    Which agent(s) to hit: csharp | python | both (default: both).

.PARAMETER Prompt
    Prompt sent every iteration. Kept short & benign so latency dominates.

.PARAMETER Parallel
    Max concurrent requests. Default 1 (sequential). Values >1 use
    ForEach-Object -Parallel (requires PowerShell 7+).

.PARAMETER Warmup
    Warm-up iterations per agent, discarded from aggregates. Default 3.

.PARAMETER TargetRps
    Client-side rate cap. When > 0 the harness spaces requests so it dispatches
    at most this many per second (global across all -Parallel workers). Use
    this to stay under the Foundry proxy's per-agent rate limit and get a
    clean success curve. Default 0 (no pacing, fires as fast as possible).

.PARAMETER MaxRetries
    Per-call retries on HTTP 429 / 503. The harness honours ``Retry-After``
    when present and falls back to exponential backoff (500ms, 1s, 2s, ...).
    Retries count as ONE logical call in the aggregates; the number of
    physical retries is tracked in a separate ``retries`` column and reported
    in the summary. Default 5.

.PARAMETER RequestTimeoutSec
    Per-request HTTP timeout in seconds. This prevents one stalled hosted-agent
    call from hanging an entire long benchmark run. Default 120.

.PARAMETER ProjectBase
    Base URL of the Foundry project (defaults to the PoC deployment).

.PARAMETER OutDir
    Directory for outputs. Auto-timestamped subfolder is created.

.EXAMPLE
    # Clean 100-call sequential run, paced at 0.3 rps to stay under the limit.
    ./scripts/benchmark.ps1 -N 100 -TargetRps 0.3
.EXAMPLE
    # Headline run: 1000 calls, 4 concurrent workers, 1 rps global cap.
    ./scripts/benchmark.ps1 -N 1000 -Parallel 4 -TargetRps 1
.EXAMPLE
    ./scripts/benchmark.ps1 -N 100 -Agent csharp -Prompt "quick sanity"
#>
[CmdletBinding()]
param(
    [int]$N = 100,
    [ValidateSet('csharp', 'python', 'both')]
    [string]$Agent = 'both',
    [string]$Prompt = "benchmark ping: what is the capital of France?",
    [int]$Parallel = 1,
    [int]$Warmup = 3,
    [double]$TargetRps = 0,
    [int]$MaxRetries = 5,
    [int]$RequestTimeoutSec = 120,
    [string]$ProjectBase = "https://ippocfoundryoqxs25zqctwd2.services.ai.azure.com/api/projects/ippoc-proj",
    [string]$OutDir = "out/bench"
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ Helpers --

$script:AzureTokenValue = $null
$script:AzureTokenExpiresAtUtc = [datetime]::MinValue

function Get-AzureToken {
    param([switch]$ForceRefresh)

    $now = (Get-Date).ToUniversalTime()
    if (-not $ForceRefresh -and $script:AzureTokenValue -and $now -lt $script:AzureTokenExpiresAtUtc.AddMinutes(-5)) {
        return $script:AzureTokenValue
    }

    $json = az account get-access-token --resource https://ai.azure.com --query "{token:accessToken, expiresOn:expiresOn, expiresOnEpoch:expires_on}" -o json 2>$null
    if (-not $json) { throw "Failed to acquire Azure AD token. Run 'az login' first." }

    $parsed = $json | ConvertFrom-Json -ErrorAction Stop
    if (-not $parsed.token) { throw "Failed to acquire Azure AD token. Run 'az login' first." }

    $script:AzureTokenValue = [string]$parsed.token
    if ($parsed.expiresOnEpoch) {
        $script:AzureTokenExpiresAtUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$parsed.expiresOnEpoch).UtcDateTime
    } elseif ($parsed.expiresOn) {
        $script:AzureTokenExpiresAtUtc = ([datetime]::Parse([string]$parsed.expiresOn)).ToUniversalTime()
    } else {
        $script:AzureTokenExpiresAtUtc = $now.AddMinutes(55)
    }

    return $script:AzureTokenValue
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $lo = [int][math]::Floor($rank); $hi = [int][math]::Ceiling($rank)
    if ($lo -eq $hi) { return [double]$sorted[$lo] }
    $w = $rank - $lo
    return [double]($sorted[$lo] * (1 - $w) + $sorted[$hi] * $w)
}

function Get-StdDev {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -lt 2) { return 0.0 }
    $avg = ($Values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $Values) { $sumSq += ($v - $avg) * ($v - $avg) }
    return [math]::Sqrt($sumSq / ($Values.Count - 1))
}

function Invoke-AgentOnce {
    param(
        [string]$Endpoint,
        [string]$Body,
        [int]$MaxRetries = 5,
        [int]$RequestTimeoutSec = 120
    )
    $result = [ordered]@{
        t_utc          = (Get-Date).ToUniversalTime().ToString('o')
        duration_ms    = 0
        status_code    = 0
        success        = $false
        response_bytes = 0
        input_tokens   = $null
        output_tokens  = $null
        total_tokens   = $null
        retries        = 0
        retry_wait_ms  = 0
        error          = ''
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            $token = Get-AzureToken
            # -SkipHttpErrorCheck keeps 4xx/5xx from throwing so we still time them.
            $raw = Invoke-WebRequest -Uri $Endpoint -Method POST -Body $Body `
                -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $token" } `
                -OperationTimeoutSeconds $RequestTimeoutSec `
                -SkipHttpErrorCheck -ErrorAction Stop
            $code = [int]$raw.StatusCode
            $result.status_code = $code
            $result.response_bytes = if ($raw.Content) { [int]$raw.RawContentLength } else { 0 }
            if ($code -ge 200 -and $code -lt 300) {
                $result.success = $true
                try {
                    $parsed = $raw.Content | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed.usage) {
                        $result.input_tokens  = [int]$parsed.usage.input_tokens
                        $result.output_tokens = [int]$parsed.usage.output_tokens
                        $result.total_tokens  = [int]$parsed.usage.total_tokens
                    }
                } catch { $result.error = "parse: $($_.Exception.Message)" }
                break
            }
            elseif (($code -eq 401 -or $code -eq 403) -and $attempt -lt $MaxRetries) {
                [void](Get-AzureToken -ForceRefresh)
                $result.retries += 1
                continue
            }
            elseif (($code -eq 429 -or $code -eq 503) -and $attempt -lt $MaxRetries) {
                # Honour Retry-After (seconds or HTTP-date). Fall back to
                # exponential backoff 2s * 2^attempt (Foundry proxy rate-limit
                # windows are long; 500ms base gives up too fast).
                $wait = 2000 * [math]::Pow(2, $attempt)
                $ra = $null
                try { $ra = $raw.Headers['Retry-After'] } catch {}
                if ($ra) {
                    $raVal = if ($ra -is [array]) { $ra[0] } else { $ra }
                    $parsed = 0
                    if ([int]::TryParse([string]$raVal, [ref]$parsed) -and $parsed -gt 0) {
                        $wait = $parsed * 1000
                    } else {
                        try {
                            $target = [datetime]::Parse([string]$raVal)
                            $delta = ($target.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalMilliseconds
                            if ($delta -gt 0) { $wait = $delta }
                        } catch {}
                    }
                }
                # cap wait to a sane upper bound (60s) so a bad header doesn't hang the run
                if ($wait -gt 60000) { $wait = 60000 }
                $result.retries       += 1
                $result.retry_wait_ms += [int]$wait
                Start-Sleep -Milliseconds ([int]$wait)
                continue
            }
            else {
                $result.error = "http_$code"
                break
            }
        } catch {
            $result.error = $_.Exception.Message -replace "`r?`n", ' '
            break
        }
    }
    $sw.Stop()
    $result.duration_ms = [double]$sw.Elapsed.TotalMilliseconds
    return [pscustomobject]$result
}

function Invoke-Agent {
    param(
        [string]$Name,
        [string]$Endpoint,
        [string]$Body,
        [int]$Count,
        [int]$Warmup,
        [int]$Parallel,
        [double]$TargetRps = 0,
        [int]$MaxRetries = 5,
        [int]$RequestTimeoutSec = 120
    )
    Write-Host "-> $Name : warming up ($Warmup) ..." -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Warmup; $i++) {
        [void](Invoke-AgentOnce -Endpoint $Endpoint -Body $Body -MaxRetries $MaxRetries -RequestTimeoutSec $RequestTimeoutSec)
    }

    $paceMs = if ($TargetRps -gt 0) { [int](1000.0 / $TargetRps) } else { 0 }
    Write-Host "-> $Name : running $Count iterations (parallel=$Parallel, target_rps=$TargetRps, retries<=$MaxRetries) ..." -ForegroundColor Cyan
    $wallSw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($Parallel -le 1) {
        # Sequential + pacing: each call starts no earlier than the previous
        # call's planned slot + $paceMs. Slower actual calls just delay the
        # next slot; faster calls sleep the remainder.
        $rows = @()
        $nextSlot = [System.Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -lt $Count; $i++) {
            $slotStart = [double]($i * $paceMs)
            $waitMs = $slotStart - $nextSlot.Elapsed.TotalMilliseconds
            if ($waitMs -gt 0) { Start-Sleep -Milliseconds ([int]$waitMs) }
            $row = Invoke-AgentOnce -Endpoint $Endpoint -Body $Body -MaxRetries $MaxRetries -RequestTimeoutSec $RequestTimeoutSec
            $rows += $row
            if (($i + 1) -eq 1 -or ($i + 1) % 10 -eq 0 -or ($i + 1) -eq $Count) {
                $state = if ($row.success) { "ok" } elseif ($row.error) { $row.error } else { "failed" }
                Write-Host ("   {0}: {1}/{2} last={3} {4:n0}ms" -f $Name, ($i + 1), $Count, $state, $row.duration_ms) -ForegroundColor DarkGray
            }
        }
    } else {
        # ForEach-Object -Parallel: each runspace re-imports scope, so pass
        # values explicitly and inline the per-call function (which now
        # includes retry-on-429 with Retry-After honouring).
        # Pacing is expressed as a per-request slot the runspace waits for
        # before issuing its call; a shared stopwatch would need a mutex, so
        # instead we compute a fixed slot from the iteration index.
        $rows = 1..$Count | ForEach-Object -Parallel {
            $Endpoint   = $using:Endpoint
            $Body       = $using:Body
            $MaxRetries = $using:MaxRetries
            $RequestTimeoutSec = $using:RequestTimeoutSec
            $paceMs     = $using:paceMs
            $idx        = $_ - 1
            if ($paceMs -gt 0) { Start-Sleep -Milliseconds ([int]($idx * $paceMs / $using:Parallel)) }

            if (-not $script:BenchTokenValue) { $script:BenchTokenValue = $null }
            if (-not $script:BenchTokenExpiresAtUtc) { $script:BenchTokenExpiresAtUtc = [datetime]::MinValue }
            function Get-RunspaceAzureToken {
                param([switch]$ForceRefresh)

                $now = (Get-Date).ToUniversalTime()
                if (-not $ForceRefresh -and $script:BenchTokenValue -and $now -lt $script:BenchTokenExpiresAtUtc.AddMinutes(-5)) {
                    return $script:BenchTokenValue
                }

                $json = az account get-access-token --resource https://ai.azure.com --query "{token:accessToken, expiresOn:expiresOn, expiresOnEpoch:expires_on}" -o json 2>$null
                if (-not $json) { throw "Failed to acquire Azure AD token. Run 'az login' first." }
                $parsed = $json | ConvertFrom-Json -ErrorAction Stop
                if (-not $parsed.token) { throw "Failed to acquire Azure AD token. Run 'az login' first." }

                $script:BenchTokenValue = [string]$parsed.token
                if ($parsed.expiresOnEpoch) {
                    $script:BenchTokenExpiresAtUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$parsed.expiresOnEpoch).UtcDateTime
                } elseif ($parsed.expiresOn) {
                    $script:BenchTokenExpiresAtUtc = ([datetime]::Parse([string]$parsed.expiresOn)).ToUniversalTime()
                } else {
                    $script:BenchTokenExpiresAtUtc = $now.AddMinutes(55)
                }

                return $script:BenchTokenValue
            }

            $row = [ordered]@{
                t_utc = (Get-Date).ToUniversalTime().ToString('o')
                duration_ms = 0; status_code = 0; success = $false
                response_bytes = 0; input_tokens = $null; output_tokens = $null
                total_tokens = $null; retries = 0; retry_wait_ms = 0; error = ''
            }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
                try {
                    $token = Get-RunspaceAzureToken
                    $raw = Invoke-WebRequest -Uri $Endpoint -Method POST -Body $Body `
                        -ContentType 'application/json' `
                        -Headers @{ Authorization = "Bearer $token" } `
                        -OperationTimeoutSeconds $RequestTimeoutSec `
                        -SkipHttpErrorCheck -ErrorAction Stop
                    $code = [int]$raw.StatusCode
                    $row.status_code = $code
                    $row.response_bytes = if ($raw.Content) { [int]$raw.RawContentLength } else { 0 }
                    if ($code -ge 200 -and $code -lt 300) {
                        $row.success = $true
                        try {
                            $parsed = $raw.Content | ConvertFrom-Json -ErrorAction Stop
                            if ($parsed.usage) {
                                $row.input_tokens  = [int]$parsed.usage.input_tokens
                                $row.output_tokens = [int]$parsed.usage.output_tokens
                                $row.total_tokens  = [int]$parsed.usage.total_tokens
                            }
                        } catch {}
                        break
                    }
                    elseif (($code -eq 401 -or $code -eq 403) -and $attempt -lt $MaxRetries) {
                        [void](Get-RunspaceAzureToken -ForceRefresh)
                        $row.retries += 1
                        continue
                    }
                    elseif (($code -eq 429 -or $code -eq 503) -and $attempt -lt $MaxRetries) {
                        $wait = 500 * [math]::Pow(2, $attempt)
                        $ra = $null
                        try { $ra = $raw.Headers['Retry-After'] } catch {}
                        if ($ra) {
                            $raVal = if ($ra -is [array]) { $ra[0] } else { $ra }
                            $p = 0
                            if ([int]::TryParse([string]$raVal, [ref]$p) -and $p -gt 0) { $wait = $p * 1000 }
                        }
                        if ($wait -gt 60000) { $wait = 60000 }
                        $row.retries       += 1
                        $row.retry_wait_ms += [int]$wait
                        Start-Sleep -Milliseconds ([int]$wait)
                        continue
                    }
                    else { $row.error = "http_$code"; break }
                } catch {
                    $row.error = $_.Exception.Message -replace "`r?`n", ' '
                    break
                }
            }
            $sw.Stop()
            $row.duration_ms = [double]$sw.Elapsed.TotalMilliseconds
            [pscustomobject]$row
        } -ThrottleLimit $Parallel
    }
    $wallSw.Stop()
    return @{ Rows = $rows; WallMs = $wallSw.Elapsed.TotalMilliseconds }
}

function Get-Summary {
    param([string]$Name, [object[]]$Rows, [double]$WallMs)
    $success  = @($Rows | Where-Object success)
    $failed   = @($Rows | Where-Object { -not $_.success })
    $lat      = [double[]]($success | ForEach-Object duration_ms)

    $tokensIn  = [double[]]($success | Where-Object input_tokens  -ne $null | ForEach-Object input_tokens)
    $tokensOut = [double[]]($success | Where-Object output_tokens -ne $null | ForEach-Object output_tokens)
    $tokensTot = [double[]]($success | Where-Object total_tokens  -ne $null | ForEach-Object total_tokens)

    $bytes = [double[]]($success | ForEach-Object response_bytes)

    $retryRows = @($Rows | Where-Object { $_.retries -gt 0 })
    $retriesSum = ($Rows | Where-Object { $_.retries } | Measure-Object retries -Sum).Sum
    if (-not $retriesSum) { $retriesSum = 0 }

    [pscustomobject]@{
        agent                = $Name
        n_total              = $Rows.Count
        n_success            = $success.Count
        n_failed             = $failed.Count
        success_rate_pct     = if ($Rows.Count) { [math]::Round(100.0 * $success.Count / $Rows.Count, 3) } else { 0 }
        wallclock_s          = [math]::Round($WallMs / 1000.0, 3)
        throughput_rps       = if ($WallMs -gt 0) { [math]::Round($Rows.Count / ($WallMs / 1000.0), 3) } else { 0 }
        n_calls_retried      = $retryRows.Count
        retries_total        = [int]$retriesSum
        latency_ms_mean      = if ($lat.Count) { [math]::Round(($lat | Measure-Object -Average).Average, 2) } else { $null }
        latency_ms_stddev    = if ($lat.Count) { [math]::Round((Get-StdDev $lat), 2) } else { $null }
        latency_ms_min       = if ($lat.Count) { [math]::Round(($lat | Measure-Object -Minimum).Minimum, 2) } else { $null }
        latency_ms_p50       = if ($lat.Count) { [math]::Round((Get-Percentile $lat 50), 2) } else { $null }
        latency_ms_p90       = if ($lat.Count) { [math]::Round((Get-Percentile $lat 90), 2) } else { $null }
        latency_ms_p95       = if ($lat.Count) { [math]::Round((Get-Percentile $lat 95), 2) } else { $null }
        latency_ms_p99       = if ($lat.Count) { [math]::Round((Get-Percentile $lat 99), 2) } else { $null }
        latency_ms_max       = if ($lat.Count) { [math]::Round(($lat | Measure-Object -Maximum).Maximum, 2) } else { $null }
        response_bytes_mean  = if ($bytes.Count) { [math]::Round(($bytes | Measure-Object -Average).Average, 0) } else { $null }
        tokens_in_avg        = if ($tokensIn.Count)  { [math]::Round(($tokensIn  | Measure-Object -Average).Average, 2) } else { $null }
        tokens_out_avg       = if ($tokensOut.Count) { [math]::Round(($tokensOut | Measure-Object -Average).Average, 2) } else { $null }
        tokens_total_sum     = if ($tokensTot.Count) { [int]  ($tokensTot | Measure-Object -Sum).Sum } else { $null }
        top_errors           = ($failed | Group-Object error | Sort-Object Count -Descending | Select-Object -First 3 |
                                ForEach-Object { "$($_.Count)x $($_.Name)" }) -join ' | '
    }
}

function Write-SummaryMarkdown {
    param([object[]]$Summaries, [hashtable]$Meta, [string]$Path)
    function Format-MarkdownValue {
        param([object]$Value)
        if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) { return 'n/a' }
        if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
            return $Value.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return [string]$Value
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Benchmark run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| setting | value |")
    [void]$sb.AppendLine("|---|---|")
    foreach ($k in $Meta.Keys) { [void]$sb.AppendLine("| $k | $(Format-MarkdownValue $Meta[$k]) |") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("| metric | " + (($Summaries | ForEach-Object agent) -join ' | ') + " |")
    [void]$sb.AppendLine("|" + ("---|" * ($Summaries.Count + 1)))
    $props = @(
        'n_total','n_success','n_failed','success_rate_pct','wallclock_s','throughput_rps',
        'n_calls_retried','retries_total',
        'latency_ms_mean','latency_ms_stddev','latency_ms_min',
        'latency_ms_p50','latency_ms_p90','latency_ms_p95','latency_ms_p99','latency_ms_max',
        'response_bytes_mean','tokens_in_avg','tokens_out_avg','tokens_total_sum','top_errors'
    )
    foreach ($p in $props) {
        $vals = $Summaries | ForEach-Object { Format-MarkdownValue $_.$p }
        [void]$sb.AppendLine("| $p | " + ($vals -join ' | ') + " |")
    }
    Set-Content -Path $Path -Value $sb.ToString() -Encoding utf8
}

# ---------------------------------------------------------------------- Main -

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutDir "run-$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

[void](Get-AzureToken)
$body = @{ input = $Prompt; store = $false; stream = $false } | ConvertTo-Json -Compress

$targets = @()
if ($Agent -in @('csharp', 'both')) {
    $targets += @{ name = 'csharp'; url = "$ProjectBase/agents/ippoc-agentcsharp/endpoint/protocols/openai/responses?api-version=v1" }
}
if ($Agent -in @('python', 'both')) {
    $targets += @{ name = 'python'; url = "$ProjectBase/agents/ippoc-agentpython/endpoint/protocols/openai/responses?api-version=v1" }
}

$summaries = @()
if ($Agent -eq 'both' -and $Parallel -le 1) {
    # Interleaved fair mode: per iteration i, hit BOTH agents back-to-back with
    # the EXACT same body. Same warmup on each. This guarantees both agents
    # observe the same request content and near-identical network/temporal
    # conditions, so the only differences left are the language stack itself.
    Write-Host "-> interleaved mode: N=$N per agent, identical body sent to both" -ForegroundColor Cyan
    foreach ($t in $targets) {
        Write-Host "-> $($t.name) : warming up ($Warmup) ..." -ForegroundColor DarkGray
        for ($i = 0; $i -lt $Warmup; $i++) {
            [void](Invoke-AgentOnce -Endpoint $t.url -Body $body -MaxRetries $MaxRetries)
        }
    }

    $paceMs = if ($TargetRps -gt 0) { [int](1000.0 / $TargetRps) } else { 0 }
    $rowsByTarget = @{}
    foreach ($t in $targets) { $rowsByTarget[$t.name] = @() }
    $wallByTarget = @{}
    foreach ($t in $targets) { $wallByTarget[$t.name] = 0.0 }

    $iterSw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $N; $i++) {
        if ($paceMs -gt 0 -and $i -gt 0) { Start-Sleep -Milliseconds $paceMs }
        foreach ($t in $targets) {
            $callSw = [System.Diagnostics.Stopwatch]::StartNew()
            $row = Invoke-AgentOnce -Endpoint $t.url -Body $body -MaxRetries $MaxRetries
            $callSw.Stop()
            $rowsByTarget[$t.name] += $row
            $wallByTarget[$t.name] += $callSw.Elapsed.TotalMilliseconds
            $sta = if ($row.success) { 'OK ' } else { 'ERR' }
            $extra = if ($row.success) { '' } else { " code=$($row.status_code) err=$($row.error) retries=$($row.retries)" }
            Write-Host ("   [{0,3}/{1}] {2,-6} {3} {4,7:F0} ms{5}" -f ($i+1), $N, $t.name, $sta, $row.duration_ms, $extra) -ForegroundColor DarkGray
        }
    }
    $iterSw.Stop()

    foreach ($t in $targets) {
        $csvPath = Join-Path $runDir "$($t.name).csv"
        $rowsByTarget[$t.name] | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
        $summaries += (Get-Summary -Name $t.name -Rows $rowsByTarget[$t.name] -WallMs $wallByTarget[$t.name])
        Write-Host "   $($t.name): CSV -> $csvPath" -ForegroundColor DarkGray
    }
} else {
    foreach ($t in $targets) {
        $run = Invoke-Agent -Name $t.name -Endpoint $t.url -Body $body `
            -Count $N -Warmup $Warmup -Parallel $Parallel `
            -TargetRps $TargetRps -MaxRetries $MaxRetries
        $csvPath = Join-Path $runDir "$($t.name).csv"
        $run.Rows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
        $summaries += (Get-Summary -Name $t.name -Rows $run.Rows -WallMs $run.WallMs)
        Write-Host "   $($t.name): CSV -> $csvPath" -ForegroundColor DarkGray
    }
}

$meta = [ordered]@{
    n           = $N
    warmup      = $Warmup
    parallel    = $Parallel
    target_rps  = $TargetRps
    max_retries = $MaxRetries
    prompt      = $Prompt
    project     = $ProjectBase
    host        = [System.Environment]::MachineName
    powershell  = $PSVersionTable.PSVersion.ToString()
}

$mdPath   = Join-Path $runDir 'summary.md'
$jsonPath = Join-Path $runDir 'summary.json'
Write-SummaryMarkdown -Summaries $summaries -Meta $meta -Path $mdPath
$summaries | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding utf8

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
Get-Content $mdPath | Write-Host
Write-Host ""
Write-Host "Artifacts in $runDir" -ForegroundColor Green
