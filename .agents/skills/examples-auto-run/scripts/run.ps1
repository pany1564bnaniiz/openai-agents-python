# Examples Auto-Run Skill - PowerShell Script
# Automatically discovers and runs Python examples, capturing output and errors

param(
    [string]$ExamplesDir = "examples",
    [string]$OutputDir = ".agents/skills/examples-auto-run/output",
    [int]$TimeoutSeconds = 30,
    [switch]$FailFast,
    [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Track results
$Results = @{
    Passed  = @()
    Failed  = @()
    Skipped = @()
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "Cyan" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-PythonAvailable {
    try {
        $null = python --version 2>&1
        return $true
    } catch {
        return $false
    }
}

function Get-ExampleFiles {
    param([string]$Directory)
    if (-not (Test-Path $Directory)) {
        Write-Log "Examples directory '$Directory' not found." "WARN"
        return @()
    }
    return Get-ChildItem -Path $Directory -Filter "*.py" -Recurse |
        Where-Object { $_.Name -notlike "_*" } |
        Sort-Object FullName
}

function Invoke-Example {
    param(
        [System.IO.FileInfo]$File,
        [int]$Timeout
    )

    $relativePath = $File.FullName.Replace((Get-Location).Path + "\", "")
    Write-Log "Running: $relativePath"

    # Check for skip marker in file
    $content = Get-Content $File.FullName -Raw
    if ($content -match "# skip-auto-run") {
        Write-Log "Skipping '$relativePath' (skip-auto-run marker found)" "WARN"
        return @{ Status = "skipped"; File = $relativePath; Reason = "skip-auto-run marker" }
    }

    $startTime = Get-Date
    try {
        $proc = Start-Process -FilePath python `
            -ArgumentList $File.FullName `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput "$OutputDir\stdout_temp.txt" `
            -RedirectStandardError "$OutputDir\stderr_temp.txt"

        $exited = $proc.WaitForExit($Timeout * 1000)
        $elapsed = ((Get-Date) - $startTime).TotalSeconds

        if (-not $exited) {
            $proc.Kill()
            Write-Log "TIMEOUT after ${Timeout}s: $relativePath" "ERROR"
            return @{ Status = "failed"; File = $relativePath; Reason = "timeout after ${Timeout}s"; Duration = $elapsed }
        }

        $stdout = if (Test-Path "$OutputDir\stdout_temp.txt") { Get-Content "$OutputDir\stdout_temp.txt" -Raw } else { "" }
        $stderr = if (Test-Path "$OutputDir\stderr_temp.txt") { Get-Content "$OutputDir\stderr_temp.txt" -Raw } else { "" }

        if ($proc.ExitCode -eq 0) {
            Write-Log "PASSED ($([math]::Round($elapsed, 2))s): $relativePath" "SUCCESS"
            return @{ Status = "passed"; File = $relativePath; Duration = $elapsed; Stdout = $stdout }
        } else {
            Write-Log "FAILED (exit $($proc.ExitCode)): $relativePath" "ERROR"
            if ($Verbose -and $stderr) { Write-Host $stderr -ForegroundColor DarkRed }
            return @{ Status = "failed"; File = $relativePath; Reason = "exit code $($proc.ExitCode)"; Stderr = $stderr; Duration = $elapsed }
        }
    } catch {
        Write-Log "ERROR running '$relativePath': $_" "ERROR"
        return @{ Status = "failed"; File = $relativePath; Reason = $_.ToString() }
    } finally {
        Remove-Item "$OutputDir\stdout_temp.txt" -ErrorAction SilentlyContinue
        Remove-Item "$OutputDir\stderr_temp.txt" -ErrorAction SilentlyContinue
    }
}

function Write-Summary {
    $total = $Results.Passed.Count + $Results.Failed.Count + $Results.Skipped.Count
    Write-Log "============================" "INFO"
    Write-Log "SUMMARY: $total example(s) run" "INFO"
    Write-Log "  Passed:  $($Results.Passed.Count)" "SUCCESS"
    Write-Log "  Failed:  $($Results.Failed.Count)" $(if ($Results.Failed.Count -gt 0) { "ERROR" } else { "INFO" })
    Write-Log "  Skipped: $($Results.Skipped.Count)" "WARN"
    Write-Log "============================" "INFO"

    if ($Results.Failed.Count -gt 0) {
        Write-Log "Failed examples:" "ERROR"
        foreach ($f in $Results.Failed) {
            Write-Log "  - $($f.File): $($f.Reason)" "ERROR"
        }
    }
}

# --- Main ---

if (-not (Test-PythonAvailable)) {
    Write-Log "Python is not available on PATH. Aborting." "ERROR"
    exit 1
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$examples = Get-ExampleFiles -Directory $ExamplesDir
if ($examples.Count -eq 0) {
    Write-Log "No example files found in '$ExamplesDir'." "WARN"
    exit 0
}

Write-Log "Found $($examples.Count) example file(s) in '$ExamplesDir'."

foreach ($example in $examples) {
    $result = Invoke-Example -File $example -Timeout $TimeoutSeconds
    switch ($result.Status) {
        "passed"  { $Results.Passed  += $result }
        "failed"  { $Results.Failed  += $result }
        "skipped" { $Results.Skipped += $result }
    }
    if ($FailFast -and $result.Status -eq "failed") {
        Write-Log "FailFast enabled — stopping after first failure." "WARN"
        break
    }
}

Write-Summary

if ($Results.Failed.Count -gt 0) { exit 1 } else { exit 0 }
