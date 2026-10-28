#requires -Version 5.1
<#
.SYNOPSIS
Runs a sustained local-inference load against an NVIDIA GPU through Ollama, logs GPU telemetry
with nvidia-smi, and writes a Markdown + JSON report.

.DESCRIPTION
1. Preflight: nvidia-smi, GPU info, Ollama version, model warm-up, GPU offload check (/api/ps).
2. Starts nvidia-smi logging in the background.
3. Repeats one generation request until -DurationMinutes has elapsed (the iteration in flight
   when the deadline passes is allowed to finish).
4. Writes run-meta.json, gpu-log.csv, iterations.csv, summary.json and report.md to -OutputDir.

Only the local Ollama HTTP API is called. A non-loopback -OllamaUri is refused unless
-AllowRemoteOllama is given. Nothing is downloaded and nothing is sent anywhere else.
The report contains no host name, user name, paths, GPU serial or UUID.

.PARAMETER Model
Model name exactly as shown by "ollama list".

.PARAMETER ReportFrom
Rebuild summary.json and report.md from an existing output directory (for example after Ctrl+C).

.EXAMPLE
.\Invoke-GpuAiCheck.ps1 -Model <name from 'ollama list'> -DurationMinutes 60

.EXAMPLE
.\Invoke-GpuAiCheck.ps1 -ReportFrom .\gpu-ai-check-20261028-100000
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$Model,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0.1, 720)]
    [double]$DurationMinutes = 60,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 60)]
    [int]$SampleSeconds = 5,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0, 63)]
    [int]$GpuIndex = 0,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 32768)]
    [int]$NumPredict = 1024,

    [Parameter(ParameterSetName = 'Run')]
    [int]$Seed = 42,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0, 2)]
    [double]$Temperature = 0,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt = 'Write a long, detailed technical explanation of how TCP congestion control works (slow start, congestion avoidance, fast retransmit, Reno, CUBIC and BBR), with worked numeric examples. Aim for at least 1500 words.',

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(30, 7200)]
    [int]$RequestTimeoutSec = 900,

    [Parameter(ParameterSetName = 'Run')]
    [string]$OllamaUri = 'http://127.0.0.1:11434',

    [Parameter(ParameterSetName = 'Run')]
    [switch]$AllowRemoteOllama,

    [ValidateRange(1, 100)]
    [double]$LoadThresholdPct = 90,

    [double]$TempWarnC = 85,

    [string]$OutputDir,

    [Parameter(Mandatory, ParameterSetName = 'Report')]
    [string]$ReportFrom
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GpuAiCheck.psm1') -Force

function Save-Report {
    param([string]$Dir)
    $summary = New-GpuAiSummary -OutputDir $Dir
    Write-JsonFile -Path (Join-Path $Dir 'summary.json') -Object $summary
    Write-Utf8File -Path (Join-Path $Dir 'report.md') -Content (New-GpuAiReport -Summary $summary)
    return $summary
}

# ------------------------------------------------------------------ report-only mode
if ($PSCmdlet.ParameterSetName -eq 'Report') {
    $dir = Resolve-FullPath $ReportFrom
    $s = Save-Report -Dir $dir
    Write-Host ("Report rebuilt: {0}" -f (Join-Path $dir 'report.md'))
    foreach ($o in @($s.Observations)) { Write-Host ("  - {0}" -f $o) }
    return
}

# ------------------------------------------------------------------ preflight
if (-not $AllowRemoteOllama -and -not (Test-LoopbackUri $OllamaUri)) {
    throw "Refusing non-loopback -OllamaUri '$OllamaUri'. Use -AllowRemoteOllama if you really mean it (GPU telemetry would then describe the wrong machine)."
}
$base = $OllamaUri.TrimEnd('/')

$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) { throw 'nvidia-smi not found on PATH. Install the NVIDIA driver or fix PATH.' }
$smiPath = $smi.Source

