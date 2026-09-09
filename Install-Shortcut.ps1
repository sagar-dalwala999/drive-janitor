<#
.SYNOPSIS
    Creates/updates the Desktop and Start Menu shortcuts for Drive Janitor. Safe to re-run —
    it always overwrites the same two .lnk files, never duplicates them.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest

$toolRoot = $PSScriptRoot
$scriptPath = Join-Path $toolRoot 'DriveJanitor.ps1'
$psExe = Join-Path $PSHOME 'powershell.exe'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Error "DriveJanitor.ps1 not found next to this installer ($toolRoot) - run Install-Shortcut.ps1 from the tool's own folder."
    return
}

# No slice owns a .ico asset - use a built-in shell32.dll icon instead of requiring one.
# Icon indices vary across Windows builds, so verify each candidate actually resolves rather
# than trusting a hardcoded number; index 0 always exists and is the final fallback.
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
Add-Type -Namespace JanitorInstall -Name IconProbe -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    public static extern int ExtractIconEx(string szFileName, int nIconIndex, System.IntPtr[] phiconLarge, System.IntPtr[] phiconSmall, int nIcons);
'@ -ErrorAction SilentlyContinue

function Test-Shell32IconIndex {
    param([int]$Index)
    try {
        $large = New-Object System.IntPtr[] 1
        $small = New-Object System.IntPtr[] 1
        $shell32 = Join-Path $env:SystemRoot 'System32\shell32.dll'
        $count = [JanitorInstall.IconProbe]::ExtractIconEx($shell32, $Index, $large, $small, 1)
        return ($count -gt 0) -and ($large[0] -ne [IntPtr]::Zero)
    } catch { return $false }
}

# Preference order: recycle-bin/cleanup-flavoured icons first, then 0 which is always valid.
$iconCandidates = @(238, 31, 32, 137, 45, 0)
$iconIndex = 0
foreach ($c in $iconCandidates) {
    if (Test-Shell32IconIndex -Index $c) { $iconIndex = $c; break }
}
$iconLocation = "$env:SystemRoot\System32\shell32.dll,$iconIndex"

$shortcutArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$scriptPath`""

function Set-JanitorShortcut {
    param([Parameter(Mandatory)][string]$LinkPath)
    $shell = New-Object -ComObject WScript.Shell
    try {
        $sc = $shell.CreateShortcut($LinkPath)
        $sc.TargetPath = $psExe
        $sc.Arguments = $shortcutArgs
        $sc.WorkingDirectory = $toolRoot
        $sc.IconLocation = $iconLocation
        $sc.Description = 'Drive Janitor - scan and reclaim disk space'
        $sc.Save()
    } finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
}

$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Drive Janitor.lnk'
$startMenuLink = Join-Path ([Environment]::GetFolderPath('Programs')) 'Drive Janitor.lnk'

Set-JanitorShortcut -LinkPath $desktopLink
Set-JanitorShortcut -LinkPath $startMenuLink

Write-Host "Drive Janitor shortcuts installed:" -ForegroundColor Cyan
Write-Host "  Desktop:    $desktopLink"
Write-Host "  Start Menu: $startMenuLink"
Write-Host "  Target:     $psExe $shortcutArgs"
Write-Host "  Icon:       $iconLocation"
