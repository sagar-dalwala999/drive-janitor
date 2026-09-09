# S3: node_modules reaper + stale/duplicate project finder. Owns this file only. Pure read-only.
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Core.psm1') -ErrorAction Stop

$script:StaleDaysThreshold = 90
$script:MaxDupSharedPaths  = 50
$script:MaxDupIndexFiles   = 4000   # cap per-side file index so the "cheap" comparison stays cheap
$script:MaxDupGroupSize    = 400    # sanity ceiling only, not the real guard (see MaxDupSizeRatio below).
                                    # A hard "skip the whole group above N" cap (was 20, then 60) turned
                                    # out to silently drop the named D:\A/D:\Pulse acceptance pair on a
                                    # real full C:\+D:\ scan: "workspace|0.0.0" is a common monorepo
                                    # placeholder name/version and no fixed count is safe to guess for an
                                    # arbitrary machine. The real guard is now MaxDupSizeRatio.
$script:MaxDupSizeRatio    = 5      # within a name+version group, only compare dirs whose measured
                                    # sizes are within this ratio of each other. Sorted-by-size with an
                                    # early break turns the O(n^2) all-pairs cost into O(n log n + n*k)
                                    # for realistic data (D:\A=342MB vs D:\Pulse=435MB is a 1.27x ratio -
                                    # comfortably caught): wildly different-sized dirs sharing a generic
                                    # placeholder name (e.g. one real project vs a near-empty scaffold)
                                    # are cheaply skipped without ever running the expensive per-pair
                                    # file-hash comparison on them.
$script:MaxTotalDupComparisons = 5000   # scan-wide ceiling across ALL groups combined - backstop only
$script:MaxHashBytes       = 1MB
$script:LongPathThreshold  = 240
$script:SkipDescendNames   = @{ 'node_modules' = 1; '.git' = 1; '$RECYCLE.BIN' = 1; 'System Volume Information' = 1 }
# These four Windows system trees can never legitimately contain a project (Test-PathProtected
# already refuses them unconditionally) - pruning them here avoids the full enumeration cost of
# hundreds of thousands of OS directories on a default C:\+D:\ scan for zero possible payoff.
$script:ExcludedSystemTrees = @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')

function Test-ExcludedSystemTree {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.TrimEnd('\')
    foreach ($ex in $script:ExcludedSystemTrees) { if ($p -ieq $ex) { return $true } }
    return $false
}

function ConvertTo-IoPath {
    # \\?\ prefix bypasses the 260-char MAX_PATH limit in .NET Framework's Win32 layer.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.Length -ge $script:LongPathThreshold -and -not $Path.StartsWith('\\?\')) { return "\\?\$Path" }
    return $Path
}

function ConvertFrom-IoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Get-JsonProp {
    # Root cause of the real "duplicate finder failed: property 'Name' cannot be found" crash:
    # `.PSObject.Properties.Name -contains $x` throws under StrictMode when Properties is EMPTY
    # (e.g. ConvertFrom-Json '{}' - a bare/template package.json, common system-wide) because the
    # ETS collection->member enumeration has nothing to enumerate and falls back to a literal
    # lookup that doesn't exist. The indexer form never has this failure mode - verified against
    # {}, a populated object, and a top-level JSON array.
    param($Obj, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Obj) { return $null }
    try {
        $prop = $Obj.PSObject.Properties[$Name]
        if ($null -ne $prop) { return $prop.Value }
    } catch { }
    return $null
}

function Test-IsReparse {
    param([Parameter(Mandatory)][string]$IoPath)
    try { return [bool]([IO.File]::GetAttributes($IoPath) -band [IO.FileAttributes]::ReparsePoint) }
    catch { return $true }   # unreadable - fail closed, treat as a link so we never follow it
}

function Measure-TreeNoReparse {
    <# Sums bytes+files under a directory without ever descending into a reparse point.
       This is the ONLY correct way to size a pnpm node_modules tree - junctions inside it
       point at content already reachable via the real .pnpm store dirs (double-count risk)
       or, as seen in D:\projects\seo-platform\node_modules\web, straight out of the tree
       entirely into live source. #>
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{ Bytes = [long]0; FileCount = 0 }
    $rootIo = ConvertTo-IoPath $Path
    if (Test-IsReparse -IoPath $rootIo) { return $result }   # the target itself is a link - refuse, matches Clear-PathContents

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootIo)
    $bytes = [long]0
    $files = 0

    while ($stack.Count -gt 0) {
        $io = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($io)) {
                try { $bytes += (New-Object IO.FileInfo($f)).Length; $files++ } catch { }
            }
        } catch { }
        try {
            foreach ($d in [IO.Directory]::EnumerateDirectories($io)) {
                if (Test-IsReparse -IoPath $d) { continue }   # never follow - see doc comment above
                $stack.Push($d)
            }
        } catch { }
    }

    $result.Bytes = [long]$bytes
    $result.FileCount = $files
    return $result
}

