# Drive Janitor â€” shared contract. Every scanner and the cleaner depend on this module.
# Nothing here may be changed by a feature slice without the whole tool being re-verified.

Set-StrictMode -Version Latest

$script:ToolRoot = Split-Path -Parent $PSScriptRoot

# Paths that must never be emptied or deleted, whatever a scanner claims.
# Order matters only for readability; every rule is checked.
$script:ProtectedExact = @(
    'C:\', 'D:\', 'C:\Users', "$env:USERPROFILE"
)

# Protected at OR BELOW these. Exact-string matching left every subdirectory reachable -
# "C:\Program Files" was protected while "C:\Program Files\App\bin" was not.
$script:ProtectedTrees = @(
    'C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
    "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Pictures",
    "$env:USERPROFILE\Videos", "$env:USERPROFILE\Music", "$env:USERPROFILE\Favorites",
    "$env:USERPROFILE\Contacts", "$env:USERPROFILE\Links", "$env:USERPROFILE\Searches",
    "$env:USERPROFILE\Saved Games", "$env:USERPROFILE\OneDrive",
    "$env:USERPROFILE\Downloads"   # reported so you can see what's big, NEVER deletable by this tool
)

# Narrow carve-outs that win over ProtectedTrees - genuinely disposable spots inside them.
$script:AllowedExceptions = @(
    'C:\Windows\Temp',
    'C:\Windows\SoftwareDistribution\Download',
    'C:\Windows\Prefetch'
)

# Blocked whether they appear as the target or as any ancestor.
$script:ProtectedPatterns = @(
    '\\\.git($|\\)',                       # git metadata - deleting this destroys history
    '\\\.gradle\\caches\\modules-2($|\\)', # downloaded dependency jars - costs a full re-download
    '\\(pagefile|hiberfil|swapfile)\.sys$',
    '\\System Volume Information($|\\)',
    '\\\$Recycle\.Bin\\S-',                # per-SID bins: use the Clear-RecycleBin API, not raw delete
    '\\Android\\Sdk($|\\)'                 # installed SDK/NDK tooling. ndk\<ver>\build IS the
                                           # ndk-build toolchain, not build output - 469 KB, and
                                           # deleting it breaks every native Android build.
)

# Blocked as an ancestor. 'styles' was here but is a submodule name in pygments/openpyxl/docx, so
# it was blocking legitimate styles\__pycache__ cleans on any box with pip installed. Leaf-only now.
$script:SourceAncestors = @('src','components','hooks','pages')

# Legacy OS junctions that resolve into protected trees. GetFullPath does NOT follow reparse
# points, so "C:\Documents and Settings\me" reaches the real profile while reading as unprotected.
$script:LegacyAliases = @{
    'c:\documents and settings' = 'C:\Users'
    'c:\users\all users'        = 'C:\ProgramData'
}

# Ambiguous names: 'app' and 'lib' are Gradle module dirs (android\app\build is the biggest
# reclaim target there is), so these are only protected when they ARE the delete target.
$script:SourceLeaves = @('src','components','hooks','pages','styles','app','lib','assets','public','utils')

