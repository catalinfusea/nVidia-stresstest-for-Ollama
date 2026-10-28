#requires -Version 5.1
# GpuAiCheck.psm1 - parsing, statistics and report helpers for gpu-ai-check.
# Kept ASCII-only on purpose so Windows PowerShell 5.1 reads it correctly without a BOM.
Set-StrictMode -Version 2.0

$script:ToolVersion = '0.1.0'
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-GpuAiCheckVersion {
    $script:ToolVersion
}

# ---------------------------------------------------------------- small helpers

function Resolve-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $full = Resolve-FullPath $Path
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    Write-Utf8File -Path $Path -Content (ConvertTo-Json -InputObject $Object -Depth 8)
}

function Format-Num {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value) { return '-' }
    return ([double]$Value).ToString("F$Digits", $script:Inv)
}

function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse([string]$Value, $script:Inv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

function Get-JsonValue {
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-ErrorText {
    param([Parameter(Mandatory)]$ErrorRecord)
    $m = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $m = $ErrorRecord.ErrorDetails.Message
    } else {
        $m = $ErrorRecord.Exception.Message
    }
    $m = ([string]$m -replace '\s+', ' ').Trim()
    if ($m.Length -gt 300) { $m = $m.Substring(0, 300) }
    return $m
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (-join ($bytes | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

function Test-LoopbackUri {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Uri)
    $u = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'http' -and $u.Scheme -ne 'https') { return $false }
    if ($u.Host -ieq 'localhost') { return $true }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($u.Host.Trim('[', ']'), [ref]$ip)) {
        return [System.Net.IPAddress]::IsLoopback($ip)
    }
    return $false
}

function ConvertTo-NullableDouble {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { return $null }
    $t = $Text.Trim()
    if ($t -eq '' -or $t -match 'N/A' -or $t -match 'Not Supported') { return $null }
    $m = [regex]::Match($t, '^-?\d+(\.\d+)?')
    if (-not $m.Success) { return $null }
    return [double]::Parse($m.Value, $script:Inv)
}

# ---------------------------------------------------------------- nvidia-smi log

function ConvertFrom-NvidiaSmiCsv {
    <#
    .SYNOPSIS
    Parses a CSV produced by `nvidia-smi --query-gpu=... --format=csv -l N`.
    Columns are matched by header name, so column order and unit suffixes ("[W]", "[MHz]")
    do not matter. Values with units ("169.9 W") and "[N/A]" are handled.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = Resolve-FullPath $Path
    $lines = @(Get-Content -LiteralPath $full -Encoding UTF8 | Where-Object { $_ -and $_.Trim() -ne '' })
    $samples = New-Object System.Collections.Generic.List[object]
    if ($lines.Count -eq 0) { return @() }

    $map = $null
    foreach ($line in $lines) {
        $f = @($line.Split(',') | ForEach-Object { $_.Trim() })
        $isHeader = @($f | Where-Object { $_ -match '^(timestamp|temperature\.gpu|power\.draw|clocks[._]|memory\.|utilization\.)' }).Count -gt 0
        if ($isHeader) {
            $map = @{}
            for ($i = 0; $i -lt $f.Count; $i++) {
                $name = ($f[$i].ToLowerInvariant() -replace '\s*\[.*\]\s*$', '').Trim()
                $map[$name] = $i
            }
            continue
        }
        if ($null -eq $map) { throw "No header line ('timestamp, ...') found before data in $Path" }
        if ($f.Count -lt $map.Count) { continue }   # partial last line (logger was killed mid-write)

        $get = {
            param($key)
            if ($map.ContainsKey($key)) { return $f[$map[$key]] }
            return $null
        }
        $thr = & $get 'clocks_throttle_reasons.active'
        if ($null -eq $thr) { $thr = & $get 'clocks_event_reasons.active' }
        if ($thr -and $thr -notmatch '^0x[0-9A-Fa-f]+$') { $thr = $null }

        $samples.Add([pscustomobject]@{
            Timestamp        = & $get 'timestamp'
            TempC            = ConvertTo-NullableDouble (& $get 'temperature.gpu')
            PowerW           = ConvertTo-NullableDouble (& $get 'power.draw')
            GraphicsClockMHz = ConvertTo-NullableDouble (& $get 'clocks.current.graphics')
            MemoryClockMHz   = ConvertTo-NullableDouble (& $get 'clocks.current.memory')
            MemoryUsedMiB    = ConvertTo-NullableDouble (& $get 'memory.used')
            MemoryTotalMiB   = ConvertTo-NullableDouble (& $get 'memory.total')
            UtilPct          = ConvertTo-NullableDouble (& $get 'utilization.gpu')
            ThrottleReasons  = $thr
        })
    }
    return $samples.ToArray()
}

# ---------------------------------------------------------------- statistics

function Get-NumericStat {
    param([AllowEmptyCollection()][double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $m = $Values | Measure-Object -Minimum -Maximum -Average
    [pscustomobject]@{
        Count = $Values.Count
        Min   = $m.Minimum
        Avg   = [math]::Round($m.Average, 2)
        Max   = $m.Maximum
    }
}

function Get-PropValues {
    param([object[]]$Items, [Parameter(Mandatory)][string]$Prop)
    $out = New-Object System.Collections.Generic.List[double]
    foreach ($i in @($Items)) {
        $v = $i.$Prop
        if ($null -ne $v) { $out.Add([double]$v) }
    }
    return , $out.ToArray()
}

function Get-TelemetrySummary {
    [CmdletBinding()]
    param(
        [object[]]$Samples,
        [double]$LoadThresholdPct = 90
    )
    $all = @($Samples)
    $load = @($all | Where-Object { $null -ne $_.UtilPct -and $_.UtilPct -ge $LoadThresholdPct })

    $thr = @($load | Where-Object { $_.ThrottleReasons } |
        Group-Object -Property ThrottleReasons |
        Sort-Object -Property Count -Descending |
        ForEach-Object { [pscustomobject]@{ Value = $_.Name; Count = $_.Count } })

    $vramMax = $null
    $vramTotal = $null
    $usedVals = Get-PropValues -Items $all -Prop 'MemoryUsedMiB'
    if ($usedVals.Count -gt 0) { $vramMax = ($usedVals | Measure-Object -Maximum).Maximum }
    $totVals = Get-PropValues -Items $all -Prop 'MemoryTotalMiB'
    if ($totVals.Count -gt 0) { $vramTotal = $totVals[0] }

    [pscustomobject]@{
        SamplesTotal         = $all.Count
        SamplesUnderLoad     = $load.Count
        LoadThresholdPct     = $LoadThresholdPct
        TempC                = Get-NumericStat -Values (Get-PropValues -Items $load -Prop 'TempC')
        PowerW               = Get-NumericStat -Values (Get-PropValues -Items $load -Prop 'PowerW')
        GraphicsClockMHz     = Get-NumericStat -Values (Get-PropValues -Items $load -Prop 'GraphicsClockMHz')
        MemoryClockMHz       = Get-NumericStat -Values (Get-PropValues -Items $load -Prop 'MemoryClockMHz')
        VramUsedMaxMiB       = $vramMax
        VramTotalMiB         = $vramTotal
        ThrottleReasonValues = $thr
    }
}

function Get-TpsTrend {
    <#
    .SYNOPSIS
    Summarises tokens/second over successive iterations. The first-third vs last-third
    comparison needs at least 6 values.
    #>
    param([AllowEmptyCollection()][double[]]$Values)
    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $n = $Values.Count
    $stat = Get-NumericStat -Values $Values
    $firstThird = $null
    $lastThird = $null
    $change = $null
    if ($n -ge 6) {
        $k = [int][math]::Floor($n / 3)
        $firstThird = [math]::Round((($Values[0..($k - 1)] | Measure-Object -Average).Average), 2)
        $lastThird = [math]::Round((($Values[($n - $k)..($n - 1)] | Measure-Object -Average).Average), 2)
        if ($firstThird -gt 0) { $change = [math]::Round((($lastThird - $firstThird) / $firstThird) * 100, 1) }
    }
    [pscustomobject]@{
        Count          = $n
        First          = $Values[0]
        Last           = $Values[$n - 1]
        Min            = $stat.Min
        Max            = $stat.Max
        Mean           = $stat.Avg
        FirstThirdMean = $firstThird
        LastThirdMean  = $lastThird
        ChangePct      = $change
    }
}

function Get-DeterminismSummary {
    param([AllowEmptyCollection()][string[]]$Hashes)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $n = 0
    foreach ($h in @($Hashes)) {
        if ($h) { $n++; [void]$set.Add($h) }
    }
    [pscustomobject]@{ Compared = $n; Distinct = $set.Count }
}

# ---------------------------------------------------------------- Ollama HTTP API

function Test-ModelNameMatch {
    param([string]$Wanted, [string]$Candidate)
    if (-not $Wanted -or -not $Candidate) { return $false }
    $a = $Wanted.ToLowerInvariant()
    $b = $Candidate.ToLowerInvariant()
    if (-not $a.Contains(':')) { $a = $a + ':latest' }
    if (-not $b.Contains(':')) { $b = $b + ':latest' }
    return ($a -eq $b)
}

function Invoke-OllamaGenerate {
    <#
    .SYNOPSIS
    One non-streaming /api/generate call. Duration fields are nanoseconds in the API.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [int]$NumPredict = 1024,
        [int]$Seed = 42,
        [double]$Temperature = 0,
        [string]$KeepAlive = '10m',
        [int]$TimeoutSec = 900
    )
    $body = @{
        model      = $Model
        prompt     = $Prompt
        stream     = $false
        keep_alive = $KeepAlive
        options    = @{ seed = $Seed; temperature = $Temperature; num_predict = $NumPredict }
    }
    $json = ConvertTo-Json -InputObject $body -Depth 5 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $uri = $BaseUri.TrimEnd('/') + '/api/generate'
    $r = Invoke-RestMethod -Method Post -Uri $uri -Body $bytes -ContentType 'application/json; charset=utf-8' -TimeoutSec $TimeoutSec

    $text = [string](Get-JsonValue $r 'response')
    $evalCount = Get-JsonValue $r 'eval_count'
    $evalNs = Get-JsonValue $r 'eval_duration'
    $tps = $null
    if ($null -ne $evalCount -and $null -ne $evalNs -and [double]$evalNs -gt 0) {
        $tps = [double]$evalCount / [double]$evalNs * 1e9
    }
    [pscustomobject]@{
        EvalCount       = $evalCount
        EvalDurationNs  = $evalNs
        TokensPerSecond = $tps
        PromptEvalCount = Get-JsonValue $r 'prompt_eval_count'
        TotalDurationNs = Get-JsonValue $r 'total_duration'
        ResponseSha256  = Get-Sha256Hex $text
        ResponseChars   = $text.Length
    }
}

function Get-OllamaGpuOffload {
    <#
    .SYNOPSIS
    Percentage of the loaded model reported in VRAM by /api/ps (size_vram / size), or $null
    when the model is not listed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$Model
    )
    $r = Invoke-RestMethod -Method Get -Uri ($BaseUri.TrimEnd('/') + '/api/ps') -TimeoutSec 10
    foreach ($m in @(Get-JsonValue $r 'models')) {
        $n1 = [string](Get-JsonValue $m 'name')
        $n2 = [string](Get-JsonValue $m 'model')
        if ((Test-ModelNameMatch $Model $n1) -or (Test-ModelNameMatch $Model $n2)) {
            $size = [double](Get-JsonValue $m 'size')
            $vram = [double](Get-JsonValue $m 'size_vram')
            if ($size -gt 0) { return [math]::Round($vram / $size * 100, 1) }
        }
    }
    return $null
}

# ---------------------------------------------------------------- summary + report

function New-GpuAiObservations {
    <#
    .SYNOPSIS
    Heuristic flags. They are prompts to look closer, not a verdict; thresholds are arbitrary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Meta,
        [Parameter(Mandatory)]$Telemetry,
        [Parameter(Mandatory)]$Inference,
        [Parameter(Mandatory)]$Determinism
    )
    $obs = New-Object System.Collections.Generic.List[string]

    $off = $Meta.ollama.gpuOffloadPct
    if ($null -eq $off) {
        $obs.Add('Could not confirm via Ollama /api/ps that the model was fully on the GPU. Check "ollama ps" yourself; a CPU/GPU split makes this a partial CPU test.')
    } elseif ([double]$off -lt 99) {
        $obs.Add(("Ollama reported the model only {0}% on GPU; the rest ran on CPU, so this was not a pure GPU load." -f (Format-Num $off 1)))
    }

    if ($Telemetry.SamplesUnderLoad -eq 0) {
        $obs.Add(("No telemetry samples at or above {0}% GPU utilization. The workload may be too light, the log may be empty, or -GpuIndex may not match the GPU Ollama used." -f (Format-Num $Telemetry.LoadThresholdPct 0)))
    }

    $elapsed = $Meta.elapsedSeconds
    $interval = [double]$Meta.config.sampleSeconds
    if ($null -ne $elapsed -and $interval -gt 0) {
        $expected = [double]$elapsed / $interval
        if ($Telemetry.SamplesTotal -lt (0.8 * $expected)) {
            $obs.Add(("Fewer telemetry samples than expected ({0} logged, about {1} expected). The logger may have stopped early." -f $Telemetry.SamplesTotal, (Format-Num $expected 0)))
        }
    }

    if ($Inference.Succeeded -eq 0) {
        $obs.Add('No inference iteration succeeded.')
    }
    if ($Inference.Failed -gt 0) {
        $obs.Add(("{0} of {1} inference iterations failed (see iterations.csv, column error)." -f $Inference.Failed, $Inference.Iterations))
    }

    $tps = $Inference.Tps
    if ($null -ne $tps -and $null -ne $tps.ChangePct -and [double]$tps.ChangePct -lt -5) {
        $obs.Add(("Generation speed fell {0}% from the first third to the last third of the run. Compare with clock, power and temperature over time. The 5% threshold is arbitrary; run-to-run variation also exists." -f (Format-Num ([math]::Abs([double]$tps.ChangePct)) 1)))
    }

    $warnC = [double]$Meta.config.tempWarnC
    if ($null -ne $Telemetry.TempC -and [double]$Telemetry.TempC.Max -ge $warnC) {
        $obs.Add(("Maximum GPU temperature under load was {0} C (flag threshold {1} C, configurable). Compare with the documented limit for your exact GPU." -f (Format-Num $Telemetry.TempC.Max 0), (Format-Num $warnC 0)))
    }

    if ($null -ne $Telemetry.VramUsedMaxMiB -and $null -ne $Telemetry.VramTotalMiB -and [double]$Telemetry.VramTotalMiB -gt 0) {
        $ratio = [double]$Telemetry.VramUsedMaxMiB / [double]$Telemetry.VramTotalMiB
        if ($ratio -ge 0.95) {
            $obs.Add(("VRAM was nearly full ({0} of {1} MiB). A larger context or a second app on the GPU may push the model partly to CPU or fail to load." -f (Format-Num $Telemetry.VramUsedMaxMiB 0), (Format-Num $Telemetry.VramTotalMiB 0)))
        }
    }

    if ($Determinism.Tested -and $Determinism.Compared -ge 2 -and $Determinism.Distinct -gt 1) {
        $obs.Add(("Outputs differed between iterations ({0} distinct of {1}) despite temperature 0 and a fixed seed. This alone is not conclusive (bit-exact determinism is not guaranteed on GPUs); repeat the run and compare." -f $Determinism.Distinct, $Determinism.Compared))
    }

    return $obs.ToArray()
}

