#requires -Version 5.1
<#
.SYNOPSIS
Dependency-free unit tests for scripts/GpuAiCheck.psm1 (no Pester needed).
All data is synthetic. These tests cover parsing, statistics, observations and report generation;
they do not touch a GPU, nvidia-smi or Ollama.

.EXAMPLE
pwsh -NoProfile -File tests/Run-Tests.ps1
powershell -NoProfile -File tests\Run-Tests.ps1
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path $repoRoot 'scripts') 'GpuAiCheck.psm1') -Force

$script:Pass = 0
$script:Fail = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host ("ok   - {0}" -f $Name)
    } catch {
        $script:Fail++
        Write-Host ("FAIL - {0}: {1}" -f $Name, $_.Exception.Message)
    }
}
function Assert-True {
    param($Condition, [string]$Message = 'assertion failed')
    if (-not $Condition) { throw $Message }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if ($Actual -ne $Expected) { throw ("expected [{0}] but got [{1}] {2}" -f $Expected, $Actual, $Message) }
}
function Assert-Near {
    param([double]$Actual, [double]$Expected, [double]$Tolerance = 0.01)
    if ([math]::Abs($Actual - $Expected) -gt $Tolerance) { throw ("expected ~{0} but got {1}" -f $Expected, $Actual) }
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gpu-ai-check-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot | Out-Null
$fixture = Join-Path (Join-Path $PSScriptRoot 'fixtures') 'gpu-log-sample.csv'

try {
    # ------------------------------------------------------------ basic helpers
    Test-Case 'Get-Sha256Hex matches the known SHA-256 of "abc"' {
        Assert-Equal (Get-Sha256Hex 'abc') 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
    Test-Case 'Test-LoopbackUri accepts loopback and rejects look-alikes' {
        Assert-True (Test-LoopbackUri 'http://127.0.0.1:11434')
        Assert-True (Test-LoopbackUri 'http://localhost:11434')
        Assert-True (Test-LoopbackUri 'http://[::1]:11434')
        Assert-True (-not (Test-LoopbackUri 'http://example.com:11434'))
        Assert-True (-not (Test-LoopbackUri 'http://localhost.evil.example:11434'))
        Assert-True (-not (Test-LoopbackUri 'http://127.0.0.1@evil.example:11434'))
        Assert-True (-not (Test-LoopbackUri 'http://192.168.1.5:11434'))
        Assert-True (-not (Test-LoopbackUri 'file:///etc/passwd'))
        Assert-True (-not (Test-LoopbackUri 'not a uri'))
    }
    Test-Case 'ConvertTo-NullableDouble handles units, N/A and empty values' {
        Assert-Equal (ConvertTo-NullableDouble '169.95 W') 169.95
        Assert-Equal (ConvertTo-NullableDouble '99 %') 99
        Assert-Equal (ConvertTo-NullableDouble '[N/A]') $null
        Assert-Equal (ConvertTo-NullableDouble '') $null
        Assert-Equal (ConvertTo-NullableDouble 'Not Supported') $null
    }
    Test-Case 'Test-ModelNameMatch treats a missing tag as :latest and ignores case' {
        Assert-True (Test-ModelNameMatch 'My-Model' 'my-model:latest')
        Assert-True (Test-ModelNameMatch 'a:b' 'A:B')
        Assert-True (-not (Test-ModelNameMatch 'a:b' 'a:c'))
    }

    # ------------------------------------------------------------ nvidia-smi CSV parsing
    Test-Case 'ConvertFrom-NvidiaSmiCsv parses the synthetic fixture' {
        $s = @(ConvertFrom-NvidiaSmiCsv -Path $fixture)
        Assert-Equal $s.Count 6
        Assert-Equal $s[1].TempC 60
        Assert-Equal $s[1].PowerW 150
        Assert-Equal $s[1].GraphicsClockMHz 1800
        Assert-Equal $s[1].MemoryUsedMiB 11000
        Assert-Equal $s[1].UtilPct 98
        Assert-Equal $s[1].ThrottleReasons '0x0000000000000004'
        Assert-Equal $s[5].PowerW $null 'N/A power must become $null'
    }
    Test-Case 'Parser matches columns by header name, not position' {
        $p = Join-Path $tmpRoot 'reordered.csv'
        $content = "utilization.gpu [%], timestamp, temperature.gpu`n99 %, 2026/01/01 10:00:00.000, 71`n"
        [System.IO.File]::WriteAllText($p, $content)
        $s = @(ConvertFrom-NvidiaSmiCsv -Path $p)
        Assert-Equal $s.Count 1
        Assert-Equal $s[0].UtilPct 99
        Assert-Equal $s[0].TempC 71
        Assert-Equal $s[0].PowerW $null
    }
    Test-Case 'Parser skips a partial last line and handles a repeated header' {
        $p = Join-Path $tmpRoot 'partial.csv'
        $lines = @(
            'timestamp, temperature.gpu, utilization.gpu [%]',
            '2026/01/01 10:00:00.000, 70, 99 %',
            'timestamp, temperature.gpu, utilization.gpu [%]',
            '2026/01/01 10:00:05.000, 71, 98 %',
            '2026/01/01 10:00:10.000, 72'
        )
        [System.IO.File]::WriteAllText($p, (($lines -join "`n") + "`n"))
        $s = @(ConvertFrom-NvidiaSmiCsv -Path $p)
        Assert-Equal $s.Count 2
    }
    Test-Case 'Parser returns nothing for an empty file and throws for data without header' {
        $e = Join-Path $tmpRoot 'empty.csv'
        [System.IO.File]::WriteAllText($e, '')
        Assert-Equal @(ConvertFrom-NvidiaSmiCsv -Path $e).Count 0
        $n = Join-Path $tmpRoot 'noheader.csv'
        [System.IO.File]::WriteAllText($n, "2026/01/01 10:00:00.000, 70, 99 %`n")
        $threw = $false
        try { [void](ConvertFrom-NvidiaSmiCsv -Path $n) } catch { $threw = $true }
        Assert-True $threw 'expected an error'
    }

    # ------------------------------------------------------------ statistics
    Test-Case 'Get-TelemetrySummary computes stats over samples under load only' {
        $s = @(ConvertFrom-NvidiaSmiCsv -Path $fixture)
        $t = Get-TelemetrySummary -Samples $s -LoadThresholdPct 90
        Assert-Equal $t.SamplesTotal 6
        Assert-Equal $t.SamplesUnderLoad 4
        Assert-Equal $t.TempC.Min 60
        Assert-Equal $t.TempC.Max 76
        Assert-Near $t.TempC.Avg 70.25
        Assert-Equal $t.PowerW.Min 150
        Assert-Equal $t.PowerW.Max 170
        Assert-Near $t.PowerW.Avg 162.67
        Assert-Equal $t.GraphicsClockMHz.Min 1700
        Assert-Equal $t.GraphicsClockMHz.Max 1800
        Assert-Near $t.GraphicsClockMHz.Avg 1742.5
        Assert-Equal $t.VramUsedMaxMiB 11200
        Assert-Equal $t.VramTotalMiB 12288
        $thr = @($t.ThrottleReasonValues)
        Assert-Equal $thr.Count 2
        Assert-Equal $thr[0].Value '0x0000000000000004'
        Assert-Equal $thr[0].Count 3
    }
    Test-Case 'Get-TelemetrySummary with no samples yields zero counts and null stats' {
        $t = Get-TelemetrySummary -Samples @() -LoadThresholdPct 90
        Assert-Equal $t.SamplesTotal 0
        Assert-Equal $t.SamplesUnderLoad 0
        Assert-Equal $t.TempC $null
    }
    Test-Case 'Get-TpsTrend computes first/last third comparison' {
        $v = [double[]](30, 30, 30, 30, 28, 28, 28, 28, 27, 27, 27, 27)
        $t = Get-TpsTrend -Values $v
        Assert-Equal $t.Count 12
        Assert-Equal $t.First 30
        Assert-Equal $t.Last 27
        Assert-Equal $t.Min 27
        Assert-Equal $t.Max 30
        Assert-Near $t.Mean 28.33
        Assert-Equal $t.FirstThirdMean 30
        Assert-Equal $t.LastThirdMean 27
        Assert-Equal $t.ChangePct -10
    }
    Test-Case 'Get-TpsTrend leaves the third-comparison empty below 6 values and handles empty input' {
        $t = Get-TpsTrend -Values ([double[]](30, 29, 28))
        Assert-Equal $t.Count 3
        Assert-Equal $t.ChangePct $null
        Assert-Equal (Get-TpsTrend -Values ([double[]]@())) $null
    }
    Test-Case 'Get-DeterminismSummary counts distinct hashes' {
        $a = 'a' * 64
        $b = 'b' * 64
        $x = Get-DeterminismSummary -Hashes @($a, $a, $a)
        Assert-Equal $x.Compared 3
        Assert-Equal $x.Distinct 1
        $y = Get-DeterminismSummary -Hashes @($a, $b, $a)
        Assert-Equal $y.Distinct 2
        $z = Get-DeterminismSummary -Hashes @()
        Assert-Equal $z.Compared 0
    }

    # ------------------------------------------------------------ observations
    function New-ObsInput {
        param([hashtable]$O)
        $meta = [pscustomobject]@{
            elapsedSeconds = $O.elapsed
            ollama         = [pscustomobject]@{ gpuOffloadPct = $O.offload }
            config         = [pscustomobject]@{ sampleSeconds = 5; tempWarnC = 85 }
        }
        $tel = [pscustomobject]@{
            SamplesTotal = $O.samples; SamplesUnderLoad = $O.underLoad; LoadThresholdPct = 90
            TempC = [pscustomobject]@{ Max = $O.tempMax }
            VramUsedMaxMiB = $O.vramUsed; VramTotalMiB = 12288
        }
        $inf = [pscustomobject]@{
            Iterations = $O.iters; Succeeded = $O.ok; Failed = ($O.iters - $O.ok)
            Tps = [pscustomobject]@{ ChangePct = $O.change }
        }
        $det = [pscustomobject]@{ Tested = $true; Compared = 10; Distinct = $O.distinct }
        return @{ Meta = $meta; Tel = $tel; Inf = $inf; Det = $det }
    }
    Test-Case 'New-GpuAiObservations raises no flags for a clean run' {
        $i = New-ObsInput @{ elapsed = 60; offload = 100; samples = 12; underLoad = 10; tempMax = 76; vramUsed = 11000; iters = 10; ok = 10; change = -1.0; distinct = 1 }
        $o = @(New-GpuAiObservations -Meta $i.Meta -Telemetry $i.Tel -Inference $i.Inf -Determinism $i.Det)
        Assert-Equal $o.Count 0 ($o -join ' | ')
    }
    Test-Case 'New-GpuAiObservations raises every flag for a bad run' {
        $i = New-ObsInput @{ elapsed = 600; offload = 60; samples = 10; underLoad = 0; tempMax = 90; vramUsed = 12000; iters = 10; ok = 8; change = -12.5; distinct = 3 }
        $o = @(New-GpuAiObservations -Meta $i.Meta -Telemetry $i.Tel -Inference $i.Inf -Determinism $i.Det)
        Assert-Equal $o.Count 8 ($o -join ' | ')
    }
    Test-Case 'New-GpuAiObservations flags unconfirmed GPU offload' {
        $i = New-ObsInput @{ elapsed = 60; offload = $null; samples = 12; underLoad = 10; tempMax = 76; vramUsed = 11000; iters = 10; ok = 10; change = -1.0; distinct = 1 }
        $o = @(New-GpuAiObservations -Meta $i.Meta -Telemetry $i.Tel -Inference $i.Inf -Determinism $i.Det)
        Assert-Equal $o.Count 1
        Assert-True ($o[0] -match 'Could not confirm')
    }

    # ------------------------------------------------------------ summary + report from files
    Test-Case 'New-GpuAiSummary and New-GpuAiReport work from an output directory' {
        $dir = Join-Path $tmpRoot 'run'
        New-Item -ItemType Directory -Path $dir | Out-Null
        Copy-Item -LiteralPath $fixture -Destination (Join-Path $dir 'gpu-log.csv')
        $meta = [ordered]@{
            toolVersion = (Get-GpuAiCheckVersion); startedUtc = '2026-01-01T10:00:00.0000000Z'
            endedUtc = '2026-01-01T10:00:30.0000000Z'; elapsedSeconds = 30
            powershell = '7.0.0'; os = 'TestOS 1.0'
            gpu = [ordered]@{ index = 0; name = 'Synthetic GPU 12GB'; driverVersion = '000.00'; memoryTotalMiB = 12288 }
            ollama = [ordered]@{ version = '0.0.0'; gpuOffloadPct = 100 }
            config = [ordered]@{
                model = 'test-model'; durationMinutes = 0.5; sampleSeconds = 5; loadThresholdPct = 90; tempWarnC = 85
                numPredict = 1024; seed = 42; temperature = 0; promptIsDefault = $true; promptChars = 10
                promptSha256 = (Get-Sha256Hex 'x'); throttleField = 'clocks_throttle_reasons.active'
            }
        }
        Write-JsonFile -Path (Join-Path $dir 'run-meta.json') -Object $meta
        $rows = @()
        $tpsVals = @(30, 30, 30, 30, 28, 28, 28, 28, 27, 27, 27, 27)
        for ($n = 0; $n -lt $tpsVals.Count; $n++) {
            $rows += [pscustomobject]@{
                iteration = $n + 1; started_utc = '2026-01-01T10:00:00Z'; eval_count = 100; eval_duration_ns = 1000
                tokens_per_second = $tpsVals[$n].ToString('F2', [cultureinfo]::InvariantCulture)
                prompt_eval_count = 10; total_duration_ns = 2000; response_sha256 = ('a' * 64); response_chars = 50; error = ''
            }
        }
        $rows += [pscustomobject]@{
            iteration = 13; started_utc = '2026-01-01T10:00:29Z'; eval_count = ''; eval_duration_ns = ''
            tokens_per_second = ''; prompt_eval_count = ''; total_duration_ns = ''; response_sha256 = ''; response_chars = ''
            error = 'connection, "closed"'
        }
        $rows | Export-Csv -LiteralPath (Join-Path $dir 'iterations.csv') -NoTypeInformation -Encoding UTF8

        $sum = New-GpuAiSummary -OutputDir $dir
        Assert-Equal $sum.Inference.Iterations 13
        Assert-Equal $sum.Inference.Succeeded 12
        Assert-Equal $sum.Inference.Failed 1
        Assert-Equal $sum.Inference.Tps.ChangePct -10
        Assert-Equal $sum.Determinism.Tested $true
        Assert-Equal $sum.Determinism.Distinct 1
        Assert-Equal @($sum.Observations).Count 2 (@($sum.Observations) -join ' | ')

        $report = New-GpuAiReport -Summary $sum
        foreach ($h in @('# GPU AI check report', '## Run', '## GPU telemetry', '## Inference', '## Determinism check', '## Observations')) {
            Assert-True ($report.Contains($h)) ("report is missing section: " + $h)
        }
        Assert-True ($report.Contains('Synthetic GPU 12GB'))
        Assert-True ($report.Contains('connection, "closed"')) 'error text must appear in the report'
        Assert-True ($report -cnotmatch '\b(PASS|FAIL|PASSED|FAILED)\b') 'the report must not issue a pass/fail verdict'
        Assert-True (-not $report.Contains($tmpRoot)) 'the report must not contain local paths'
    }
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