function Get-ProjectAgeDays {
    <# Days since the PROJECT was touched - package.json/src mtime, never node_modules' own
       (which changes on every install). Falls back to the newest non-node_modules/.git entry. #>
    param([Parameter(Mandatory)][string]$ProjectDir)

    $times = New-Object System.Collections.Generic.List[datetime]

    try {
        $pkg = Join-Path $ProjectDir 'package.json'
        if (Test-Path -LiteralPath $pkg) { $times.Add((Get-Item -LiteralPath $pkg -Force).LastWriteTimeUtc) }
    } catch { }
    try {
        $src = Join-Path $ProjectDir 'src'
        if (Test-Path -LiteralPath $src) { $times.Add((Get-Item -LiteralPath $src -Force).LastWriteTimeUtc) }
    } catch { }

    if ($times.Count -eq 0) {
        try {
            $newest = Get-ChildItem -LiteralPath $ProjectDir -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -ne 'node_modules' -and $_.Name -ne '.git' } |
                      Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            if ($newest) { $times.Add($newest.LastWriteTimeUtc) }
        } catch { }
    }
    if ($times.Count -eq 0) {
        try { $times.Add((Get-Item -LiteralPath $ProjectDir -Force).LastWriteTimeUtc) } catch { $times.Add((Get-Date).ToUniversalTime()) }
    }

    $last = $times | Sort-Object -Descending | Select-Object -First 1
    $days = [Math]::Floor(((Get-Date).ToUniversalTime() - $last).TotalDays)
    return [int]([Math]::Max(0, $days))
}

function Test-HasGitRemote {
    param([Parameter(Mandatory)][string]$ProjectDir)
    try {
        $cfg = Join-Path $ProjectDir '.git\config'
        if (-not (Test-Path -LiteralPath $cfg)) { return $false }
        $content = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop
        return [bool]($content -match '(?im)^\s*\[remote\s+"')
    } catch { return $false }
}

function Get-RestoreCommand {
    <# Exact restore command inferred from whichever lockfile is present. #>
    param([Parameter(Mandatory)][string]$ProjectDir)
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'package-lock.json')) { return 'npm ci' }
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'pnpm-lock.yaml'))   { return 'pnpm i' }
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'yarn.lock'))       { return 'yarn' }
    if (Test-Path -LiteralPath (Join-Path $ProjectDir 'bun.lockb'))       { return 'bun install' }
    return 'npm install'   # no lockfile found - best-effort fallback
}

