# Windows system reclaim scanner - S4. Pure read-only: recycle bins, Downloads triage,
# Windows Update cache, Windows Installer cache (report-only), WinSxS via DISM, hibernation, big files.

Set-StrictMode -Version Latest
# No -Force: it evicts an already-global Core into this module's private scope and strips
# Core's functions from every caller (S7's orchestrator, S6's GUI).
Import-Module (Join-Path $PSScriptRoot 'Core.psm1')

# Directory basenames that S1 (build/cache) or S3 (node_modules) already count elsewhere -
# the big-file finder must not re-report bytes living under any of these.
$script:PruneNames = [Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'node_modules', '.cxx', '.gradle', '.next', '.turbo', '.parcel-cache', '__pycache__',
        '.venv', 'venv', 'dist', 'build', 'target', '.cache', 'cache', 'code cache', 'gpucache',
        'service worker', 'optguideondevicemodel', 'cachedextensionvsixs', 'huggingface',
        'codex-runtimes', 'antigravity-backup', '.codeium', 'npm-cache', '.nuget', 'pip', '.git'
    ),
    [StringComparer]::OrdinalIgnoreCase
)

# These four Windows system trees can never legitimately hold a >500MB user file worth reporting
# (Test-PathProtected already refuses them unconditionally) - pruning them here avoids the full
# enumeration cost of hundreds of thousands of OS directories on a default C:\+D:\ scan.
$script:ExcludedSystemTrees = @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')

