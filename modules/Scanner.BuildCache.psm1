# S1 scanner - build/package cache finder. Owns this file only. Pure read-only: no deletes.
# Exports exactly one function: Invoke-BuildCacheScan -Roots [string[]] -> [pscustomobject[]]

Set-StrictMode -Version Latest
# No -Force: it evicts an already-global Core into this module's private scope and strips
# Core's functions from every caller (S7's orchestrator, S6's GUI).
Import-Module (Join-Path $PSScriptRoot 'Core.psm1')

function Get-JunctionSafeDirSize {
    <# Was a private Get-ChildItem-based walk that silently returned 0 for any content deeper
       than 260 chars (this machine has LongPathsEnabled=0) - proven live: a correctly-matched
       88-char .cxx folder with a 287-char nested file reported Bytes=0 vs a true 2 MB. Now a
       thin wrapper over Core's Get-DirSize, which is robocopy-based: long-path-safe (no MAX_PATH
       limit) AND junction-safe (/XJ), proven by tests/Sizing.Tests.ps1. Every one of this
       scanner's 7 finding categories sizes through this one function, so fixing it here fixes
       all of them at once. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExcludeLiteral
    )
    $total = Get-DirSize -Path $Path
    if ($ExcludeLiteral -and (Test-Path -LiteralPath $ExcludeLiteral)) {
        $pFull = try { ([IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { $Path.TrimEnd('\') }
        $exFull = try { [IO.Path]::GetFullPath($ExcludeLiteral) } catch { $ExcludeLiteral }
        # only subtract when the excluded path is actually inside $Path - it's counted as part
        # of $Path's own robocopy total otherwise it wouldn't be there to subtract at all.
        if (($exFull.TrimEnd('\') -ieq $pFull) -or $exFull.ToLowerInvariant().StartsWith(($pFull + '\').ToLowerInvariant())) {
            $total -= (Get-DirSize -Path $ExcludeLiteral)
            if ($total -lt 0) { $total = [long]0 }
        }
    }
    return [long]$total
}

# These four Windows system trees can never legitimately hold a build cache (Test-PathProtected
# already refuses them unconditionally) - pruning them here avoids the full enumeration cost of
# hundreds of thousands of OS directories on a default C:\+D:\ scan for zero possible payoff.
$script:ExcludedSystemTrees = @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')

function Test-ExcludedSystemTree {
    param([Parameter(Mandatory)][string]$Path)
    $p = $Path.TrimEnd('\')
    foreach ($ex in $script:ExcludedSystemTrees) { if ($p -ieq $ex) { return $true } }
    return $false
}

function Test-ProjectRootMarker {
    <# Gates the generic dist/build/target match so an unrelated folder named 'build' deep in
       source isn't flagged - require a sibling project file. #>
    param([Parameter(Mandatory)][string]$DirPath)
    $markers = @('package.json','pyproject.toml','setup.py','Cargo.toml','pom.xml','requirements.txt','.git')
    foreach ($m in $markers) {
        if (Test-Path -LiteralPath (Join-Path $DirPath $m)) { return $true }
    }
    return $false
}

function Find-BuildCacheCandidates {
    <# Single directory-only walk (cheap - no file stats) that prunes at every match instead of
       descending further, and never follows a reparse point. Real Android layouts put build/.cxx
       at any depth under android\ (e.g. android\app\build), so 'inside an android\ tree' is
       tracked as ancestor state, not an immediate-parent check. #>
    param([Parameter(Mandatory)][string]$Root)

    $results = @{
        AndroidBuild       = New-Object System.Collections.Generic.List[string]
        GradleVersionCache = New-Object System.Collections.Generic.List[string]
        GradleTransient    = New-Object System.Collections.Generic.List[string]
        WebBuildOutput     = New-Object System.Collections.Generic.List[string]
        PyVenv             = New-Object System.Collections.Generic.List[string]
    }
    if (-not (Test-Path -LiteralPath $Root)) { return $results }

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $Root; InNM = $false; InAndroid = $false })

    while ($stack.Count -gt 0) {
        $f = $stack.Pop()
        $children = $null
        try { $children = Get-ChildItem -LiteralPath $f.Path -Directory -Force -ErrorAction SilentlyContinue } catch { $children = $null }
        if (-not $children) { continue }

        foreach ($c in $children) {
            if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }   # never follow a junction/symlink
            if (Test-ExcludedSystemTree -Path $c.FullName) { continue }               # never descend into Windows/Program Files*/ProgramData

            $lname = $c.Name.ToLowerInvariant()
            $parentDir = $c.Parent
            $parentLower = if ($parentDir) { $parentDir.Name.ToLowerInvariant() } else { '' }
            $grandDir = if ($parentDir) { $parentDir.Parent } else { $null }
            $grandLower = if ($grandDir) { $grandDir.Name.ToLowerInvariant() } else { '' }
            $inNM = $f.InNM -or ($lname -eq 'node_modules')
            $inAndroid = $f.InAndroid -or ($lname -eq 'android')

            $matched = $false

            # R1: android\...\build and android\...\.cxx, anywhere under an android\ tree (incl. inside node_modules).
            if ((-not $matched) -and $f.InAndroid -and ($lname -eq 'build' -or $lname -eq '.cxx')) {
                $results.AndroidBuild.Add($c.FullName); $matched = $true
            }

            # R2: exclude modules-2 (dependency jars) - prune only, never report or descend.
            if ((-not $matched) -and ($lname -eq 'modules-2') -and ($parentLower -eq 'caches') -and ($grandLower -eq '.gradle')) {
                $matched = $true
            }

            # R3: any other direct child of .gradle\caches (version-numbered transform/build caches).
            if ((-not $matched) -and ($parentLower -eq 'caches') -and ($grandLower -eq '.gradle')) {
                $results.GradleVersionCache.Add($c.FullName); $matched = $true
            }

            # R4: .gradle\daemon, .gradle\native, .gradle\wrapper\dists.
            if (-not $matched) {
                if ((($lname -eq 'daemon') -or ($lname -eq 'native')) -and ($parentLower -eq '.gradle')) {
                    $results.GradleTransient.Add($c.FullName); $matched = $true
                } elseif (($lname -eq 'dists') -and ($parentLower -eq 'wrapper') -and ($grandLower -eq '.gradle')) {
                    $results.GradleTransient.Add($c.FullName); $matched = $true
                }
            }

            # R5: python venvs. Name alone is NOT safe here - 'venv' also names the CPython stdlib's
            # own venv-module source folder and Jedi/typeshed stub bundles (found by verification
            # run against this machine: Lib\venv and two extensions' typeshed\...\venv false-positived
            # as Moderate, one of which would have broken `python -m venv` machine-wide). Every real
            # virtualenv created by `python -m venv` has pyvenv.cfg at its root; those never do.
            if ((-not $matched) -and ($lname -eq '.venv' -or $lname -eq 'venv')) {
                if (Test-Path -LiteralPath (Join-Path $c.FullName 'pyvenv.cfg')) {
                    $results.PyVenv.Add($c.FullName); $matched = $true
                }
            }

            # R6: generic web/py/rust build output. Skipped inside node_modules - a package's
            # shipped dist/build folder is real content, not a cache.
            if ((-not $matched) -and (-not $inNM)) {
                if ($lname -in @('.next', '.turbo', '.parcel-cache', '__pycache__')) {
                    $results.WebBuildOutput.Add($c.FullName); $matched = $true
                } elseif (($lname -in @('dist', 'build', 'target')) -and ($parentLower -ne 'android')) {
                    if (Test-ProjectRootMarker -DirPath $parentDir.FullName) {
                        $results.WebBuildOutput.Add($c.FullName); $matched = $true
                    }
                }
            }

            if (-not $matched) {
                $stack.Push([pscustomobject]@{ Path = $c.FullName; InNM = $inNM; InAndroid = $inAndroid })
            }
            # matched => prune, do not descend further
        }
    }
    return $results
}

function Add-CategoryFinding {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string[]]$Paths, [string]$Category, [string]$Title,
        [string]$Risk, [string]$Action, [string]$Detail, [string]$Consequence
    )
    $paths = @($Paths)
    if ($paths.Count -eq 0) { return }
    $bytes = [long]0
    foreach ($p in $paths) { $bytes += Get-JunctionSafeDirSize -Path $p }
    $List.Add((New-Finding -Category $Category -Title $Title -Paths $paths -Bytes $bytes `
                            -Count $paths.Count -Risk $Risk -Action $Action `
                            -Detail $Detail -Consequence $Consequence))
}

function Test-PathUnderAnyRoot {
    param([string]$Path, [string[]]$Roots)
    $full = try { [IO.Path]::GetFullPath($Path) } catch { $null }
    if (-not $full) { return $false }
    $fullLower = $full.ToLowerInvariant()
    foreach ($r in $Roots) {
        $rf = try { [IO.Path]::GetFullPath($r) } catch { $null }
        if (-not $rf) { continue }
        $rfLower = $rf.TrimEnd('\').ToLowerInvariant()
        # boundary-safe prefix check - plain StartsWith would let "C:\Users\VA-007" match a
        # sibling "C:\Users\VA-007-other\..." too.
        if (($fullLower -eq $rfLower) -or $fullLower.StartsWith($rfLower + '\')) { return $true }
    }
    return $false
}

function Get-PackageManagerCacheFindings {
    <# Global download caches live at fixed well-known locations, not "anywhere under roots" -
       checked directly instead of via the tree walk, and scoped to the caller's -Roots. #>
    param([string[]]$Roots)

    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'npm-cache'
        $candidates += Join-Path $env:LOCALAPPDATA 'pnpm\store'
        $candidates += Join-Path $env:LOCALAPPDATA 'Yarn\Cache'
        $candidates += Join-Path $env:LOCALAPPDATA 'pip\Cache'
    }
    if ($env:USERPROFILE) {
        $candidates += Join-Path $env:USERPROFILE '.bun\install\cache'
        $candidates += Join-Path $env:USERPROFILE '.nuget\packages'
    }

    $paths = @()
    foreach ($c in $candidates) {
        if ((Test-Path -LiteralPath $c) -and (Test-PathUnderAnyRoot -Path $c -Roots $Roots)) {
            $paths += [IO.Path]::GetFullPath($c)
        }
    }
    if ($paths.Count -eq 0) { return @() }

    $bytes = [long]0
    foreach ($p in $paths) { $bytes += Get-JunctionSafeDirSize -Path $p }
    return @(New-Finding -Category 'Package Manager Cache' `
        -Title 'Package manager caches (npm, pnpm, Yarn, Bun, NuGet, pip)' `
        -Paths $paths -Bytes $bytes -Count $paths.Count -Risk 'Moderate' -Action 'Empty' `
        -Detail 'Global download caches: npm-cache, pnpm store, Yarn cache, Bun cache, NuGet packages, pip cache.' `
        -Consequence 'Next install re-downloads packages instead of reading the local cache - slower, not broken. The folder itself is kept so tools do not have to recreate it.')
}

function Get-TempDirFindings {
    <# %TEMP% and C:\Windows\Temp, excluding this tool's own robocopy staging dir - deleting that
       out from under an in-progress mirror would break the very operation cleaning it. #>
    param([string[]]$Roots)

    $staging = Get-EmptyStagingDir
    $candidates = @($env:TEMP, 'C:\Windows\Temp') | Where-Object { $_ } | Select-Object -Unique

    $paths = @()
    foreach ($c in $candidates) {
        if ((Test-Path -LiteralPath $c) -and (Test-PathUnderAnyRoot -Path $c -Roots $Roots)) {
            $paths += [IO.Path]::GetFullPath($c)
        }
    }
    if ($paths.Count -eq 0) { return @() }

    $bytes = [long]0
    foreach ($p in $paths) { $bytes += Get-JunctionSafeDirSize -Path $p -ExcludeLiteral $staging }
    return @(New-Finding -Category 'Temp Files' -Title 'Temp files (%TEMP%, C:\Windows\Temp)' `
        -Paths $paths -Bytes $bytes -Count $paths.Count -Risk 'Safe' -Action 'Empty' `
        -Detail 'OS/user scratch space. Excludes this tool''s own staging directory.' `
        -Consequence 'Regenerated on demand by whatever process needs it next. Safe to clear; folder itself is kept.')
}

function Invoke-BuildCacheScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Roots)

    $agg = @{
        AndroidBuild       = New-Object System.Collections.Generic.List[string]
        GradleVersionCache = New-Object System.Collections.Generic.List[string]
        GradleTransient    = New-Object System.Collections.Generic.List[string]
        WebBuildOutput     = New-Object System.Collections.Generic.List[string]
        PyVenv             = New-Object System.Collections.Generic.List[string]
    }

    foreach ($root in $Roots) {
        Write-JanitorLog -Level 'INFO' -Message "BuildCache scan: $root"
        $found = Find-BuildCacheCandidates -Root $root
        foreach ($key in $found.Keys) { $agg[$key].AddRange($found[$key]) }
    }

    $findings = New-Object System.Collections.Generic.List[object]

    Add-CategoryFinding -List $findings -Paths @($agg.AndroidBuild) `
        -Category 'Android Build' -Title 'Android build output (android\build, android\.cxx)' `
        -Risk 'Safe' -Action 'Delete' `
        -Detail 'Gradle/CMake build artifacts anywhere under an android\ tree, including copies vendored inside node_modules.' `
        -Consequence 'Regenerates automatically on the next Gradle/CMake build. No manual step to restore.'

    Add-CategoryFinding -List $findings -Paths @($agg.GradleVersionCache) `
        -Category 'Gradle Cache' -Title 'Gradle version caches (.gradle\caches\<version>)' `
        -Risk 'Safe' -Action 'Delete' `
        -Detail 'Per-Gradle-version transform/build caches under .gradle\caches. modules-2 (dependency jars) is excluded.' `
        -Consequence 'Rebuilt automatically by Gradle on next use. Does not touch downloaded dependency jars.'

    Add-CategoryFinding -List $findings -Paths @($agg.GradleTransient) `
        -Category 'Gradle Cache' -Title 'Gradle daemon / native / wrapper caches' `
        -Risk 'Moderate' -Action 'Delete' `
        -Detail '.gradle\daemon, .gradle\native, and .gradle\wrapper\dists.' `
        -Consequence 'Gradle re-downloads the wrapper distribution and restarts the daemon on next build - costs time and bandwidth, not correctness.'

    Add-CategoryFinding -List $findings -Paths @($agg.WebBuildOutput) `
        -Category 'Build Output' -Title 'Web/Python/Rust build output (.next, dist, build, target, __pycache__, .turbo, .parcel-cache)' `
        -Risk 'Safe' -Action 'Delete' `
        -Detail 'Compiled/bundled output found at a detected project root (package.json/Cargo.toml/pyproject.toml/pom.xml/.git present).' `
        -Consequence 'Regenerates on the next build/run command. No source file is touched.'

    Add-CategoryFinding -List $findings -Paths @($agg.PyVenv) `
        -Category 'Python' -Title 'Python virtualenvs (.venv, venv)' `
        -Risk 'Moderate' -Action 'Delete' `
        -Detail 'Local Python virtual environments.' `
        -Consequence 'Recreated with python -m venv plus a pip install -r requirements.txt re-run - costs a re-download, not data.'

    $findings.AddRange(@(Get-PackageManagerCacheFindings -Roots $Roots))
    $findings.AddRange(@(Get-TempDirFindings -Roots $Roots))

    # @() around a List[object] throws "Argument types do not match" under strict mode (PS5.1
    # PSEnumerableBinder quirk) - ToArray() sidesteps the binder entirely.
    return $findings.ToArray()
}

Export-ModuleMember -Function Invoke-BuildCacheScan
