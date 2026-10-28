#requires -Version 5.1
<#
.SYNOPSIS
End-to-end smoke test of scripts/Invoke-GpuAiCheck.ps1 against a FAKE Ollama server and a FAKE
nvidia-smi. Linux/macOS only (needs python3 and an executable-bit shebang script).

This proves the orchestration, file formats and error handling work. It does NOT prove anything
about real GPUs, real nvidia-smi output on every driver, real Ollama, Windows, or PowerShell 5.1.

.EXAMPLE
pwsh -NoProfile -File tests/e2e/Run-E2E.ps1
#>
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Desktop' -or ($PSVersionTable.ContainsKey('Platform') -and $PSVersionTable.Platform -eq 'Win32NT')) {
    Write-Host 'SKIP: the end-to-end smoke test needs Linux or macOS (python3 + shebang scripts).'
    exit 0
}
if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { Write-Host 'SKIP: python3 not found.'; exit 0 }

$here = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$tool = Join-Path (Join-Path $repoRoot 'scripts') 'Invoke-GpuAiCheck.ps1'
$binDir = Join-Path $here 'bin'
$fakeOllama = Join-Path $here 'fake_ollama.py'
& chmod +x (Join-Path $binDir 'nvidia-smi')

$script:Pass = 0
$script:Fail = 0
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Pass++; Write-Host ("ok   - {0}" -f $Name) }
    catch { $script:Fail++; Write-Host ("FAIL - {0}: {1}" -f $Name, $_.Exception.Message) }
}
function Assert-True {
    param($Condition, [string]$Message = 'assertion failed')
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $msg = $null
    try { & $Body } catch { $msg = $_.Exception.Message }
    if ($null -eq $msg) { throw 'expected an error but none was thrown' }
    if ($msg -notmatch $Pattern) { throw ("error did not match /{0}/: {1}" -f $Pattern, $msg) }
}
function Get-FreePort {
    [int](& python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
}
function Start-FakeOllama {
    param([int]$Port, [string[]]$Extra = @())
    $p = Start-Process -FilePath 'python3' -ArgumentList (@('-u', $fakeOllama, '--port', "$Port") + $Extra) -PassThru `
        -RedirectStandardOutput (Join-Path $tmp "ollama-$Port.out") -RedirectStandardError (Join-Path $tmp "ollama-$Port.err")
    for ($i = 0; $i -lt 50; $i++) {
        try { [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/version" -TimeoutSec 2); return $p } catch { Start-Sleep -Milliseconds 200 }
    }
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw 'fake Ollama did not start'
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('gpu-ai-check-e2e-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$oldPath = $env:PATH
$servers = @()
$env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
$null = $tool

try {
    $portA = Get-FreePort
    $servers += Start-FakeOllama -Port $portA -Extra @('--drift')
    $uriA = "http://127.0.0.1:$portA"
    $dirA = Join-Path $tmp 'run-a'

    Test-Case 'full run with a drifting fake: files, telemetry, flags' {
        & $tool -Model 'fake-model' -DurationMinutes 0.12 -SampleSeconds 1 -OllamaUri $uriA -OutputDir $dirA *> $null
        foreach ($f in @('run-meta.json', 'gpu-log.csv', 'iterations.csv', 'summary.json', 'report.md')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $dirA $f)) "missing $f"
        }
        $s = Get-Content -LiteralPath (Join-Path $dirA 'summary.json') -Raw | ConvertFrom-Json
        Assert-True ($s.Inference.Iterations -ge 6) ("too few iterations: " + $s.Inference.Iterations)
        Assert-True ($s.Inference.Failed -eq 0) 'no iteration should fail'
        Assert-True ($s.Telemetry.SamplesTotal -ge 3) ("too few telemetry samples: " + $s.Telemetry.SamplesTotal)
        Assert-True ($s.Telemetry.SamplesUnderLoad -ge 1) 'expected samples under load'
        Assert-True ($s.Telemetry.VramTotalMiB -eq 12288) 'VRAM total not parsed'
        Assert-True ($s.Meta.config.throttleField -eq 'clocks_throttle_reasons.active') 'throttle field not detected'
        Assert-True ($s.Meta.ollama.gpuOffloadPct -eq 100) 'GPU offload should be 100'
        Assert-True (@($s.Observations | Where-Object { $_ -match 'Generation speed fell' }).Count -eq 1) 'drift should be flagged'
        $r = Get-Content -LiteralPath (Join-Path $dirA 'report.md') -Raw
        Assert-True ($r.Contains('NVIDIA GeForce FAKE 3060')) 'GPU name missing from report'
        Assert-True (-not $r.Contains($tmp)) 'report must not contain local paths'
    }

    Test-Case '-ReportFrom rebuilds the report from an existing directory' {
        Remove-Item -LiteralPath (Join-Path $dirA 'report.md')
        & $tool -ReportFrom $dirA *> $null
        Assert-True (Test-Path -LiteralPath (Join-Path $dirA 'report.md')) 'report.md not rebuilt'
    }

    Test-Case 'non-empty output directory is refused' {
        Assert-Throws { & $tool -Model 'fake-model' -DurationMinutes 0.1 -OllamaUri $uriA -OutputDir $dirA *> $null } 'not empty'
    }

    Test-Case 'a missing model fails at warm-up with a clear message' {
        Assert-Throws { & $tool -Model 'no-such-model' -DurationMinutes 0.1 -OllamaUri $uriA -OutputDir (Join-Path $tmp 'run-x') *> $null } 'Warm-up request failed'
    }

    Test-Case 'a non-loopback Ollama URI is refused by default' {
        Assert-Throws { & $tool -Model 'fake-model' -OllamaUri 'http://example.invalid:11434' -OutputDir (Join-Path $tmp 'run-y') *> $null } 'Refusing non-loopback'
    }

    Test-Case 'an unreachable Ollama gives a clear message' {
        $dead = Get-FreePort
        Assert-Throws { & $tool -Model 'fake-model' -OllamaUri "http://127.0.0.1:$dead" -OutputDir (Join-Path $tmp 'run-z') *> $null } 'Cannot reach Ollama'
    }

    # second server without drift, and a "newer driver" nvidia-smi variant
    $portB = Get-FreePort
    $servers += Start-FakeOllama -Port $portB
    $uriB = "http://127.0.0.1:$portB"
    $dirB = Join-Path $tmp 'run-b'
    $env:FAKE_SMI_NEW_DRIVER = '1'
    Test-Case 'steady fake + newer-driver throttle field: no speed flag, determinism 1' {
        & $tool -Model 'fake-model' -DurationMinutes 0.12 -SampleSeconds 1 -OllamaUri $uriB -OutputDir $dirB *> $null
        $s = Get-Content -LiteralPath (Join-Path $dirB 'summary.json') -Raw | ConvertFrom-Json
        Assert-True ($s.Meta.config.throttleField -eq 'clocks_event_reasons.active') 'newer throttle field not detected'
        Assert-True (@($s.Observations | Where-Object { $_ -match 'Generation speed fell' }).Count -eq 0) 'steady run must not be flagged'
        Assert-True ($s.Determinism.Distinct -eq 1) 'identical fake output should hash identically'
        Assert-True (@($s.Telemetry.ThrottleReasonValues).Count -ge 1) 'throttle values missing'
    }
    Remove-Item Env:\FAKE_SMI_NEW_DRIVER -ErrorAction SilentlyContinue

    # third server whose output varies on every call
    $portC = Get-FreePort
    $servers += Start-FakeOllama -Port $portC -Extra @('--vary')
    $dirC = Join-Path $tmp 'run-c'
    Test-Case 'varying output at temperature 0 is flagged by the determinism check' {
        & $tool -Model 'fake-model' -DurationMinutes 0.1 -SampleSeconds 1 -OllamaUri "http://127.0.0.1:$portC" -OutputDir $dirC *> $null
        $s = Get-Content -LiteralPath (Join-Path $dirC 'summary.json') -Raw | ConvertFrom-Json
        Assert-True ($s.Determinism.Distinct -gt 1) 'expected distinct hashes'
        Assert-True (@($s.Observations | Where-Object { $_ -match 'Outputs differed' }).Count -eq 1) 'determinism flag missing'
    }
}
finally {
    foreach ($p in $servers) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $env:PATH = $oldPath
    Remove-Item Env:\FAKE_SMI_NEW_DRIVER -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