function Find-ProjectTree {
    <# Single pruned walk of -Roots: never follows a reparse point, never descends into
       node_modules (so every node_modules found is inherently top-level - it can't be
       nested, since we never go looking for one inside another). Collects project-dir
       markers (package.json / .git) and node_modules hits in the same pass. #>
    param([Parameter(Mandatory)][string[]]$Roots)

    $projectDirs = New-Object System.Collections.Generic.List[object]
    $nodeModulesHits = New-Object System.Collections.Generic.List[object]

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $rootNorm = $root
        try { $rootNorm = [IO.Path]::GetFullPath($root) } catch { }
        if (-not (Test-Path -LiteralPath $rootNorm)) { continue }

        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($rootNorm)

        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            if (Test-ExcludedSystemTree -Path $dir) { continue }   # never descend into Windows/Program Files*/ProgramData
            $io = ConvertTo-IoPath $dir

            $hasPkgJson = $false
            $hasGit = $false
            $hasNodeModules = $false
            $nmIsReparse = $false
            $children = New-Object System.Collections.Generic.List[string]

            try {
                # Single EnumerateFileSystemInfos pass returns files+dirs WITH Attributes already
                # populated by the same underlying directory read. Replaces two separate per-node
                # stats this walk used to pay on every directory visited system-wide: the
                # [IO.File]::Exists(package.json) check and the [IO.File]::GetAttributes reparse
                # check per child - the extra stat that made this walk ~5x slower than BuildCache's
                # Get-ChildItem-based walk (which gets attributes for free from one enumeration too).
                foreach ($entry in [IO.DirectoryInfo]::new($io).EnumerateFileSystemInfos()) {
                    if (-not ($entry.Attributes -band [IO.FileAttributes]::Directory)) {
                        if ($entry.Name -ieq 'package.json') { $hasPkgJson = $true }
                        continue
                    }
                    $name = $entry.Name
                    if ($name -ieq 'node_modules') {
                        $hasNodeModules = $true
                        $nmIsReparse = [bool]($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)
                        continue   # never descend - prune here
                    }
                    if ($name -ieq '.git') { $hasGit = $true; continue }
                    if ($script:SkipDescendNames.ContainsKey($name)) { continue }
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }   # never follow junctions/symlinks
                    $children.Add((ConvertFrom-IoPath $entry.FullName))
                }
            } catch { continue }   # unreadable dir - skip subtree, never throw

            if ($hasPkgJson -or $hasGit) {
                $projectDirs.Add([pscustomobject]@{ Path = $dir; HasPackageJson = $hasPkgJson; HasGit = $hasGit })
            }
            if ($hasNodeModules -and -not $nmIsReparse) {
                # a reparse-point node_modules would be refused by Clear-PathContents anyway (frees 0) - don't report it
                $nodeModulesHits.Add([pscustomobject]@{ ProjectDir = $dir; NodeModulesPath = (Join-Path $dir 'node_modules') })
            }

            foreach ($c in $children) { $stack.Push($c) }
        }
    }

    [pscustomobject]@{ ProjectDirs = $projectDirs; NodeModulesHits = $nodeModulesHits }
}