$infoRaw = @(& $smiPath "--id=$GpuIndex" '--query-gpu=name,driver_version,memory.total' '--format=csv,noheader,nounits' 2>&1)
if ($LASTEXITCODE -ne 0) { throw ("nvidia-smi could not query GPU index {0}: {1}" -f $GpuIndex, ($infoRaw -join ' ')) }
$parts = @(([string]$infoRaw[0]).Split(',') | ForEach-Object { $_.Trim() })
if ($parts.Count -lt 3) { throw ("Unexpected nvidia-smi output: {0}" -f ($infoRaw -join ' ')) }
$gpuName = ($parts[0..($parts.Count - 3)] -join ',').Trim()
$driverVersion = $parts[$parts.Count - 2]
$memTotal = ConvertTo-NullableDouble $parts[$parts.Count - 1]

# Optional throttle-reason field: its name differs between driver generations, so probe both.
$throttleField = $null
foreach ($cand in @('clocks_throttle_reasons.active', 'clocks_event_reasons.active')) {
    $probe = @(& $smiPath "--id=$GpuIndex" "--query-gpu=$cand" '--format=csv,noheader' 2>&1)
    if ($LASTEXITCODE -eq 0 -and $probe.Count -gt 0 -and ([string]$probe[0]).Trim() -match '^0x[0-9A-Fa-f]+$') {
        $throttleField = $cand
        break
    }
}

try {
    $ver = Invoke-RestMethod -Method Get -Uri ($base + '/api/version') -TimeoutSec 10
    $ollamaVersion = [string]$ver.version
} catch {
    throw ("Cannot reach Ollama at {0}: {1}" -f $base, (Get-ErrorText $_))
}

Write-Host ("GPU: {0} | driver {1} | Ollama {2} | model {3}" -f $gpuName, $driverVersion, $ollamaVersion, $Model)
Write-Host 'Warm-up request (loads the model)...'
try {
    [void](Invoke-OllamaGenerate -BaseUri $base -Model $Model -Prompt 'ping' -NumPredict 8 -Seed $Seed -Temperature $Temperature -TimeoutSec $RequestTimeoutSec)
} catch {
    throw ("Warm-up request failed (is the model name right? see 'ollama list'): {0}" -f (Get-ErrorText $_))
}
$offload = $null
try { $offload = Get-OllamaGpuOffload -BaseUri $base -Model $Model } catch { Write-Warning ("Could not read /api/ps: {0}" -f (Get-ErrorText $_)) }
if ($null -eq $offload) {
    Write-Warning 'Model not listed by /api/ps; GPU offload not confirmed.'
} elseif ($offload -lt 99) {
    Write-Warning ("Only {0}% of the model is on the GPU. This will not be a pure GPU load." -f $offload)
}

