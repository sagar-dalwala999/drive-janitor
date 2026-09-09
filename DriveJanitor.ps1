<#
.SYNOPSIS
    Drive Janitor entry point. Double-click the desktop/Start Menu shortcut for the GUI,
    or run "-CLI" from a terminal for a headless text-mode scan.
.PARAMETER CLI
    Run a no-GUI text scan and print a findings table instead of loading the WPF window.
.PARAMETER DryRun
    With -CLI, also run the cleaner's dry-run for the auto-selected (Safe-risk) findings —
    prints the exact would-delete path list and predicted bytes. Touches nothing on disk.
#>
[CmdletBinding()]
param(
    [switch]$CLI,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # one bad scanner/module must not kill the whole run

# --- WPF needs STA. Windows PowerShell 5.1's console host defaults to STA, but "Run with
#     PowerShell" from Explorer and some launchers don't guarantee it - relaunch defensively. ---
if (-not $CLI) {
    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -ne 'STA') {
        $psExe = Join-Path $PSHOME 'powershell.exe'
        $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
        if ($DryRun) { $relaunchArgs += '-DryRun' }
        Start-Process -FilePath $psExe -ArgumentList $relaunchArgs
        exit 0
    }
}

# --- Core is frozen and guaranteed present - hard fail if it's missing, that's an environment
#     problem, not a "scanner not built yet" situation. Everything else is best-effort. ---
$coreModulePath = Join-Path $PSScriptRoot 'modules\Core.psm1'
Import-Module $coreModulePath -Force -Global -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'modules\Config.psm1') -Force -Global -ErrorAction Stop

$script:ScannerSpecs = @(
    @{ Stage = 'BuildCache'; Module = 'Scanner.BuildCache.psm1'; Func = 'Invoke-BuildCacheScan' },
    @{ Stage = 'BrowserApp'; Module = 'Scanner.BrowserApp.psm1'; Func = 'Invoke-BrowserAppScan' },
    @{ Stage = 'Projects';   Module = 'Scanner.Projects.psm1';   Func = 'Invoke-ProjectScan' },
    @{ Stage = 'System';     Module = 'Scanner.System.psm1';     Func = 'Invoke-SystemScan' }
)
foreach ($s in $script:ScannerSpecs) {
    $modPath = Join-Path $PSScriptRoot "modules\$($s.Module)"
    if (Test-Path -LiteralPath $modPath) {
        try { Import-Module $modPath -Force -ErrorAction Stop }
        catch { Write-JanitorLog -Level 'ERROR' -Message "import failed: $($s.Module): $_" }
    } else {
        Write-JanitorLog -Level 'INFO' -Message "$($s.Module) not present yet - stage '$($s.Stage)' will be skipped"
    }
}
$cleanerPath = Join-Path $PSScriptRoot 'modules\Cleaner.psm1'
if (Test-Path -LiteralPath $cleanerPath) {
    try { Import-Module $cleanerPath -Force -ErrorAction Stop }
    catch { Write-JanitorLog -Level 'ERROR' -Message "import failed: Cleaner.psm1: $_" }
} else {
    Write-JanitorLog -Level 'INFO' -Message 'Cleaner.psm1 not present yet - clean/dry-run disabled this run'
}

# Sibling modules -Force-reimport Core.psm1 internally, which strips its functions back out of
# this scope (reproduced empirically) - reimport last, -Global, so our bindings survive.
Import-Module $coreModulePath -Force -Global -ErrorAction Stop

# Pinned S6<->S7 contract: pure + synchronous, never touches WPF. A missing/throwing scanner is
# logged and skipped so it never takes down the other three.
function Invoke-AllScans {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        [scriptblock]$ProgressCallback,
        [switch]$IncludeDuplicates
    )
    # The four scanners are independent and I/O-bound, so running them concurrently costs the
    # slowest one rather than the sum - roughly halves a full-drive scan.
    $findings = @()

    # $PSScriptRoot is EMPTY when this function is transplanted into the GUI's background
    # runspace, so derive the module dir from Core (always imported -Global) and only fall
    # back to $PSScriptRoot. Getting this wrong fails as "Cannot bind argument to 'Path'".
    $moduleDir = $null
    $coreMod = Get-Module -Name 'Core' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($coreMod -and $coreMod.Path) { $moduleDir = Split-Path -Parent $coreMod.Path }
    if (-not $moduleDir -and $PSScriptRoot) { $moduleDir = Join-Path $PSScriptRoot 'modules' }
    if (-not $moduleDir -or -not (Test-Path -LiteralPath $moduleDir)) {
        throw "Invoke-AllScans: cannot locate the modules directory (resolved '$moduleDir')"
    }

    $Roots = @($Roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Roots.Count -eq 0) { throw 'Invoke-AllScans: no valid roots to scan' }
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $script:ScannerSpecs.Count)
    $pool.ApartmentState = 'MTA'
    $pool.Open()

    $work = @()
    foreach ($s in $script:ScannerSpecs) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript({
            param($ModuleDir, $ModuleFile, $Func, $Roots, $IncludeDuplicates)
            Import-Module (Join-Path $ModuleDir 'Core.psm1') -ErrorAction Stop
            Import-Module (Join-Path $ModuleDir $ModuleFile) -ErrorAction Stop
            $extra = @{}
            if ($Func -eq 'Invoke-ProjectScan' -and $IncludeDuplicates) { $extra['IncludeDuplicates'] = $true }
            & $Func -Roots $Roots @extra
        }).AddArgument($moduleDir).AddArgument($s.Module).AddArgument($s.Func).AddArgument($Roots).AddArgument([bool]$IncludeDuplicates)
        $work += [pscustomobject]@{ Stage = $s.Stage; Func = $s.Func; PS = $ps; Handle = $ps.BeginInvoke() }
    }

    $total = $work.Count
    $done = 0
    while ($done -lt $total) {
        Start-Sleep -Milliseconds 250
        $done = @($work | Where-Object { $_.Handle.IsCompleted }).Count
        if ($ProgressCallback) {
            $running = ($work | Where-Object { -not $_.Handle.IsCompleted } | ForEach-Object { $_.Stage }) -join ', '
            try {
                & $ProgressCallback ([pscustomobject]@{
                    Stage           = $(if ($running) { $running } else { 'System' })
                    CurrentPath     = $(if ($running) { "scanning: $running" } else { 'done' })
                    PercentComplete = [int](100 * $done / $total)
                })
            } catch { }
        }
    }

    foreach ($w in $work) {
        try {
            $r = $w.PS.EndInvoke($w.Handle)
            if ($w.PS.Streams.Error.Count) {
                foreach ($e in $w.PS.Streams.Error) { Write-JanitorLog -Level 'ERROR' -Message "$($w.Func): $e" }
            }
            if ($r) { $findings += @($r) }
        } catch {
            Write-JanitorLog -Level 'ERROR' -Message "$($w.Func) threw - stage $($w.Stage) skipped: $_"
        } finally { $w.PS.Dispose() }
    }
    $pool.Close(); $pool.Dispose()

    if ($ProgressCallback) {
        try { & $ProgressCallback ([pscustomobject]@{ Stage = 'System'; CurrentPath = 'done'; PercentComplete = 100 }) } catch { }
    }
    return $findings
}