function New-GpuAiSummary {
    <#
    .SYNOPSIS
    Builds the summary object from run-meta.json, gpu-log.csv and iterations.csv in OutputDir.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OutputDir)

    $dir = Resolve-FullPath $OutputDir
    $metaPath = Join-Path $dir 'run-meta.json'
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "run-meta.json not found in $dir" }
    $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $samples = @()
    $logPath = Join-Path $dir 'gpu-log.csv'
    if (Test-Path -LiteralPath $logPath) { $samples = @(ConvertFrom-NvidiaSmiCsv -Path $logPath) }
    $tel = Get-TelemetrySummary -Samples $samples -LoadThresholdPct ([double]$meta.config.loadThresholdPct)

    $rows = @()
    $itPath = Join-Path $dir 'iterations.csv'
    if (Test-Path -LiteralPath $itPath) { $rows = @(Import-Csv -LiteralPath $itPath -Encoding UTF8) }

    $tpsList = New-Object System.Collections.Generic.List[double]
    $hashes = New-Object System.Collections.Generic.List[string]
    $failedRows = New-Object System.Collections.Generic.List[object]
    $tokens = 0.0
    foreach ($r in $rows) {
        if ([string]$r.error) {
            $failedRows.Add([pscustomobject]@{ Iteration = [int]$r.iteration; Message = [string]$r.error })
            continue
        }
        $t = ConvertTo-NullableDouble ([string]$r.tokens_per_second)
        if ($null -ne $t) { $tpsList.Add($t) }
        $c = ConvertTo-NullableDouble ([string]$r.eval_count)
        if ($null -ne $c) { $tokens += $c }
        if ([string]$r.response_sha256) { $hashes.Add([string]$r.response_sha256) }
    }
    $inference = [pscustomobject]@{
        Iterations      = $rows.Count
        Succeeded       = $rows.Count - $failedRows.Count
        Failed          = $failedRows.Count
        FailedSample    = @($failedRows | Select-Object -First 5)
        EvalTokensTotal = $tokens
        Tps             = Get-TpsTrend -Values $tpsList.ToArray()
    }

    $tested = ([double]$meta.config.temperature -eq 0)
    $det = Get-DeterminismSummary -Hashes $hashes.ToArray()
    $determinism = [pscustomobject]@{ Tested = $tested; Compared = $det.Compared; Distinct = $det.Distinct }

    $observations = @(New-GpuAiObservations -Meta $meta -Telemetry $tel -Inference $inference -Determinism $determinism)

    [pscustomobject]@{
        ToolVersion  = $script:ToolVersion
        Meta         = $meta
        Telemetry    = $tel
        Inference    = $inference
        Determinism  = $determinism
        Observations = $observations
    }
}