function Resolve-JanitorPath {
    <# Canonical form for matching. Windows strips trailing spaces/dots when it resolves a path,
       so "C:\Windows\System32 " reaches the real System32 - match the resolved form, never the
       literal string. Returns $null for anything we refuse to reason about. #>
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()

    if ($p -like '\\*') { return $null }                    # UNC - out of scope, fail closed
    if ($p -match '^[A-Za-z]:\\.*:') { return $null }       # alternate data stream
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }       # not an absolute local path

    try { $p = [IO.Path]::GetFullPath($p) } catch { return $null }   # resolves .. and .

    # Rewrite legacy junction aliases to their real targets BEFORE matching, then re-resolve any
    # reparse point in the leading segments so the guard sees the true destination.
    foreach ($alias in $script:LegacyAliases.Keys) {
        if ($p.ToLower() -eq $alias -or $p.ToLower().StartsWith($alias + '\')) {
            $p = $script:LegacyAliases[$alias] + $p.Substring($alias.Length)
            break
        }
    }
    try {
        $probe = $p
        while ($probe -match '\\' -and $probe.Length -gt 3) {
            if (Test-Path -LiteralPath $probe) {
                $item = Get-Item -LiteralPath $probe -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $tgt = $item.Target
                    if ($tgt) {
                        if ($tgt -is [array]) { $tgt = $tgt[0] }
                        $p = $tgt.TrimEnd('\') + $p.Substring($probe.Length)
                    }
                }
                break
            }
            $probe = Split-Path -Parent $probe
        }
    } catch { return $null }   # unreadable: fail closed, callers treat null as protected

    $drive = $p.Substring(0, 3)
    $rest  = $p.Substring(3)
    $segs = @()
    foreach ($s in ($rest -split '\\')) {
        if ($s -eq '') { continue }
        if ($s -match '^.{1,6}~\d+$') { return $null }      # 8.3 short name - refuse, fail closed
        $segs += $s.TrimEnd(' ', '.')                       # what the OS does on resolution
    }
    if ($segs.Count -eq 0) { return $drive }
    return ($drive + ($segs -join '\'))
}

function Test-PathProtected {
    <# Returns $true if the path must never be emptied or deleted. Fail-closed on any error. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    try {
        $p = Resolve-JanitorPath -Path $Path
        if ($null -eq $p) { return $true }
        $p = $p.TrimEnd('\')
        if ($p -notmatch '^[A-Za-z]:\\') { return $true }

        # Carve-outs are checked first so they can win over the trees below.
        foreach ($ok in $script:AllowedExceptions) {
            $o = $ok.TrimEnd('\')
            if ($p -ieq $o -or $p.ToLower().StartsWith($o.ToLower() + '\')) { return $false }
        }
        foreach ($x in $script:ProtectedExact) {
            if ($p -ieq $x.TrimEnd('\')) { return $true }
        }
        foreach ($t in $script:ProtectedTrees) {
            $tt = $t.TrimEnd('\')
            if ($p -ieq $tt -or $p.ToLower().StartsWith($tt.ToLower() + '\')) { return $true }
        }
        foreach ($rx in $script:ProtectedPatterns) {
            if ($p -imatch $rx) { return $true }
        }

        # Refuse anything shallower than <drive>\a\b - guards against a bug nuking a drive root.
        $segments = @(($p -split '\\') | Where-Object { $_ -ne '' })
        if ($segments.Count -lt 3) { return $true }

        $leaf = $segments[-1]
        if ($script:SourceLeaves -contains $leaf.ToLower()) { return $true }
        foreach ($seg in $segments[1..($segments.Count-2)]) {
            if ($script:SourceAncestors -contains $seg.ToLower()) { return $true }
        }

        # Never clean the tool's own directory.
        if ($p -ilike "$($script:ToolRoot)*") { return $true }

        return $false
    } catch {
        return $true
    }
}

function Test-JanitorPathExists {
    <# Test-Path reports >260-char paths as non-existent when LongPathsEnabled=0, which made
       Invoke-Clean silently no-op and log "path no longer exists" for files that were right there. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if ([IO.Directory]::Exists($Path) -or [IO.File]::Exists($Path)) { return $true }
        $pfx = if ($Path.StartsWith('\\?\')) { $Path } else { "\\?\$Path" }
        return ([IO.Directory]::Exists($pfx) -or [IO.File]::Exists($pfx))
    } catch { return $false }
}

function Test-PathReparsePoint {
    <# Junction/symlink detection. Fail-closed: an unreadable path is treated as a reparse point. #>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $i = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($i.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } catch {
        # Long path: Get-Item can't see it, so read the attributes through the \\?\ form instead
        # of failing closed - failing closed here would block every deep clean.
        try {
            $pfx = if ($Path.StartsWith('\\?\')) { $Path } else { "\\?\$Path" }
            $a = [IO.File]::GetAttributes($pfx)
            return [bool]($a -band [IO.FileAttributes]::ReparsePoint)
        } catch { return $true }
    }
}

function Remove-NestedReparsePoints {
    <# Deletes only the link entries inside a tree, deepest-first. Directory.Delete($p,$false)
       removes the reparse point itself and can never recurse into its target. #>
    param([Parameter(Mandatory)][string]$Path)
    $n = 0
    try {
        $links = Get-ChildItem -LiteralPath $Path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
                 Sort-Object { $_.FullName.Length } -Descending
        foreach ($l in $links) {
            try { [IO.Directory]::Delete($l.FullName, $false); $n++ }
            catch { Write-JanitorLog -Level 'ERROR' -Message "could not unlink $($l.FullName): $_" }
        }
    } catch { }
    return $n
}

function New-Finding {
    <# The one object shape every scanner emits and the GUI/cleaner consume. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][long]$Bytes,
        [int]$Count = 1,
        [ValidateSet('Safe','Moderate','Advanced')][string]$Risk = 'Safe',
        [ValidateSet('Empty','Delete','RecycleBin','Dism','Report')][string]$Action = 'Empty',
        [string]$Detail = '',
        [string]$Consequence = ''
    )
    [pscustomobject]@{
        Category    = $Category
        Title       = $Title
        Paths       = @($Paths)
        Bytes       = $Bytes
        Count       = $Count
        Risk        = $Risk
        Action      = $Action
        Detail      = $Detail
        Consequence = $Consequence   # plain-English "what breaks if I delete this"
        Selected    = ($Risk -eq 'Safe')
    }
}

function Format-Size {
    param([Parameter(Mandatory)][long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes/1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes/1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes/1MB) }
    if ($Bytes -ge 1KB) { return "{0:N0} KB" -f ($Bytes/1KB) }
    "$Bytes B"
}

function Get-DirSize {
    <# Sizes via robocopy /L because Get-ChildItem -Recurse silently returns 0 for paths over
       260 chars when LongPathsEnabled=0 - which is exactly the deep CMake/Gradle output that
       dominates these drives. Measured: 1 MB reported vs 6 MB actual on a 460-char tree. #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-JanitorPathExists -Path $Path)) { return [long]0 }

    # Fast pass first. Get-ChildItem drops >260-char paths SILENTLY (no catchable error), so
    # instead of trying to detect the failure, watch how close we get to the limit: a tree holding
    # a 240-char path almost certainly holds longer ones that were dropped. Only those pay for
    # robocopy. Spawning robocopy for all ~1900 dirs a scan sizes costs ~2 min of pure overhead.
    $total = [long]0
    $maxLen = 0
    $needsLongPathPass = $false
    try {
        # One pass over files AND directories. The length check must include directories:
        # Get-ChildItem stops descending AT the over-long directory, so when content is dropped
        # every file path it did return is short, and only the directory paths reveal how deep
        # the tree really goes. A junction anywhere also forces the robocopy pass, because
        # -Recurse follows them and would count the target's bytes as if they lived here.
        foreach ($e in (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { $needsLongPathPass = $true; break }
            if ($e.FullName.Length -gt $maxLen) { $maxLen = $e.FullName.Length }
            if (-not $e.PSIsContainer) { $total += $e.Length }
        }
        # 200 leaves headroom: a directory this deep can hold children past the 260 limit.
        if ($maxLen -ge 200) { $needsLongPathPass = $true }
    } catch { $needsLongPathPass = $true }

    if (-not $needsLongPathPass) { return [long]$total }

    # Deep tree: robocopy /L speaks the long-path API. /XJ keeps junctions from counting twice.
    try {
        $out = & robocopy $Path "$Path\__janitor_sizing_dest__" /L /S /NJH /BYTES /XJ /R:0 /W:0 2>$null
        foreach ($line in $out) {
            # "Bytes : <total> <copied> <skipped> ..." - first column is the total.
            if ($line -match '^\s*Bytes\s*:\s+(\d+)') { return [long]$matches[1] }
        }
    } catch { }
    return [long]$total
}

function Get-EmptyStagingDir {
    <# robocopy needs a real empty source dir to mirror from. #>
    $d = Join-Path $env:TEMP 'drive-janitor-empty'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    return $d
}

function Clear-PathContents {
    <# Empties a directory via robocopy mirror - the only method that survives >260-char paths.
       Returns bytes reclaimed. Honours -WhatIf. #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$Path, [switch]$AlsoRemoveDir)

    if (Test-PathProtected -Path $Path) {
        Write-JanitorLog -Level 'BLOCK' -Message "protected, refused: $Path"
        return [long]0
    }
    if (-not (Test-JanitorPathExists -Path $Path)) { return [long]0 }

    # Mirroring ONTO a junction would empty whatever it points at, which may be outside the tree.
    if (Test-PathReparsePoint -Path $Path) {
        Write-JanitorLog -Level 'BLOCK' -Message "reparse point, refused: $Path"
        return [long]0
    }

    $before = Get-DirSize -Path $Path
    if (-not $PSCmdlet.ShouldProcess($Path, "empty ($(Format-Size $before))")) { return [long]0 }

    # /MIR purges THROUGH nested junctions and destroys their targets anywhere on disk - /XJ does
    # not stop it (both verified destructive in a sandbox, 2026-08-24). Unlink first, then mirror.
    $links = Remove-NestedReparsePoints -Path $Path

    $empty = Get-EmptyStagingDir
    & robocopy $empty $Path /MIR /XJ /NFL /NDL /NJH /NJS /R:0 /W:0 | Out-Null
    if ($AlsoRemoveDir) { & cmd /c rd /s /q "$Path" 2>$null }
    if ($links) { Write-JanitorLog -Level 'SKIP' -Message "unlinked $links junction(s) under $Path before mirror" }

    $after = if (Test-JanitorPathExists -Path $Path) { Get-DirSize -Path $Path } else { [long]0 }
    $freed = $before - $after
    Write-JanitorLog -Level 'CLEAN' -Message "$Path freed=$(Format-Size $freed)"
    return [long]$freed
}

function Write-JanitorLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','CLEAN','BLOCK','SKIP','ERROR')][string]$Level = 'INFO'
    )
    try {
        $dir = Join-Path $script:ToolRoot 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $f = Join-Path $dir ("run-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        "{0} [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message | Add-Content -LiteralPath $f -Encoding utf8
    } catch { }
}

Export-ModuleMember -Function Test-PathProtected, Test-PathReparsePoint, Test-JanitorPathExists,
                              Resolve-JanitorPath, New-Finding, Format-Size, Get-DirSize,
                              Clear-PathContents, Write-JanitorLog, Get-EmptyStagingDir

