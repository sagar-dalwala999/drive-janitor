# Drive Janitor — S5: cleaner engine. Owns exactly this file.
# Dispatches findings to Core's Clear-PathContents / Clear-RecycleBin / DISM, never trusting a
# scanner's filtering — every path is re-checked against Test-PathProtected immediately before use.

Set-StrictMode -Version Latest

# No -Force: Core is frozen and never changes mid-session. -Force here would tear down and
# re-scope an already-loaded global Core module out from under the caller (S6/S7 both import it).
if (-not (Get-Module -Name Core)) {
    Import-Module (Join-Path $PSScriptRoot 'Core.psm1')
}

function Get-JanitorDriveLetter {
    <# 'C:\foo\bar' -> 'C'. Returns $null for anything that doesn't start with a drive letter. #>
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):\\') { return $Matches[1].ToUpper() }
    return $null
}

function Get-RecycleBinBytes {
    <# Best-effort sum of recycle-bin item sizes for one drive via the Shell COM API. Explorer
       rounds the displayed size column, so this is approximate — informational, never gating. #>
    param([Parameter(Mandatory)][string]$DriveLetter)
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(0x0A)
        if (-not $bin) { return [long]0 }
        $sum = 0L
        foreach ($item in @($bin.Items())) {
            try {
                $orig = $bin.GetDetailsOf($item, 1)   # "Original Location" column
                if ($orig -notlike "$DriveLetter`:*") { continue }
                $sizeStr = $bin.GetDetailsOf($item, 3) # e.g. "1.25 MB"
                if ($sizeStr -match '([\d.,]+)\s*([A-Za-z]+)') {
                    $num = [double]($Matches[1] -replace ',', '')
                    $mult = switch ($Matches[2].ToUpper()) {
                        'KB' { 1KB }; 'MB' { 1MB }; 'GB' { 1GB }; 'TB' { 1TB }; default { 1 }
                    }
                    $sum += [long]($num * $mult)
                }
            } catch { }
        }
        return $sum
    } catch { return [long]0 }
}

function Test-JanitorIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Long-path-safe helpers (mirrors the \\?\ technique Scanner.Projects.psm1 already uses) ---
# Test-Path/Get-ChildItem silently misreport a >260-char path as absent when LongPathsEnabled=0 -
# a false "path no longer exists" is worse than an error, since the user believes it was handled.
$script:JanitorLongPathThreshold = 240

function ConvertTo-JanitorIoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Length -ge $script:JanitorLongPathThreshold -and -not $Path.StartsWith('\\?\')) { return "\\?\$Path" }
    return $Path
}

function Test-JanitorIsReparse {
    param([Parameter(Mandatory)][string]$IoPath)
    try { return [bool]([IO.File]::GetAttributes($IoPath) -band [IO.FileAttributes]::ReparsePoint) }
    catch { return $true }   # unreadable - fail closed, treat as a link so we never follow it
}

function Test-JanitorPathExists {
    <# Long-path-safe existence check for a file OR directory target. #>
    param([Parameter(Mandatory)][string]$Path)
    $io = ConvertTo-JanitorIoPath -Path $Path
    try { if ([IO.Directory]::Exists($io)) { return $true } } catch { }
    try { if ([IO.File]::Exists($io)) { return $true } } catch { }
    return $false
}

function Get-JanitorLeftoverFileCount {
    <# Long-path-safe recursive file count - Get-ChildItem -Recurse has the same 260-char blind
       spot as Test-Path, which would previously under-count (or zero-count) leftover locked
       files on a deep tree and misreport a clean as fully successful. #>
    param([Parameter(Mandatory)][string]$Path)
    $count = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push((ConvertTo-JanitorIoPath -Path $Path))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { foreach ($f in [IO.Directory]::EnumerateFiles($dir)) { $count++ } } catch { }
        try { foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) { $stack.Push($d) } } catch { }
    }
    return $count
}

# --- FIX 5 (owner-opinion, conservative half): an Empty action must never sweep a file another
# live process just wrote - %TEMP% is shared OS scratch space, not one app's disposable cache. ---
$script:JanitorRecentFileGuardMinutes = 60