function New-GpuAiReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Summary)

    $m = $Summary.Meta
    $tel = $Summary.Telemetry
    $inf = $Summary.Inference
    $sb = New-Object System.Text.StringBuilder
    $ln = { param($t) [void]$sb.AppendLine([string]$t) }

    $started = ConvertTo-UtcDate $m.startedUtc
    $startedText = '-'
    if ($null -ne $started) { $startedText = $started.ToString('yyyy-MM-dd HH:mm:ss', $script:Inv) + ' UTC' }
    $elapsedText = '-'
    if ($null -ne $m.elapsedSeconds) { $elapsedText = (Format-Num ([double]$m.elapsedSeconds / 60) 1) + ' min' }
    $offText = 'not confirmed'
    if ($null -ne $m.ollama.gpuOffloadPct) { $offText = (Format-Num $m.ollama.gpuOffloadPct 1) + '%' }

    & $ln '# GPU AI check report'
    & $ln ''
    & $ln ("Generated by gpu-ai-check v{0}. This report lists measurements and heuristic flags. It is not a pass/fail verdict; see docs/limitations.md." -f $Summary.ToolVersion)
    & $ln ''
    & $ln '## Run'
    & $ln ''
    & $ln '| Field | Value |'
    & $ln '|---|---|'
    & $ln ("| Started | {0} |" -f $startedText)
    & $ln ("| Elapsed | {0} |" -f $elapsedText)
    & $ln ("| GPU | {0} (nvidia-smi index {1}) |" -f $m.gpu.name, $m.gpu.index)
    & $ln ("| Driver | {0} |" -f $m.gpu.driverVersion)
    & $ln ("| VRAM total | {0} MiB |" -f (Format-Num $m.gpu.memoryTotalMiB 0))
    & $ln ("| OS | {0} |" -f $m.os)
    & $ln ("| PowerShell | {0} |" -f $m.powershell)
    & $ln ("| Ollama version | {0} |" -f $m.ollama.version)
    & $ln ("| Model | {0} |" -f $m.config.model)
    & $ln ("| Model on GPU (Ollama /api/ps) | {0} |" -f $offText)
    & $ln ''
    & $ln '## Configuration'
    & $ln ''
    & $ln '| Setting | Value |'
    & $ln '|---|---|'
    & $ln ("| Requested duration | {0} min |" -f (Format-Num $m.config.durationMinutes 1))
    & $ln ("| Telemetry interval | {0} s |" -f $m.config.sampleSeconds)
    & $ln ("| Load threshold | GPU utilization >= {0}% |" -f (Format-Num $m.config.loadThresholdPct 0))
    & $ln ("| num_predict | {0} |" -f $m.config.numPredict)
    & $ln ("| seed / temperature | {0} / {1} |" -f $m.config.seed, (Format-Num $m.config.temperature 2))
    $promptKind = 'custom'
    if ($m.config.promptIsDefault) { $promptKind = 'default' }
    & $ln ("| Prompt | {0}, {1} chars, SHA-256 {2} |" -f $promptKind, $m.config.promptChars, $m.config.promptSha256)
    & $ln ''
    & $ln ("## GPU telemetry (samples with utilization >= {0}%)" -f (Format-Num $tel.LoadThresholdPct 0))
    & $ln ''
    & $ln ("Samples: {0} total, {1} under load." -f $tel.SamplesTotal, $tel.SamplesUnderLoad)
    & $ln ''
    & $ln '| Metric | Min | Avg | Max |'
    & $ln '|---|---|---|---|'
    $rowsDef = @(
        @('Temperature (C)', $tel.TempC, 1),
        @('Power draw (W)', $tel.PowerW, 1),
        @('Graphics clock (MHz)', $tel.GraphicsClockMHz, 0),
        @('Memory clock (MHz)', $tel.MemoryClockMHz, 0)
    )
    foreach ($d in $rowsDef) {
        $s = $d[1]
        if ($null -eq $s) {
            & $ln ("| {0} | - | - | - |" -f $d[0])
        } else {
            & $ln ("| {0} | {1} | {2} | {3} |" -f $d[0], (Format-Num $s.Min $d[2]), (Format-Num $s.Avg $d[2]), (Format-Num $s.Max $d[2]))
        }
    }
    & $ln ''
    & $ln ("VRAM used (max over the whole log): {0} MiB of {1} MiB." -f (Format-Num $tel.VramUsedMaxMiB 0), (Format-Num $tel.VramTotalMiB 0))
    & $ln ''
    $thr = @($tel.ThrottleReasonValues)
    if ($thr.Count -eq 0) {
        & $ln 'Throttle-reason bitmask: not available (no matching nvidia-smi field on this driver, or no samples under load).'
    } else {
        & $ln 'Throttle-reason bitmask under load (raw values, not decoded here; decode with the nvidia-smi documentation or "nvidia-smi -q -d PERFORMANCE"):'
        & $ln ''
        & $ln '| Value | Samples |'
        & $ln '|---|---|'
        foreach ($t in $thr) { & $ln ("| {0} | {1} |" -f $t.Value, $t.Count) }
    }
    & $ln ''
    & $ln '## Inference'
    & $ln ''
    & $ln '| Field | Value |'
    & $ln '|---|---|'
    & $ln ("| Iterations (ok / failed) | {0} / {1} |" -f $inf.Succeeded, $inf.Failed)
    & $ln ("| Tokens generated | {0} |" -f (Format-Num $inf.EvalTokensTotal 0))
    $tps = $inf.Tps
    if ($null -eq $tps) {
        & $ln '| Tokens/s | no successful iterations |'
    } else {
        & $ln ("| Tokens/s first / last | {0} / {1} |" -f (Format-Num $tps.First 2), (Format-Num $tps.Last 2))
        & $ln ("| Tokens/s min / mean / max | {0} / {1} / {2} |" -f (Format-Num $tps.Min 2), (Format-Num $tps.Mean 2), (Format-Num $tps.Max 2))
        if ($null -eq $tps.ChangePct) {
            & $ln '| First third vs last third | needs at least 6 successful iterations |'
        } else {
            & $ln ("| Mean first third / last third | {0} / {1} ({2}%) |" -f (Format-Num $tps.FirstThirdMean 2), (Format-Num $tps.LastThirdMean 2), (Format-Num $tps.ChangePct 1))
        }
    }
    & $ln ''
    $failed = @($inf.FailedSample)
    if ($failed.Count -gt 0) {
        & $ln 'First failed iterations:'
        & $ln ''
        foreach ($f in $failed) { & $ln ("- run {0}: {1}" -f $f.Iteration, $f.Message) }
        & $ln ''
    }
    & $ln '## Determinism check'
    & $ln ''
    if (-not $Summary.Determinism.Tested) {
        & $ln 'Not applicable: temperature was not 0.'
    } else {
        & $ln ("{0} distinct output hash(es) across {1} successful iterations (temperature 0, fixed seed). Identical outputs are a weak consistency signal, not proof of healthy hardware." -f $Summary.Determinism.Distinct, $Summary.Determinism.Compared)
    }
    & $ln ''
    & $ln '## Observations (heuristic, not a verdict)'
    & $ln ''
    $obs = @($Summary.Observations)
    if ($obs.Count -eq 0) {
        & $ln 'No heuristic flags were raised. That does not prove the card is healthy: this tool does not test VRAM integrity or long-term reliability.'
    } else {
        foreach ($o in $obs) { & $ln ("- {0}" -f $o) }
    }
    & $ln ''
    return $sb.ToString()
}

Export-ModuleMember -Function @(
    'Get-GpuAiCheckVersion',
    'Resolve-FullPath',
    'Write-Utf8File',
    'Write-JsonFile',
    'ConvertTo-NullableDouble',
    'ConvertFrom-NvidiaSmiCsv',
    'Get-NumericStat',
    'Get-TelemetrySummary',
    'Get-TpsTrend',
    'Get-DeterminismSummary',
    'Get-Sha256Hex',
    'Get-ErrorText',
    'Test-LoopbackUri',
    'Test-ModelNameMatch',
    'Invoke-OllamaGenerate',
    'Get-OllamaGpuOffload',
    'New-GpuAiObservations',
    'New-GpuAiSummary',
    'New-GpuAiReport'
)
