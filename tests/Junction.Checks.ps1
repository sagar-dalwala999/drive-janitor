# Regression test for the junction data-loss bug found 2026-08-24.
# robocopy /MIR purges THROUGH nested junctions and destroys their targets anywhere on disk.
# /XJ alone does NOT prevent it. Clear-PathContents must unlink first, then mirror.
Import-Module (Join-Path $PSScriptRoot '..\modules\Core.psm1') -Force -ErrorAction Stop

$script:fail = 0
function Check($cond, $why) {
    if (-not $cond) { $script:fail++ }
    "{0}  {1}" -f $(if ($cond) { 'PASS' } else { 'FAIL' }), $why
}

$sb = Join-Path $env:TEMP ("dj-junction-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path "$sb\precious\deep" | Out-Null
New-Item -ItemType Directory -Force -Path "$sb\proj\android\build\normal\deeper" | Out-Null
'IRREPLACEABLE' | Set-Content "$sb\precious\important.txt"
'ALSO PRECIOUS' | Set-Content "$sb\precious\deep\nested.txt"
'junk'          | Set-Content "$sb\proj\android\build\normal\junk.txt"
'junk2'         | Set-Content "$sb\proj\android\build\normal\deeper\junk2.txt"

# Junctions at two depths inside the tree being cleaned.
cmd /c mklink /J "$sb\proj\android\build\linked" "$sb\precious" | Out-Null
cmd /c mklink /J "$sb\proj\android\build\normal\deeper\alsolinked" "$sb\precious" | Out-Null

"=== nested junctions must not leak the purge to their target ==="
Clear-PathContents -Path "$sb\proj\android\build" -Confirm:$false | Out-Null
Check (Test-Path "$sb\precious\important.txt") 'junction target file survived (depth 1 link)'
Check (Test-Path "$sb\precious\deep\nested.txt") 'junction target file survived (depth 3 link)'
Check ((Get-Content "$sb\precious\important.txt" -EA SilentlyContinue) -eq 'IRREPLACEABLE') 'contents intact, not truncated'
Check (@(Get-ChildItem "$sb\proj\android\build" -Recurse -File -EA SilentlyContinue).Count -eq 0) 'the build dir WAS still emptied (the actual job)'

"=== mirroring directly onto a junction must be refused ==="
cmd /c mklink /J "$sb\directlink" "$sb\precious" | Out-Null
$freed = Clear-PathContents -Path "$sb\directlink" -Confirm:$false
Check ($freed -eq 0) 'refused, reported 0 bytes freed'
Check (Test-Path "$sb\precious\important.txt") 'junction target untouched'

cmd /c rd /s /q "$sb" 2>$null
""
if ($script:fail -eq 0) { "ALL JUNCTION TESTS PASSED"; exit 0 } else { "$script:fail FAILURES"; exit 1 }