function Test-JanitorHasRecentFile {
    <# Cheap short-circuiting probe: $true as soon as ANY file under Path was modified within
       the guard window. Never descends into a reparse point (matches Clear-PathContents /
       Remove-NestedReparsePoints - a junction's target must never be walked from here). #>
    param([Parameter(Mandatory)][string]$Path, [int]$MinutesGuard = $script:JanitorRecentFileGuardMinutes)
    $cutoffUtc = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesGuard)
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push((ConvertTo-JanitorIoPath -Path $Path))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                try { if ((New-Object IO.FileInfo($f)).LastWriteTimeUtc -gt $cutoffUtc) { return $true } } catch { }
            }
        } catch { }
        try {
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
                if (Test-JanitorIsReparse -IoPath $d) { continue }
                $stack.Push($d)
            }
        } catch { }
    }
    return $false
}

function Clear-JanitorEmptyWithRecencyGuard {
    <# Deletes files older than the guard window, leaves newer ones (and the container dir)
       untouched. Only used when Test-JanitorHasRecentFile found something to protect - the
       common case still goes through Core's proven robocopy mirror. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinutesGuard = $script:JanitorRecentFileGuardMinutes
    )

    $result = [pscustomobject]@{ Freed = [long]0; SkippedRecent = 0 }
    if (Test-PathProtected -Path $Path) {
        Write-JanitorLog -Level 'BLOCK' -Message "protected, refused: $Path"
        return $result
    }
    if (Test-PathReparsePoint -Path $Path) {
        Write-JanitorLog -Level 'BLOCK' -Message "reparse point, refused: $Path"
        return $result
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'empty (recency-guarded)')) { return $result }

    $cutoffUtc = (Get-Date).ToUniversalTime().AddMinutes(-$MinutesGuard)
    $dirsSeen = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push((ConvertTo-JanitorIoPath -Path $Path))

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirsSeen.Add($dir)
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($dir)) {
                try {
                    $fi = New-Object IO.FileInfo($f)
                    if ($fi.LastWriteTimeUtc -gt $cutoffUtc) {
                        $result.SkippedRecent++
                        continue
                    }
                    $len = $fi.Length
                    [IO.File]::Delete($f)
                    $result.Freed += $len
                } catch { }
            }
        } catch { }
        try {
            foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) {
                if (Test-JanitorIsReparse -IoPath $d) { continue }   # never follow a junction/symlink
                $stack.Push($d)
            }
        } catch { }
    }

    # Best-effort cleanup of now-empty subdirs, deepest first; a dir still holding a preserved
    # recent file simply fails Directory.Delete and is left in place.
    foreach ($d in ($dirsSeen | Sort-Object Length -Descending)) {
        if ($d -eq (ConvertTo-JanitorIoPath -Path $Path)) { continue }   # never remove the container itself
        try { [IO.Directory]::Delete($d, $false) } catch { }
    }

    if ($result.SkippedRecent -gt 0) {
        Write-JanitorLog -Level 'SKIP' -Message "$($result.SkippedRecent) recently-modified file(s) (<${MinutesGuard}m old) preserved under $Path"
    }
    return $result
}