# ------------------------------------------------------------------ output + meta
if (-not $OutputDir) { $OutputDir = ('gpu-ai-check-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$out = Resolve-FullPath $OutputDir
if (Test-Path -LiteralPath $out) {
    if (@(Get-ChildItem -LiteralPath $out -Force).Count -gt 0) { throw "Output directory '$out' exists and is not empty." }
} else {
    New-Item -ItemType Directory -Path $out | Out-Null
}
$logPath = Join-Path $out 'gpu-log.csv'
$logErrPath = Join-Path $out 'gpu-log.stderr.txt'
$itPath = Join-Path $out 'iterations.csv'

$promptIsDefault = ($PSBoundParameters.ContainsKey('Prompt') -eq $false)
$meta = [ordered]@{
    toolVersion    = (Get-GpuAiCheckVersion)
    startedUtc     = [datetime]::UtcNow.ToString('o')
    endedUtc       = $null
    elapsedSeconds = $null
    powershell     = $PSVersionTable.PSVersion.ToString()
    os             = [System.Environment]::OSVersion.VersionString
    gpu            = [ordered]@{ index = $GpuIndex; name = $gpuName; driverVersion = $driverVersion; memoryTotalMiB = $memTotal }
    ollama         = [ordered]@{ version = $ollamaVersion; gpuOffloadPct = $offload }
    config         = [ordered]@{
        model           = $Model
        durationMinutes = $DurationMinutes
        sampleSeconds   = $SampleSeconds
        loadThresholdPct = $LoadThresholdPct
        tempWarnC       = $TempWarnC
        numPredict      = $NumPredict
        seed            = $Seed
        temperature     = $Temperature
        promptIsDefault = $promptIsDefault
        promptChars     = $Prompt.Length
        promptSha256    = (Get-Sha256Hex $Prompt)
        throttleField   = $throttleField
    }
}
Write-JsonFile -Path (Join-Path $out 'run-meta.json') -Object $meta

# ------------------------------------------------------------------ logger
$fields = 'timestamp,temperature.gpu,power.draw,clocks.current.graphics,clocks.current.memory,memory.used,memory.total,utilization.gpu'
if ($throttleField) { $fields += ',' + $throttleField }
$logger = Start-Process -FilePath $smiPath `
    -ArgumentList @("--id=$GpuIndex", "--query-gpu=$fields", '--format=csv', '-l', "$SampleSeconds") `
    -RedirectStandardOutput $logPath -RedirectStandardError $logErrPath -NoNewWindow -PassThru
Start-Sleep -Seconds 2
if ($logger.HasExited) {
    $e = ''
    if (Test-Path -LiteralPath $logErrPath) { $e = (Get-Content -LiteralPath $logErrPath -Raw) }
    throw ("nvidia-smi logger exited immediately (exit code {0}). {1}" -f $logger.ExitCode, $e)
}

# ------------------------------------------------------------------ load loop
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$deadline = [datetime]::UtcNow.AddMinutes($DurationMinutes)
$iter = 0
$consecutiveFailures = 0
Write-Host ("Running for {0} min. Ctrl+C aborts; rebuild the report later with -ReportFrom." -f $DurationMinutes)
try {
    while ([datetime]::UtcNow -lt $deadline) {
        $iter++
        $startedUtc = [datetime]::UtcNow.ToString('o')
        $row = [ordered]@{
            iteration         = $iter
            started_utc       = $startedUtc
            eval_count        = ''
            eval_duration_ns  = ''
            tokens_per_second = ''
            prompt_eval_count = ''
            total_duration_ns = ''
            response_sha256   = ''
            response_chars    = ''
            error             = ''
        }
        try {
            $r = Invoke-OllamaGenerate -BaseUri $base -Model $Model -Prompt $Prompt -NumPredict $NumPredict -Seed $Seed -Temperature $Temperature -TimeoutSec $RequestTimeoutSec
            $row.eval_count = $r.EvalCount
            $row.eval_duration_ns = $r.EvalDurationNs
            if ($null -ne $r.TokensPerSecond) { $row.tokens_per_second = ([double]$r.TokensPerSecond).ToString('F2', [System.Globalization.CultureInfo]::InvariantCulture) }
            $row.prompt_eval_count = $r.PromptEvalCount
            $row.total_duration_ns = $r.TotalDurationNs
            $row.response_sha256 = $r.ResponseSha256
            $row.response_chars = $r.ResponseChars
            $consecutiveFailures = 0
            Write-Host ("run {0}: {1} tok/s ({2} tokens)" -f $iter, $row.tokens_per_second, $row.eval_count)
        } catch {
            $row.error = Get-ErrorText $_
            $consecutiveFailures++
            Write-Warning ("run {0} failed: {1}" -f $iter, $row.error)
        }
        [pscustomobject]$row | Export-Csv -LiteralPath $itPath -Append -NoTypeInformation -Encoding UTF8
        if ($consecutiveFailures -ge 3) {
            Write-Warning 'Three consecutive failures; stopping the load loop.'
            break
        }
    }
} finally {
    $sw.Stop()
    if ($logger -and -not $logger.HasExited) { Stop-Process -Id $logger.Id -Force -ErrorAction SilentlyContinue }
    $meta.endedUtc = [datetime]::UtcNow.ToString('o')
    $meta.elapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-JsonFile -Path (Join-Path $out 'run-meta.json') -Object $meta
}

# ------------------------------------------------------------------ report
$summary = Save-Report -Dir $out
Write-Host ''
Write-Host ("Done. Report: {0}" -f (Join-Path $out 'report.md'))
foreach ($o in @($summary.Observations)) { Write-Host ("  - {0}" -f $o) }
if (@($summary.Observations).Count -eq 0) { Write-Host '  No heuristic flags (this is not a health guarantee).' }
