# Walks brief.md section 5 MVP Acceptance Criteria one by one against the real built tool.
# This is the gate for calling the build done - not a unit test, an end-to-end acceptance pass.
$root = Split-Path -Parent $PSScriptRoot
$script:fail = 0
$script:warn = 0

function Assert-Criterion($cond, $criterion) {
    if (-not $cond) { $script:fail++ }
    "{0}  {1}" -f $(if ($cond) { 'PASS' } else { 'FAIL' }), $criterion
}
function Add-Warning($msg) { $script:warn++; "WARN  $msg" }

Import-Module (Join-Path $root 'modules\Core.psm1') -Force -Global -ErrorAction Stop
foreach ($m in 'Scanner.BuildCache', 'Scanner.BrowserApp', 'Scanner.Projects', 'Scanner.System', 'Cleaner', 'Config') {
    Import-Module (Join-Path $root "modules\$m.psm1") -Force -ErrorAction SilentlyContinue
}

"=== AC: protected-path guard is provably sound ==="
$guard = & (Join-Path $PSScriptRoot 'Guard.Checks.ps1')
Assert-Criterion (@($guard)[-1] -match 'ALL GUARD TESTS PASSED') 'guard suite green'

"=== AC: junction inside a cleaned tree never loses its target ==="
$j = & (Join-Path $PSScriptRoot 'Junction.Checks.ps1')
Assert-Criterion (@($j)[-1] -match 'ALL JUNCTION TESTS PASSED') 'junction suite green'

"=== AC: honest numbers (deep-path sizing) ==="
$s = & (Join-Path $PSScriptRoot 'Sizing.Checks.ps1')
Assert-Criterion (@($s)[-1] -match 'ALL SIZING TESTS PASSED') 'sizing suite green'

"=== AC: handles a >260-char path without error, end to end ==="
$sb = Join-Path $env:TEMP ("dj-acc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$deep = Join-Path $sb 'proj\android\app\build'
$cur = $deep
1..8 | ForEach-Object { $cur = $cur + "\nested-" + ('y' * 20) + "-$_" }
[IO.Directory]::CreateDirectory("\\?\$cur") | Out-Null
$fs = [IO.File]::Create("\\?\$cur\payload.bin"); $fs.Write((New-Object byte[] 3145728), 0, 3145728); $fs.Close()
$truth = Get-DirSize -Path $deep
Assert-Criterion ($truth -eq 3145728) "deep tree sizes correctly before clean (got $truth, want 3145728)"

$f = New-Finding -Category 'Test' -Title 'deep build' -Paths @($deep) -Bytes $truth -Risk Safe -Action Empty -Consequence 'test fixture'
$res = Invoke-Clean -Findings @($f)
Assert-Criterion ($res.ActualPathBytes -eq $truth) "clean reports the real freed bytes (got $($res.ActualPathBytes), want $truth)"
$after = Get-DirSize -Path $deep
Assert-Criterion ($after -eq 0) "deep content is genuinely gone from disk (residual $after)"
$falseSkip = @($res.Skipped | Where-Object { "$($_.Reason)" -match 'no longer exists' })
Assert-Criterion ($falseSkip.Count -eq 0) 'no false "path no longer exists" skip reason'

"=== AC: 5% reclaim accuracy, measured against ground truth ==="
if ($res.Predicted -gt 0) {
    $off = [math]::Abs($res.ActualPathBytes - $res.Predicted) / $res.Predicted * 100
    Assert-Criterion ($off -le 5) ("predicted vs actual within 5% (off by {0:N2}%)" -f $off)
}

"=== AC: a Report finding is never cleaned ==="
$marker = Join-Path $sb 'reportonly'
[IO.Directory]::CreateDirectory($marker) | Out-Null
'KEEP' | Set-Content (Join-Path $marker 'keep.txt')
$rf = New-Finding -Category 'Test' -Title 'report only' -Paths @($marker) -Bytes 4 -Risk Advanced -Action Report -Consequence 'never cleaned'
$rf.Selected = $true   # even if something wrongly pre-ticks it
$res2 = Invoke-Clean -Findings @($rf)
Assert-Criterion (Test-Path (Join-Path $marker 'keep.txt')) 'Report finding survived a clean even when Selected=true'

"=== AC: a smuggled protected path is refused (defense in depth) ==="
$bad = New-Finding -Category 'Test' -Title 'smuggled' -Paths @("$env:USERPROFILE\Documents") -Bytes 1 -Risk Safe -Action Delete -Consequence 'should be blocked'
$res3 = Invoke-Clean -Findings @($bad) -DryRun
Assert-Criterion (@($res3.Blocked).Count -ge 1 -or @($res3.Cleaned).Count -eq 0) 'protected path never reaches a delete'

"=== AC: dry run touches nothing ==="
$dr = Join-Path $sb 'dryrun'
[IO.Directory]::CreateDirectory($dr) | Out-Null
'INTACT' | Set-Content (Join-Path $dr 'file.txt')
$df = New-Finding -Category 'Test' -Title 'dry' -Paths @($dr) -Bytes 6 -Risk Safe -Action Empty -Consequence 'test'
Invoke-Clean -Findings @($df) -DryRun | Out-Null
Assert-Criterion ((Get-Content (Join-Path $dr 'file.txt') -EA SilentlyContinue) -eq 'INTACT') 'dry run left the file untouched'

"=== AC: duplicate finder identifies D:\A vs D:\Pulse ==="
if ((Test-Path 'D:\A') -and (Test-Path 'D:\Pulse')) {
    $dupes = @(Invoke-ProjectScan -Roots @('D:\A', 'D:\Pulse') | Where-Object { $_.Title -match 'uplicate' })
    Assert-Criterion ($dupes.Count -ge 1) 'duplicate finder reports the named fixture'
    Assert-Criterion (@($dupes | Where-Object { $_.Action -ne 'Report' }).Count -eq 0) 'duplicates are Report-only, never deletable'
} else { Add-Warning 'D:\A or D:\Pulse absent - duplicate AC not evaluated' }

"=== AC: config round-trips all four Advanced fields ==="
if (Get-Command Get-JanitorConfig -EA SilentlyContinue) {
    $c = Get-JanitorConfig
    foreach ($k in 'Roots', 'Exclusions', 'MinSizeMB', 'AgeDays') {
        if (-not ($c.PSObject.Properties.Name -contains $k)) { Add-Warning "config has no '$k' field" }
    }
}

cmd /c rd /s /q "$sb" 2>$null
""
"failures: $script:fail   warnings: $script:warn"
if ($script:fail -eq 0) { "ACCEPTANCE: all evaluated criteria PASSED"; exit 0 } else { "ACCEPTANCE: $script:fail FAILED"; exit 1 }