function Invoke-Clean {
    <# Dispatches every finding by .Action. Report is never touched. -DryRun touches nothing.
       Returns @{ Predicted; ActualPathBytes; ActualDriveDeltaBytes; Cleaned; Skipped; Blocked; Errors }
       per the pinned S5 result contract in sprints/spec.md. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject[]]$Findings,
        [switch]$DryRun,
        [scriptblock]$ProgressCallback
    )

    $predicted       = [long]0
    $actualPathBytes = [long]0
    $cleaned = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $blocked = [Collections.Generic.List[object]]::new()
    $errors  = [Collections.Generic.List[object]]::new()

    $fsWork       = [Collections.Generic.List[object]]::new()  # Empty/Delete path targets
    $rbFindings   = [Collections.Generic.List[object]]::new()
    $dismFindings = [Collections.Generic.List[object]]::new()
    $driveLetters = [Collections.Generic.HashSet[string]]::new()

    foreach ($f in $Findings) {
        # Report is checked first and unconditionally - it must never be cleaned regardless of
        # whatever a stale/default .Selected value happens to be.
        if ($f.Action -eq 'Report') {
            Write-JanitorLog -Level 'SKIP' -Message "Report finding never cleaned: $($f.Title)"
            $skipped.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = ($f.Paths -join '; ')
                Bytes = [long]0; Reason = 'Report finding - informational only, never actioned'
            })
            continue
        }

        # Defense in depth: if the caller passed unfiltered findings, honour an explicit opt-out -
        # but record it, never a silent drop, or the result panel can't account for every finding.
        if ($f.PSObject.Properties['Selected'] -and $f.Selected -eq $false) {
            $skipped.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = ($f.Paths -join '; ')
                Bytes = [long]0; Reason = 'not selected'
            })
            continue
        }

        $predicted += [long]$f.Bytes

        switch ($f.Action) {
            'Empty'  {
                foreach ($p in $f.Paths) {
                    $fsWork.Add([pscustomobject]@{ Finding = $f; Path = $p; Action = 'Empty' })
                    $dl = Get-JanitorDriveLetter $p; if ($dl) { [void]$driveLetters.Add($dl) }
                }
            }
            'Delete' {
                foreach ($p in $f.Paths) {
                    $fsWork.Add([pscustomobject]@{ Finding = $f; Path = $p; Action = 'Delete' })
                    $dl = Get-JanitorDriveLetter $p; if ($dl) { [void]$driveLetters.Add($dl) }
                }
            }
            'RecycleBin' {
                $rbFindings.Add($f)
                foreach ($p in $f.Paths) {
                    $dl = Get-JanitorDriveLetter $p; if ($dl) { [void]$driveLetters.Add($dl) }
                }
            }
            'Dism' { $dismFindings.Add($f) }
            default {
                Write-JanitorLog -Level 'ERROR' -Message "unknown Action '$($f.Action)' on '$($f.Title)'"
                $errors.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = ($f.Paths -join '; ')
                    Reason = "unknown action '$($f.Action)'"
                })
            }
        }
    }

    # Deepest-first so a nested target is never orphaned when its parent dir is removed.
    $fsWork = @($fsWork | Sort-Object { ($_.Path.TrimEnd('\') -split '\\').Count } -Descending)

    $driveBefore = @{}
    if (-not $DryRun) {
        foreach ($dl in $driveLetters) {
            try { $driveBefore[$dl] = (Get-PSDrive -Name $dl -ErrorAction Stop).Free } catch { }
        }
    }

    $total = $fsWork.Count + $rbFindings.Count + $dismFindings.Count
    $done = 0
    function Send-Progress([string]$CurrentPath) {
        if (-not $ProgressCallback) { return }
        $pct = if ($total -gt 0) { [int](($done / $total) * 100) } else { 100 }
        try {
            & $ProgressCallback ([pscustomobject]@{
                Stage = 'Clean'; CurrentPath = $CurrentPath; PercentComplete = $pct
            })
        } catch { }
    }

    foreach ($item in $fsWork) {
        $f = $item.Finding; $p = $item.Path
        $done++; Send-Progress $p

        # Re-check every path immediately before acting, even though the scanner already filtered —
        # a scanner bug must never become data loss.
        if (Test-PathProtected -Path $p) {
            Write-JanitorLog -Level 'BLOCK' -Message "defense-in-depth refused: $p"
            $blocked.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0
                Reason = 'Test-PathProtected refused'
            })
            continue
        }

        if ($DryRun) {
            # FIX 3: an Empty action clears CONTENTS and keeps the container - render that
            # distinguishably from a Delete action (which removes the target itself), so the
            # dry-run list never implies "<path>" itself is what disappears when it isn't.
            $label = if ($item.Action -eq 'Empty') { "contents of $p ($($f.Count) file(s))" } else { $p }
            $cleaned.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $p; DisplayPath = $label
                Action = $item.Action; Bytes = (Get-DirSize -Path $p); DryRun = $true
            })
            continue
        }

        # Long-path-safe existence check (FIX 1) - Test-Path -LiteralPath silently reads a
        # >260-char path as absent when LongPathsEnabled=0, so a real, still-present target was
        # being reported as "path no longer exists" instead of actually being cleaned.
        if (-not (Test-JanitorPathExists -Path $p)) {
            $skipped.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0
                Reason = 'path no longer exists'
            })
            continue
        }

        try {
            $alsoRemove = ($item.Action -eq 'Delete')
            $recentlyPreserved = 0
            if ($item.Action -eq 'Empty' -and (Test-JanitorHasRecentFile -Path $p)) {
                # FIX 5: something under this Empty target was modified within the guard window -
                # route through the selective walker instead of Clear-PathContents' blind mirror
                # so an in-flight write from another live process is never taken.
                $guard = Clear-JanitorEmptyWithRecencyGuard -Path $p -Confirm:$false
                $freed = $guard.Freed
                $recentlyPreserved = $guard.SkippedRecent
                if ($recentlyPreserved -gt 0) {
                    $skipped.Add([pscustomobject]@{
                        Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0
                        Reason = "$recentlyPreserved recently-modified file(s) preserved (<$($script:JanitorRecentFileGuardMinutes)m old) - in-flight write protection"
                    })
                }
            } else {
                $freed = Clear-PathContents -Path $p -AlsoRemoveDir:$alsoRemove -Confirm:$false
            }
            $actualPathBytes += $freed
            $cleaned.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $p; Action = $item.Action; Bytes = $freed
            })

            # robocopy skips locked files without throwing, so a clean can "succeed" and still leave
            # files behind - surface that as Skipped instead of silently reporting a full success.
            # Long-path-safe (FIX 1): the classic Test-Path/Get-ChildItem pair used here previously
            # shared the same >260-char blind spot as the existence check above. Any file already
            # accounted for by the FIX 5 recency guard is excluded here - it wasn't left behind by
            # a lock, it was deliberately preserved, and reporting both would be a misleading
            # duplicate "why" for the exact same file.
            if (Test-JanitorPathExists -Path $p) {
                $leftoverCount = (Get-JanitorLeftoverFileCount -Path $p) - $recentlyPreserved
                if ($leftoverCount -gt 0) {
                    $skipped.Add([pscustomobject]@{
                        Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0
                        Reason = "$leftoverCount file(s) could not be removed - likely locked/in-use"
                    })
                }
            }
        } catch {
            # A clean must never abort halfway — locked/in-use files are skipped, not thrown.
            $msg = $_.Exception.Message
            if ($msg -match 'used by another process|access.*denied|IOException|UnauthorizedAccess') {
                $skipped.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0; Reason = $msg
                })
            } else {
                $errors.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Reason = $msg
                })
            }
        }
    }

    foreach ($f in $rbFindings) {
        foreach ($p in $f.Paths) {
            $done++; Send-Progress $p
            $dl = Get-JanitorDriveLetter $p
            if (-not $dl) {
                $blocked.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0
                    Reason = 'could not resolve a drive letter for RecycleBin action'
                })
                continue
            }

            # FIX 4: spec.md states "call Test-PathProtected on every path immediately before
            # acting" unconditionally. A bare "<drive>\$Recycle.Bin" is only 2 path segments, which
            # trips the guard's own "refuse anything shallower than <drive>\a\b" rule on every
            # call - append a synthetic leaf so the real exact/pattern/ancestor checks still run
            # without that structural false-positive, honouring the invariant without breaking
            # every RecycleBin clean.
            if (Test-PathProtected -Path (Join-Path $p 'x')) {
                Write-JanitorLog -Level 'BLOCK' -Message "defense-in-depth refused: $p"
                $blocked.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Bytes = [long]0
                    Reason = 'Test-PathProtected refused'
                })
                continue
            }

            if ($DryRun) {
                $cleaned.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Action = 'RecycleBin'
                    Bytes = (Get-RecycleBinBytes -DriveLetter $dl); DryRun = $true
                })
                continue
            }

            try {
                $before = Get-RecycleBinBytes -DriveLetter $dl
                Clear-RecycleBin -DriveLetter $dl -Force -ErrorAction Stop -Confirm:$false
                $after = Get-RecycleBinBytes -DriveLetter $dl
                $freed = $before - $after
                $actualPathBytes += $freed
                Write-JanitorLog -Level 'CLEAN' -Message "recycle bin $dl`: freed=$(Format-Size $freed)"
                $cleaned.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Action = 'RecycleBin'; Bytes = $freed
                })
            } catch {
                $errors.Add([pscustomobject]@{
                    Category = $f.Category; Title = $f.Title; Path = $p; Reason = $_.Exception.Message
                })
            }
        }
    }

    $isAdmin = Test-JanitorIsAdmin
    foreach ($f in $dismFindings) {
        $done++; Send-Progress 'WinSxS (DISM)'
        $pathLabel = ($f.Paths -join '; ')

        # Dry-run previews regardless of elevation - it never touches anything either way, and the
        # would-do list should be complete. The admin gate only matters once we actually execute.
        if ($DryRun) {
            $cleaned.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $pathLabel; Action = 'Dism'
                Bytes = $f.Bytes; DryRun = $true
            })
            continue
        }

        if (-not $isAdmin) {
            Write-JanitorLog -Level 'SKIP' -Message "Dism cleanup requires admin, skipped: $($f.Title)"
            $skipped.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $pathLabel; Bytes = [long]0
                Reason = 'requires admin - relaunch the tool elevated'
            })
            continue
        }

        try {
            # /ResetBase makes the cleanup irreversible (drops the ability to uninstall superseded
            # updates) - this is the exact dangerous_action named in brief.md, run only when admin.
            & dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "dism.exe exited $LASTEXITCODE" }
            Write-JanitorLog -Level 'CLEAN' -Message "DISM component cleanup ran: $($f.Title)"
            $cleaned.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $pathLabel; Action = 'Dism'
                Bytes = $f.Bytes; Note = 'DISM does not report exact reclaim - predicted bytes shown'
            })
        } catch {
            $errors.Add([pscustomobject]@{
                Category = $f.Category; Title = $f.Title; Path = $pathLabel; Reason = $_.Exception.Message
            })
        }
    }

    $driveDelta = @{}
    if (-not $DryRun) {
        foreach ($dl in $driveLetters) {
            try {
                $afterFree = (Get-PSDrive -Name $dl -ErrorAction Stop).Free
                if ($driveBefore.ContainsKey($dl)) {
                    $driveDelta[$dl] = [long]($afterFree - $driveBefore[$dl])
                }
            } catch { }
        }
    }

    return @{
        Predicted             = [long]$predicted
        ActualPathBytes        = [long]$actualPathBytes
        ActualDriveDeltaBytes  = $driveDelta
        Cleaned                = $cleaned.ToArray()
        Skipped                = $skipped.ToArray()
        Blocked                = $blocked.ToArray()
        Errors                 = $errors.ToArray()
    }
}

function Export-FindingsCsv {
    <# Flattens findings (Paths joined) to a CSV for the GUI's export button. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject[]]$Findings,
        [Parameter(Mandatory)][string]$Path
    )
    $rows = foreach ($f in $Findings) {
        [pscustomobject]@{
            Category    = $f.Category
            Title       = $f.Title
            Risk        = $f.Risk
            Action      = $f.Action
            Bytes       = [long]$f.Bytes
            Size        = Format-Size -Bytes ([long]$f.Bytes)
            Count       = $f.Count
            Selected    = $f.Selected
            Paths       = ($f.Paths -join '; ')
            Detail      = $f.Detail
            Consequence = $f.Consequence
        }
    }
    $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

Export-ModuleMember -Function Invoke-Clean, Export-FindingsCsv