function Test-ExcludedSystemTree {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.TrimEnd('\')
    foreach ($ex in $script:ExcludedSystemTrees) { if ($p -ieq $ex) { return $true } }
    return $false
}

function Get-DirStatsSafe {
    <# Manual walk that never follows reparse points - Get-ChildItem -Recurse in PS5.1 does not guard this. #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [long]0
    $count = 0
    $visited = 0
    $stack = [Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    try { $stack.Push([IO.DirectoryInfo]::new($Path)) } catch { return [pscustomobject]@{ Bytes = [long]0; Count = 0 } }
    while ($stack.Count -gt 0 -and $visited -lt 100000) {
        $visited++
        $dir = $stack.Pop()
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        try {
            foreach ($f in $dir.EnumerateFiles()) {
                if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $bytes += $f.Length
                $count++
            }
        } catch { }
        try { foreach ($sub in $dir.EnumerateDirectories()) { $stack.Push($sub) } } catch { }
    }
    return [pscustomobject]@{ Bytes = [long]$bytes; Count = $count }
}

function Get-RootDriveLetters {
    <# Returns each distinct "C:\" style drive root present among -Roots, canonicalized via Core. #>
    param([string[]]$Roots)
    $set = [Collections.Generic.List[string]]::new()
    foreach ($r in $Roots) {
        $resolved = Resolve-JanitorPath -Path $r
        if ($null -eq $resolved) { continue }
        $drive = $resolved.Substring(0, 3)
        if (-not ($set -contains $drive)) { $set.Add($drive) }
    }
    return $set.ToArray()
}

function ConvertTo-BytesFromDismSize {
    param([string]$Value, [string]$Unit)
    $n = 0.0
    if (-not [double]::TryParse($Value, [ref]$n)) { return [long]0 }
    switch ($Unit) {
        'KB' { return [long]($n * 1KB) }
        'MB' { return [long]($n * 1MB) }
        'GB' { return [long]($n * 1GB) }
        'TB' { return [long]($n * 1TB) }
        default { return [long]0 }
    }
}

function Get-RecycleBinFinding {
    param([Parameter(Mandatory)][string]$DriveLetter)
    $path = Join-Path $DriveLetter '$Recycle.Bin'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $stats = Get-DirStatsSafe -Path $path
    if ($stats.Count -eq 0) { return $null }
    $disp = $DriveLetter.TrimEnd('\')
    New-Finding -Category 'Recycle Bin' -Title "Recycle Bin - $disp" `
        -Paths @($path) -Bytes $stats.Bytes -Count $stats.Count -Risk Advanced -Action RecycleBin `
        -Detail "$($stats.Count) file(s) currently in the $disp Recycle Bin ($(Format-Size $stats.Bytes)). Other user profiles' bins are skipped without elevation." `
        -Consequence 'Permanently empties the bin via the Windows Recycle Bin API, not a raw delete - once cleared there is no Undo/Restore for these items.'
}

function Get-DownloadsFindings {
    param([Parameter(Mandatory)][string]$DownloadsPath)
    if (-not (Test-Path -LiteralPath $DownloadsPath)) { return @() }

    $now = Get-Date
    $buckets = [ordered]@{
        '< 30 days'   = [Collections.Generic.List[System.IO.FileInfo]]::new()
        '30-90 days'  = [Collections.Generic.List[System.IO.FileInfo]]::new()
        '90-365 days' = [Collections.Generic.List[System.IO.FileInfo]]::new()
        'over 1 year' = [Collections.Generic.List[System.IO.FileInfo]]::new()
    }

    $stack = [Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    try { $stack.Push([IO.DirectoryInfo]::new($DownloadsPath)) } catch { return @() }
    $visited = 0
    while ($stack.Count -gt 0 -and $visited -lt 100000) {
        $visited++
        $dir = $stack.Pop()
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        try {
            foreach ($f in $dir.EnumerateFiles()) {
                if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $age = ($now - $f.LastWriteTime).Days
                if ($age -lt 30) { $buckets['< 30 days'].Add($f) }
                elseif ($age -lt 90) { $buckets['30-90 days'].Add($f) }
                elseif ($age -lt 365) { $buckets['90-365 days'].Add($f) }
                else { $buckets['over 1 year'].Add($f) }
            }
        } catch { }
        try { foreach ($sub in $dir.EnumerateDirectories()) { $stack.Push($sub) } } catch { }
    }

    $out = [Collections.Generic.List[object]]::new()
    foreach ($label in $buckets.Keys) {
        $list = $buckets[$label]
        if ($list.Count -eq 0) { continue }
        $bytes = [long](($list | Measure-Object -Property Length -Sum).Sum)
        $top = $list | Sort-Object Length -Descending | Select-Object -First 5
        $topDesc = ($top | ForEach-Object { "$($_.Name) ($(Format-Size $_.Length))" }) -join '; '
        $paths = @($list | Sort-Object Length -Descending | Select-Object -First 100 | ForEach-Object { $_.FullName })
        $out.Add((New-Finding -Category 'Downloads' -Title "Downloads - $label" `
            -Paths $paths -Bytes $bytes -Count $list.Count -Risk Advanced -Action Report `
            -Detail "$($list.Count) file(s), $(Format-Size $bytes) total. Largest: $topDesc" `
            -Consequence 'Your own downloaded files - this tool never deletes them automatically. Review and remove by hand if no longer needed.'))
    }
    return $out.ToArray()
}