$configPath = Get-JanitorConfigPath
$config = Get-JanitorConfig -Path $configPath

# --- -CLI: headless text scan, optional dry run. Never loads WPF. ---
if ($CLI) {
    Write-Host "Drive Janitor - CLI scan" -ForegroundColor Cyan
    Write-Host "Roots: $($config.Roots -join ', ')"
    $dupes = $false
    try { $dupes = [bool]$config.FindDuplicates } catch { }
    if ($dupes) { Write-Host "Duplicate detection: ON (slower)" -ForegroundColor DarkGray }
    $findings = Invoke-AllScans -Roots $config.Roots -IncludeDuplicates:$dupes -ProgressCallback {
        param($p) Write-Host ("  [{0,3}%] {1}" -f $p.PercentComplete, $p.Stage)
    }

    if (-not $findings -or $findings.Count -eq 0) {
        Write-Host "`nNo findings (scanners may not be built yet, or the drives are clean)." -ForegroundColor Yellow
    } else {
        $totalBytes = ($findings | Measure-Object -Property Bytes -Sum).Sum
        Write-Host ("`n{0} finding(s), {1} total:" -f $findings.Count, (Format-Size $totalBytes))
        $findings | Sort-Object -Property Bytes -Descending |
            Format-Table -AutoSize `
                @{ Label = 'Category'; Expression = { $_.Category } },
                @{ Label = 'Title'; Expression = { $_.Title } },
                @{ Label = 'Size'; Expression = { Format-Size $_.Bytes } },
                @{ Label = 'Risk'; Expression = { $_.Risk } },
                @{ Label = 'Action'; Expression = { $_.Action } } |
            Out-String -Width 200 | Write-Host
    }

    if ($DryRun) {
        Write-Host "-- Dry run (Safe-risk / auto-selected findings only) --" -ForegroundColor Cyan
        if (Get-Command -Name Invoke-Clean -ErrorAction SilentlyContinue) {
            $selected = @($findings | Where-Object Selected)
            $result = Invoke-Clean -Findings $selected -DryRun
            Write-Host ("Would reclaim: {0} across {1} selected finding(s)" -f (Format-Size $result.Predicted), $selected.Count)
            foreach ($f in $selected) { foreach ($p in $f.Paths) { Write-Host "  $p" } }
        } else {
            Write-Host "Cleaner.psm1 not present yet - dry run limited to the findings list above." -ForegroundColor Yellow
        }
    }
    return
}

# S6 owns ui\*, exposing Show-JanitorWindow -DefaultRoots; it captures Invoke-AllScans + every
# loaded module into its own background runspace. Falls back to a message if S6 isn't built yet.
$guiScript = Join-Path $PSScriptRoot 'ui\Gui.ps1'
$launched = $false
if (Test-Path -LiteralPath $guiScript) {
    try {
        . $guiScript
        $entry = Get-Command -Name Show-JanitorWindow -ErrorAction SilentlyContinue
        if ($entry) {
            & $entry -DefaultRoots $config.Roots
            $launched = $true
        } else {
            Write-JanitorLog -Level 'ERROR' -Message 'ui\Gui.ps1 loaded but Show-JanitorWindow was not found'
        }
    } catch {
        Write-JanitorLog -Level 'ERROR' -Message "GUI load failed: $_"
    }
}

if (-not $launched) {
    $msg = "Drive Janitor's window isn't available yet (ui\Gui.ps1 missing or incomplete).`n`nRun from a terminal with -CLI for a text-mode scan in the meantime."
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    try { [System.Windows.MessageBox]::Show($msg, 'Drive Janitor', 'OK', 'Information') | Out-Null }
    catch { Write-Host $msg -ForegroundColor Yellow }
}
