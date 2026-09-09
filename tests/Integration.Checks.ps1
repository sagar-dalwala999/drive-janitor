# Cross-slice contract test. Every slice is built independently against spec.md, so this is the
# only place the pinned contracts are actually proven to line up.
$root = Split-Path -Parent $PSScriptRoot
$script:fail = 0
$script:skip = 0

function Check($cond, $why) {
    if (-not $cond) { $script:fail++ }
    "{0}  {1}" -f $(if ($cond) { 'PASS' } else { 'FAIL' }), $why
}
function Need($path, $why) {
    if (-not (Test-Path -LiteralPath $path)) { $script:skip++; "SKIP  $why (not built yet)"; return $false }
    return $true
}

Import-Module (Join-Path $root 'modules\Core.psm1') -Force -ErrorAction Stop

"=== scanner contract: one function, correct name, read-only shape ==="
$scanners = @(
    @{ File = 'modules\Scanner.BuildCache.psm1'; Fn = 'Invoke-BuildCacheScan' }
    @{ File = 'modules\Scanner.BrowserApp.psm1'; Fn = 'Invoke-BrowserAppScan' }
    @{ File = 'modules\Scanner.Projects.psm1';   Fn = 'Invoke-ProjectScan' }
    @{ File = 'modules\Scanner.System.psm1';     Fn = 'Invoke-SystemScan' }
)
$allFindings = @()
foreach ($s in $scanners) {
    $full = Join-Path $root $s.File
    if (-not (Need $full $s.Fn)) { continue }
    Import-Module $full -Force
    Check ([bool](Get-Command $s.Fn -EA SilentlyContinue)) "$($s.Fn) is exported"
    $p = (Get-Command $s.Fn).Parameters
    Check ($p.ContainsKey('Roots')) "$($s.Fn) takes -Roots"
    $r = & $s.Fn -Roots @('C:\Users\VA-007', 'D:\')
    $allFindings += @($r)
    Check ($null -ne $r) "$($s.Fn) returned without throwing"
}

if ($allFindings.Count -gt 0) {
    "=== finding shape (New-Finding contract) ==="
    $required = 'Category', 'Title', 'Paths', 'Bytes', 'Count', 'Risk', 'Action', 'Detail', 'Consequence', 'Selected'
    $bad = @($allFindings | Where-Object { $f = $_; @($required | Where-Object { $_ -notin $f.PSObject.Properties.Name }).Count -gt 0 })
    Check ($bad.Count -eq 0) "all $($allFindings.Count) findings carry every required field"
    Check (@($allFindings | Where-Object { $_.Risk -notin 'Safe', 'Moderate', 'Advanced' }).Count -eq 0) 'Risk is always a valid enum value'
    Check (@($allFindings | Where-Object { $_.Action -notin 'Empty', 'Delete', 'RecycleBin', 'Dism', 'Report' }).Count -eq 0) 'Action is always a valid enum value'
    Check (@($allFindings | Where-Object { [string]::IsNullOrWhiteSpace($_.Consequence) }).Count -eq 0) 'every finding explains what breaks if cleaned'

    "=== THE safety invariant: nothing cleanable may trip the guard ==="
    $cleanable = @($allFindings | Where-Object { $_.Action -in 'Empty', 'Delete' })
    $violations = @()
    foreach ($f in $cleanable) { foreach ($pth in $f.Paths) { if (Test-PathProtected $pth) { $violations += "$($f.Title) -> $pth" } } }
    Check ($violations.Count -eq 0) "no cleanable finding targets a protected path ($($cleanable.Count) checked)"
    $violations | Select-Object -First 10 | ForEach-Object { "      VIOLATION: $_" }

    "=== pre-tick discipline ==="
    Check (@($allFindings | Where-Object { $_.Selected -and $_.Risk -ne 'Safe' }).Count -eq 0) 'only Safe findings are pre-ticked'
    Check (@($allFindings | Where-Object { $_.Selected -and $_.Action -eq 'Report' }).Count -eq 0) 'no Report finding is ever pre-ticked'
}

"=== S5 cleaner contract ==="
$cl = Join-Path $root 'modules\Cleaner.psm1'
if (Need $cl 'Invoke-Clean') {
    Import-Module $cl -Force
    Check ([bool](Get-Command Invoke-Clean -EA SilentlyContinue)) 'Invoke-Clean is exported'
    Check ([bool](Get-Command Export-FindingsCsv -EA SilentlyContinue)) 'Export-FindingsCsv is exported'
    $p = (Get-Command Invoke-Clean).Parameters
    Check ($p.ContainsKey('Findings') -and $p.ContainsKey('DryRun')) 'Invoke-Clean takes -Findings and -DryRun'
    # A dry run must be provably inert.
    $probe = New-Finding -Category 'T' -Title 'probe' -Paths @('C:\definitely\not\real\xyz') -Bytes 0 -Action 'Empty'
    $res = Invoke-Clean -Findings @($probe) -DryRun
    foreach ($k in 'Predicted', 'ActualPathBytes', 'ActualDriveDeltaBytes', 'Cleaned', 'Skipped', 'Blocked', 'Errors') {
        Check ($res.ContainsKey($k) -or $null -ne $res.$k) "result carries pinned field '$k'"
    }
}

"=== S7 orchestration contract (what S6 binds to) ==="
$entry = Join-Path $root 'DriveJanitor.ps1'
if (Need $entry 'Invoke-AllScans') {
    Check ((Get-Content $entry -Raw) -match 'function\s+Invoke-AllScans') 'DriveJanitor.ps1 defines Invoke-AllScans'
    Check ((Get-Content $entry -Raw) -match 'ProgressCallback') 'Invoke-AllScans accepts -ProgressCallback'
}

"=== S6 GUI files ==="
foreach ($f in 'ui\MainWindow.xaml', 'ui\Gui.ps1') {
    if (Need (Join-Path $root $f) $f) { Check $true "$f exists" }
}
$xaml = Join-Path $root 'ui\MainWindow.xaml'
if (Test-Path $xaml) {
    try { [xml](Get-Content $xaml -Raw) | Out-Null; Check $true 'MainWindow.xaml is well-formed XML' }
    catch { Check $false "MainWindow.xaml is well-formed XML ($_)" }
}

""
"findings collected: $($allFindings.Count)   failures: $script:fail   not-yet-built: $script:skip"
if ($script:fail -eq 0) { "INTEGRATION: no contract violations"; exit 0 } else { "INTEGRATION: $script:fail FAILURES"; exit 1 }