function Get-SoftwareDistributionFinding {
    $path = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $stats = $null
    try { $stats = Get-DirStatsSafe -Path $path } catch { return $null }
    if ($stats.Count -eq 0) { return $null }
    New-Finding -Category 'Windows Update Cache' -Title 'Windows Update download cache' `
        -Paths @($path) -Bytes $stats.Bytes -Count $stats.Count -Risk Moderate -Action Empty `
        -Detail "$($stats.Count) cached update file(s), $(Format-Size $stats.Bytes)." `
        -Consequence 'Windows re-downloads only what it still needs on the next update check. Already-installed updates and system stability are unaffected.'
}

function Get-InstallerFinding {
    <# Report-only, always - orphan detection here is a documented false-positive risk (spec.md S4). #>
    param([Parameter(Mandatory)][bool]$IsElevated)
    $installerDir = Join-Path $env:SystemRoot 'Installer'
    if (-not (Test-Path -LiteralPath $installerDir)) { return $null }

    $files = $null
    try {
        $files = @([IO.Directory]::EnumerateFiles($installerDir, '*.ms*', [IO.SearchOption]::TopDirectoryOnly) |
                   Where-Object { $_ -match '\.(msi|msp)$' })
    } catch {
        return New-Finding -Category 'Windows Installer Cache' -Title 'Windows Installer cache - access denied' `
            -Paths @($installerDir) -Bytes 0 -Count 0 -Risk Advanced -Action Report `
            -Detail "C:\Windows\Installer is restricted to Administrators/SYSTEM by default (elevated=$IsElevated). Re-run elevated to inventory it." `
            -Consequence 'Not analyzed. Orphan detection for this cache is unreliable even when possible; a wrong delete permanently breaks repair/uninstall for installed software. Report-only, by design.'
    }
    if (-not $files -or $files.Count -eq 0) { return $null }

    $referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $udRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
        if (Test-Path $udRoot) {
            Get-ChildItem $udRoot -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($p -and $p.PSObject.Properties['LocalPackage'] -and $p.LocalPackage) {
                        [void]$referenced.Add([IO.Path]::GetFileName($p.LocalPackage))
                    }
                } catch { }
            }
        }
    } catch { }

    if ($referenced.Count -eq 0) {
        return New-Finding -Category 'Windows Installer Cache' -Title 'Windows Installer cache - orphan status unknown' `
            -Paths @($installerDir) -Bytes 0 -Count 0 -Risk Advanced -Action Report `
            -Detail "Found $($files.Count) cached .msi/.msp files but could not read the Installer UserData registry to cross-reference which are still in use - treat all as potentially referenced." `
            -Consequence 'Not analyzed reliably. Orphan detection here is inherently unreliable; report-only, never delete.'
    }

    $candidates = [Collections.Generic.List[string]]::new()
    $candidateBytes = [long]0
    foreach ($f in $files) {
        if ($referenced.Contains([IO.Path]::GetFileName($f))) { continue }
        try { $len = [IO.FileInfo]::new($f).Length } catch { $len = 0 }
        $candidates.Add($f)
        $candidateBytes += $len
    }
    if ($candidates.Count -eq 0) { return $null }

    New-Finding -Category 'Windows Installer Cache' -Title 'Windows Installer orphan candidates' `
        -Paths @($candidates | Select-Object -First 100) -Bytes $candidateBytes -Count $candidates.Count `
        -Risk Advanced -Action Report `
        -Detail "$($candidates.Count) of $($files.Count) cached .msi/.msp files have no matching LocalPackage reference under the Installer UserData registry (best-effort filename cross-reference, not authoritative)." `
        -Consequence 'Orphan detection for Windows Installer cache is notoriously unreliable - a wrong delete permanently breaks repair and uninstall for installed software. Report-only; verify manually with a dedicated tool before ever acting on this.'
}

function Get-WinSxSFinding {
    param([Parameter(Mandatory)][bool]$IsElevated)
    $winSxSPath = Join-Path $env:SystemRoot 'WinSxS'
    if (-not (Test-Path -LiteralPath $winSxSPath)) { return $null }

    if (-not $IsElevated) {
        return New-Finding -Category 'Component Store (WinSxS)' -Title 'Component store (WinSxS) - elevation required' `
            -Paths @($winSxSPath) -Bytes 0 -Count 0 -Risk Advanced -Action Dism `
            -Detail 'DISM /Online /Cleanup-Image /AnalyzeComponentStore requires an elevated (Administrator) session. Re-run this scan as Administrator for a reclaim estimate.' `
            -Consequence "Not analyzed. WinSxS is never deleted directly - Core's guard blocks that outright - only DISM's own component cleanup is safe, and only what DISM itself reports as reclaimable."
    }

    try {
        $out = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
        $exit = $LASTEXITCODE
        if ($exit -ne 0 -or -not $out) {
            return New-Finding -Category 'Component Store (WinSxS)' -Title 'Component store (WinSxS) - analysis failed' `
                -Paths @($winSxSPath) -Bytes 0 -Count 0 -Risk Advanced -Action Dism `
                -Detail "DISM analysis did not complete (exit code $exit)." `
                -Consequence 'Not analyzed. Re-run manually: dism.exe /Online /Cleanup-Image /AnalyzeComponentStore'
        }
        $text = ($out | Out-String)
        $reclaimBytes = [long]0
        if ($text -match 'Backups and Disabled Features\s*:\s*([\d.]+)\s*(KB|MB|GB|TB)') {
            $reclaimBytes = ConvertTo-BytesFromDismSize -Value $Matches[1] -Unit $Matches[2]
        }
        $recommended = ($text -match 'Component Store Cleanup Recommended\s*:\s*Yes')
        New-Finding -Category 'Component Store (WinSxS)' -Title 'Component store (WinSxS)' `
            -Paths @($winSxSPath) -Bytes $reclaimBytes -Count 1 -Risk Advanced -Action Dism `
            -Detail "DISM's own breakdown:`n$text`nReclaim estimate uses DISM's 'Backups and Disabled Features' figure - actual bytes freed by /StartComponentCleanup can differ." `
            -Consequence "Cleanup Recommended: $(if ($recommended) { 'Yes' } else { 'No' }). Runs DISM's own /StartComponentCleanup, which removes superseded component versions and can remove the ability to uninstall the updates/service packs it clears. WinSxS itself is never deleted directly."
    } catch {
        New-Finding -Category 'Component Store (WinSxS)' -Title 'Component store (WinSxS) - analysis error' `
            -Paths @($winSxSPath) -Bytes 0 -Count 0 -Risk Advanced -Action Dism `
            -Detail "DISM analysis threw an error: $($_.Exception.Message)" `
            -Consequence 'Not analyzed.'
    }
}

function Get-HibernationFinding {
    $path = Join-Path ($env:SystemDrive) 'hiberfil.sys'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $bytes = [long]0
    $known = $true
    try { $bytes = [IO.FileInfo]::new($path).Length } catch { $known = $false }
    $sizeNote = if ($known) { Format-Size $bytes } else { 'size unknown - elevate for an exact figure' }
    New-Finding -Category 'Hibernation File' -Title 'Hibernation file (hiberfil.sys)' `
        -Paths @($path) -Bytes $bytes -Count 1 -Risk Advanced -Action Report `
        -Detail "Hibernation is enabled ($sizeNote). This tool never deletes hiberfil.sys directly - Core's guard blocks that outright." `
        -Consequence "To reclaim this space, disable hibernation (also disables Fast Startup): run 'powercfg /h off' from an elevated prompt. Re-enable any time with 'powercfg /h on'."
}

function Get-BigFileFinding {
    <# Prunes anything Test-PathProtected already blocks plus known S1/S3 cache-root names, so this
       never re-reports bytes those scanners already counted. #>
    param([Parameter(Mandatory)][string]$Root)
    $minBytes = 500L * 1MB
    $cap = 500
    $candidates = [Collections.Generic.List[System.IO.FileInfo]]::new()
    $stack = [Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
    try { $stack.Push([IO.DirectoryInfo]::new($Root)) } catch { return @() }
    $visited = 0
    while ($stack.Count -gt 0 -and $candidates.Count -lt $cap -and $visited -lt 200000) {
        $visited++
        $dir = $stack.Pop()
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($script:PruneNames.Contains($dir.Name)) { continue }
        if (Test-ExcludedSystemTree -Path $dir.FullName) { continue }   # never descend - hundreds of thousands of OS dirs, zero possible payoff
        # Test-PathProtected gates REPORTING only, not recursion: it exact-matches drive roots
        # (C:\, D:\) and C:\Users themselves, and the old code used it to gate descent too - which
        # meant Get-BigFileFinding silently did zero work for the default root="C:\" config (the
        # very first pop was already "protected", so its children were never even enumerated).
        if (-not (Test-PathProtected -Path $dir.FullName)) {
            try {
                foreach ($f in $dir.EnumerateFiles()) {
                    if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($f.Length -ge $minBytes) { $candidates.Add($f) }
                }
            } catch { }
        }
        try { foreach ($sub in $dir.EnumerateDirectories()) { $stack.Push($sub) } } catch { }
    }
    if ($candidates.Count -eq 0) { return @() }

    $bytes = [long](($candidates | Measure-Object -Property Length -Sum).Sum)
    $top = $candidates | Sort-Object Length -Descending | Select-Object -First 10
    $topDesc = ($top | ForEach-Object { "$($_.FullName) ($(Format-Size $_.Length))" }) -join '; '
    $paths = @($candidates | Sort-Object Length -Descending | Select-Object -First 200 | ForEach-Object { $_.FullName })

    @(New-Finding -Category 'Large Files' -Title "Large files (>500 MB) - $Root" `
        -Paths $paths -Bytes $bytes -Count $candidates.Count -Risk Advanced -Action Report `
        -Detail "Excludes node_modules, android\build, .cxx, and known build/package-cache roots already counted by other scanners. Largest: $topDesc" `
        -Consequence 'Could be anything from a disposable ISO/VM image to footage or an archive you still need - judge each individually before deleting.')
}

function Invoke-SystemScan {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string[]]$Roots)

    $findings = [Collections.Generic.List[object]]::new()
    $isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).
                  IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $driveLetters = Get-RootDriveLetters -Roots $Roots
    $systemDrive = ($env:SystemDrive.TrimEnd('\')) + '\'

    try {
        foreach ($d in $driveLetters) {
            $f = Get-RecycleBinFinding -DriveLetter $d
            if ($f) { $findings.Add($f) }
        }
    } catch { Write-JanitorLog -Level ERROR -Message "recycle bin scan failed: $_" }

    try {
        $downloadsPath = Join-Path $env:USERPROFILE 'Downloads'
        $downloadsResolved = Resolve-JanitorPath -Path $downloadsPath
        if ($downloadsResolved -and ($driveLetters -contains $downloadsResolved.Substring(0, 3))) {
            Get-DownloadsFindings -DownloadsPath $downloadsPath | ForEach-Object { $findings.Add($_) }
        }
    } catch { Write-JanitorLog -Level ERROR -Message "downloads scan failed: $_" }

    if ($driveLetters -contains $systemDrive) {
        try { $f = Get-SoftwareDistributionFinding; if ($f) { $findings.Add($f) } }
        catch { Write-JanitorLog -Level ERROR -Message "software distribution scan failed: $_" }

        try { $f = Get-InstallerFinding -IsElevated $isElevated; if ($f) { $findings.Add($f) } }
        catch { Write-JanitorLog -Level ERROR -Message "installer scan failed: $_" }

        try { $f = Get-WinSxSFinding -IsElevated $isElevated; if ($f) { $findings.Add($f) } }
        catch { Write-JanitorLog -Level ERROR -Message "winsxs scan failed: $_" }

        try { $f = Get-HibernationFinding; if ($f) { $findings.Add($f) } }
        catch { Write-JanitorLog -Level ERROR -Message "hibernation scan failed: $_" }
    }

    foreach ($root in $Roots) {
        try { Get-BigFileFinding -Root $root | ForEach-Object { $findings.Add($_) } }
        catch { Write-JanitorLog -Level ERROR -Message "big-file scan failed for ${root}: $_" }
    }

    return $findings.ToArray()
}

Export-ModuleMember -Function Invoke-SystemScan
