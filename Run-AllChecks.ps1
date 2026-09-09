<#
.SYNOPSIS
    Runs Drive Janitor's whole safety suite. Run this before trusting a Clean.
.DESCRIPTION
    These are plain PowerShell scripts, deliberately NOT Pester. They were once named
    *.Tests.ps1, which made Invoke-Pester "discover" 0 tests and report Passed - a false green
    on the one suite that proves the tool won't delete your work.
#>
[CmdletBinding()]
param([switch]$SkipSlow)

$ErrorActionPreference = 'Continue'
$checks = @(
    @{ Name = 'Guard      (protected paths)'; File = 'tests\Guard.Checks.ps1';    Slow = $false }
    @{ Name = 'Junction   (data-loss guard)'; File = 'tests\Junction.Checks.ps1'; Slow = $false }
    @{ Name = 'Sizing     (honest numbers)';  File = 'tests\Sizing.Checks.ps1';   Slow = $false }
    @{ Name = 'Integration(cross-slice)';     File = 'tests\Integration.Checks.ps1'; Slow = $true }
)

$results = @()
foreach ($c in $checks) {
    if ($SkipSlow -and $c.Slow) {
        $results += [pscustomobject]@{ Check = $c.Name; Result = 'SKIPPED'; Detail = '-SkipSlow' }
        continue
    }
    $path = Join-Path $PSScriptRoot $c.File
    if (-not (Test-Path -LiteralPath $path)) {
        $results += [pscustomobject]@{ Check = $c.Name; Result = 'MISSING'; Detail = $c.File }
        continue
    }
    Write-Host "`n=== $($c.Name) ===" -ForegroundColor Cyan
    $out = & $path
    $out | Write-Host
    $last = @($out)[-1]
    $ok = ($LASTEXITCODE -eq 0) -and ("$last" -notmatch 'FAILURE')
    $results += [pscustomobject]@{ Check = $c.Name; Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Detail = "$last" }
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failed -gt 0) {
    Write-Host "$failed check(s) FAILED - do not run a Clean until these are green." -ForegroundColor Red
    exit 1
}
Write-Host "All checks passed." -ForegroundColor Green
exit 0