function Get-BoundedRelativeFiles {
    <# Bounded breadth so the duplicate comparison stays "cheap" regardless of tree size -
       stops indexing once MaxFiles is hit rather than enumerating everything. #>
    param([Parameter(Mandatory)][string]$RootDir, [int]$MaxFiles = $script:MaxDupIndexFiles)

    $result = New-Object System.Collections.Generic.List[string]
    $rootLen = $RootDir.TrimEnd('\').Length
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($RootDir)

    while ($stack.Count -gt 0 -and $result.Count -lt $MaxFiles) {
        $dir = $stack.Pop()
        $io = ConvertTo-IoPath $dir
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($io)) {
                $fn = ConvertFrom-IoPath $f
                if ($fn.Length -gt $rootLen) { $result.Add($fn.Substring($rootLen).TrimStart('\')) }
                if ($result.Count -ge $MaxFiles) { break }
            }
        } catch { }
        if ($result.Count -ge $MaxFiles) { break }
        try {
            foreach ($d in [IO.Directory]::EnumerateDirectories($io)) {
                $dNorm = ConvertFrom-IoPath $d
                $name = [IO.Path]::GetFileName($dNorm.TrimEnd('\'))
                if ($name -ieq 'node_modules' -or $name -ieq '.git') { continue }
                if (Test-IsReparse -IoPath $d) { continue }
                $stack.Push($dNorm)
            }
        } catch { }
    }
    return $result
}

function Get-SampleHash {
    # Cheap-by-design: hashes only the first MaxHashBytes, not the whole file.
    param([Parameter(Mandatory)][string]$Path, [int]$MaxBytes = $script:MaxHashBytes)
    $md5 = $null
    $fs = $null
    try {
        $fs = [IO.File]::OpenRead((ConvertTo-IoPath $Path))
        $len = [Math]::Min($fs.Length, $MaxBytes)
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $fs.Read($buf, $read, $len - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $md5 = [System.Security.Cryptography.MD5]::Create()
        return [Convert]::ToBase64String($md5.ComputeHash($buf, 0, $read))
    } catch { return $null }
    finally { if ($fs) { $fs.Dispose() }; if ($md5) { $md5.Dispose() } }
}

function Compare-ProjectPair {
    <# Cheap comparison: index Dir1's relative paths (bounded), walk Dir2 looking for
       overlap, stop at MaxDupSharedPaths shared hits, then length-check + sample-hash
       each shared path. Returns the evidence, never a delete recommendation. #>
    param([Parameter(Mandatory)][string]$Dir1, [Parameter(Mandatory)][string]$Dir2)

    $index1 = @{}
    foreach ($f in (Get-BoundedRelativeFiles -RootDir $Dir1)) { $index1[$f.ToLowerInvariant()] = $f }

    $shared = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-BoundedRelativeFiles -RootDir $Dir2)) {
        $key = $f.ToLowerInvariant()
        if ($index1.ContainsKey($key)) {
            $shared.Add($index1[$key])
            if ($shared.Count -ge $script:MaxDupSharedPaths) { break }
        }
    }

    $matchCount = 0
    $differing = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $shared) {
        $p1 = Join-Path $Dir1 $rel
        $p2 = Join-Path $Dir2 $rel
        $same = $false
        try {
            $fi1 = New-Object IO.FileInfo((ConvertTo-IoPath $p1))
            $fi2 = New-Object IO.FileInfo((ConvertTo-IoPath $p2))
            if ($fi1.Exists -and $fi2.Exists -and $fi1.Length -eq $fi2.Length) {
                $h1 = Get-SampleHash -Path $p1
                $h2 = Get-SampleHash -Path $p2
                if ($null -ne $h1 -and $h1 -eq $h2) { $same = $true }
            }
        } catch { }
        if ($same) { $matchCount++ } else { $differing.Add($rel) }
    }

    $pct = if ($shared.Count -gt 0) { [Math]::Round(($matchCount / $shared.Count) * 100, 1) } else { 0.0 }
    [pscustomobject]@{ SharedCount = $shared.Count; MatchCount = $matchCount; PercentSame = $pct; DifferingPaths = $differing }
}

function Invoke-ProjectScan {
    <# S3: node_modules reaper + stale project finder + duplicate project finder.
       Pure read-only - no deletion, no writes. Returns [pscustomobject[]] of findings. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Roots,
        # Off by default: duplicate detection is ~60% of a full scan's runtime (177 pairs x ~50
        # sample hashes) and its output is report-only, so a routine cleanup never needs it.
        [switch]$IncludeDuplicates
    )

    Write-JanitorLog -Level 'INFO' -Message "Invoke-ProjectScan starting: roots=$($Roots -join ', '), duplicates=$($IncludeDuplicates.IsPresent)"
    $findings = @()

    $tree = $null
    try { $tree = Find-ProjectTree -Roots $Roots }
    catch { Write-JanitorLog -Level 'ERROR' -Message "Find-ProjectTree failed: $_" }
    if ($null -eq $tree) {
        Write-JanitorLog -Level 'ERROR' -Message 'Invoke-ProjectScan: tree walk produced nothing, returning empty'
        return @()
    }
    $projectDirs = $tree.ProjectDirs
    $nodeModulesHits = $tree.NodeModulesHits

    # --- 1. node_modules reaper ---
    $nmRaw = New-Object System.Collections.Generic.List[object]
    foreach ($hit in $nodeModulesHits) {
        try {
            if (Test-PathProtected -Path $hit.NodeModulesPath) { continue }
            $age = Get-ProjectAgeDays -ProjectDir $hit.ProjectDir
            $m = Measure-TreeNoReparse -Path $hit.NodeModulesPath
            if ($m.Bytes -le 0 -and $m.FileCount -eq 0) { continue }   # nothing measurable - skip rather than report a false zero
            $cmd = Get-RestoreCommand -ProjectDir $hit.ProjectDir
            $nmRaw.Add([pscustomobject]@{
                ProjectDir = $hit.ProjectDir; NodeModulesPath = $hit.NodeModulesPath
                AgeDays = $age; Bytes = $m.Bytes; FileCount = $m.FileCount; RestoreCmd = $cmd
            })
        } catch { Write-JanitorLog -Level 'ERROR' -Message "node_modules measure failed for $($hit.NodeModulesPath): $_" }
    }
    foreach ($n in ($nmRaw | Sort-Object AgeDays -Descending)) {   # rank by age - oldest/most idle first
        $findings += New-Finding -Category 'Projects: node_modules' `
            -Title "node_modules: $(Split-Path $n.ProjectDir -Leaf) (idle $($n.AgeDays)d)" `
            -Paths @($n.NodeModulesPath) -Bytes $n.Bytes -Count $n.FileCount -Risk Moderate -Action Delete `
            -Detail "Project ($($n.ProjectDir)) last touched $($n.AgeDays)d ago via package.json/src mtime. $($n.FileCount) files under node_modules." `
            -Consequence "Regenerate with: $($n.RestoreCmd) (re-downloads all dependencies)."
    }

    # --- 2. Stale project finder (report-only) ---
    $staleRaw = New-Object System.Collections.Generic.List[object]
    foreach ($pd in $projectDirs) {
        try {
            if (Test-PathProtected -Path $pd.Path) { continue }
            $hasRemote = if ($pd.HasGit) { Test-HasGitRemote -ProjectDir $pd.Path } else { $false }
            if ($hasRemote) { continue }
            $age = Get-ProjectAgeDays -ProjectDir $pd.Path
            if ($age -lt $script:StaleDaysThreshold) { continue }
            $staleRaw.Add([pscustomobject]@{ Path = $pd.Path; AgeDays = $age; HasGit = $pd.HasGit })
        } catch { Write-JanitorLog -Level 'ERROR' -Message "stale check failed for $($pd.Path): $_" }
    }
    foreach ($s in ($staleRaw | Sort-Object AgeDays -Descending)) {
        try {
            $m = Measure-TreeNoReparse -Path $s.Path
            $reason = if ($s.HasGit) { 'git repo with no remote configured' } else { 'not a git repository' }
            $findings += New-Finding -Category 'Projects: Stale' `
                -Title "Stale project: $(Split-Path $s.Path -Leaf)" `
                -Paths @($s.Path) -Bytes $m.Bytes -Count $m.FileCount -Risk Advanced -Action Report `
                -Detail "$reason. Last touched $($s.AgeDays)d ago (package.json/src mtime, or newest top-level entry)." `
                -Consequence 'Report only - never auto-cleaned. Investigate before deleting; nothing else may track this work.'
        } catch { Write-JanitorLog -Level 'ERROR' -Message "stale measure failed for $($s.Path): $_" }
    }

    # --- 3. Duplicate project finder (report-only, evidence-based, opt-in) ---
    if (-not $IncludeDuplicates) {
        Write-JanitorLog -Level 'INFO' -Message 'duplicate finder skipped (enable "Find duplicate projects" in Advanced)'
    } else {
    try {
        $pkgGroups = @{}
        foreach ($pd in $projectDirs) {
            if (-not $pd.HasPackageJson) { continue }
            # Whole-body try/catch, not just the parse: package.json content across a system-wide
            # walk is untrusted and shape-varying (bare {}, arrays, nested "name" objects, etc.) -
            # one bad file must skip that one project, never abort the whole duplicate finder.
            try {
                $json = Get-Content -LiteralPath (Join-Path $pd.Path 'package.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $name = [string](Get-JsonProp $json 'name')
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $ver = [string](Get-JsonProp $json 'version')
                $key = "$($name.ToLowerInvariant())|$ver"
                if (-not $pkgGroups.ContainsKey($key)) { $pkgGroups[$key] = New-Object System.Collections.Generic.List[string] }
                $pkgGroups[$key].Add($pd.Path)
            } catch { continue }
        }

        $totalComparisons = 0
        $budgetExhausted = $false
        foreach ($key in $pkgGroups.Keys) {
            if ($budgetExhausted) { break }
            $dirs = $pkgGroups[$key]
            if ($dirs.Count -lt 2 -or $dirs.Count -gt $script:MaxDupGroupSize) { continue }

            # One size measurement per dir (not per pair - the old code re-measured a dir once for
            # every pair it appeared in). Sorting by size lets the ratio check break out of the
            # inner loop the moment sizes diverge too far, since every later $j is even bigger.
            $sized = New-Object System.Collections.Generic.List[object]
            foreach ($d in $dirs) {
                try { $m = Measure-TreeNoReparse -Path $d; $sized.Add([pscustomobject]@{ Path = $d; Bytes = $m.Bytes }) }
                catch { Write-JanitorLog -Level 'ERROR' -Message "duplicate-candidate size failed for $d : $_" }
            }
            $sized = @($sized | Sort-Object Bytes)

            for ($i = 0; $i -lt $sized.Count; $i++) {
                for ($j = $i + 1; $j -lt $sized.Count; $j++) {
                    if ($totalComparisons -ge $script:MaxTotalDupComparisons) {
                        $budgetExhausted = $true
                        Write-JanitorLog -Level 'INFO' -Message "duplicate finder: scan-wide comparison budget ($($script:MaxTotalDupComparisons)) reached, remaining groups skipped"
                        break
                    }
                    $b1 = [Math]::Max(1L, $sized[$i].Bytes); $b2 = [Math]::Max(1L, $sized[$j].Bytes)
                    if (($b2 / $b1) -gt $script:MaxDupSizeRatio) { break }   # sorted ascending - every further $j only diverges more

                    $d1 = $sized[$i].Path; $d2 = $sized[$j].Path
                    if ($d1.StartsWith("$d2\", [StringComparison]::OrdinalIgnoreCase) -or
                        $d2.StartsWith("$d1\", [StringComparison]::OrdinalIgnoreCase)) { continue }   # one nested in the other - not real siblings
                    $totalComparisons++

                    try {
                        $cmp = Compare-ProjectPair -Dir1 $d1 -Dir2 $d2
                        $reclaimable = [Math]::Min($sized[$i].Bytes, $sized[$j].Bytes)
                        $nameVer = $key -replace '\|', ' v'

                        $detail = "package.json match ($nameVer). $($cmp.SharedCount) shared sampled files, $($cmp.MatchCount) identical ($($cmp.PercentSame)%). " +
                                  "$d1 = $(Format-Size $sized[$i].Bytes); $d2 = $(Format-Size $sized[$j].Bytes)."
                        if ($cmp.DifferingPaths.Count -gt 0) {
                            $detail += ' Differs: ' + (($cmp.DifferingPaths | Select-Object -First 10) -join ', ')
                        }

                        $findings += New-Finding -Category 'Projects: Duplicates' `
                            -Title "Possible duplicate project: $(Split-Path $d1 -Leaf) vs $(Split-Path $d2 -Leaf)" `
                            -Paths @($d1, $d2) -Bytes $reclaimable -Count 2 -Risk Advanced -Action Report `
                            -Detail $detail `
                            -Consequence 'Evidence only - user decides which copy (if either) to remove. No delete recommendation.'
                    } catch { Write-JanitorLog -Level 'ERROR' -Message "duplicate compare failed for $d1 vs $d2 : $_" }
                }
                if ($budgetExhausted) { break }
            }
        }
    } catch { Write-JanitorLog -Level 'ERROR' -Message "duplicate finder failed: $_" }
    }

    Write-JanitorLog -Level 'INFO' -Message "Invoke-ProjectScan done: $($findings.Count) findings"
    return [pscustomobject[]]$findings
}

Export-ModuleMember -Function Invoke-ProjectScan
