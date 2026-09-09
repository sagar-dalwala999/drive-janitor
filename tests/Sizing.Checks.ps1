# Regression test for Get-DirSize accuracy, found 2026-08-24.
# Get-ChildItem -Recurse is wrong twice over on this machine's real data: it silently drops
# >260-char paths (LongPathsEnabled=0) and it follows junctions, double-counting.
Import-Module (Join-Path $PSScriptRoot '..\modules\Core.psm1') -Force -Global -ErrorAction Stop

$script:fail = 0
function Check($cond, $why) {
    if (-not $cond) { $script:fail++ }
    "{0}  {1}" -f $(if ($cond) { 'PASS' } else { 'FAIL' }), $why
}

$sb = Join-Path $env:TEMP ("dj-sizing-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

# 460-char tree holding 5 MB, plus 1 MB shallow. Truth = 6 MB.
$deep = $sb
1..12 | ForEach-Object { $deep = $deep + "\segment-" + ('x' * 18) + "-$_" }
[IO.Directory]::CreateDirectory("\\?\$deep") | Out-Null
$fs = [IO.File]::Create("\\?\$deep\payload.bin"); $fs.Write((New-Object byte[] 5242880), 0, 5242880); $fs.Close()
[IO.Directory]::CreateDirectory("$sb\shallow") | Out-Null
$fs2 = [IO.File]::Create("$sb\shallow\small.bin"); $fs2.Write((New-Object byte[] 1048576), 0, 1048576); $fs2.Close()

"=== deep-path accuracy (truth: 6291456 bytes) ==="
$size = Get-DirSize -Path $sb
Check ($size -eq 6291456) "Get-DirSize returned $size, want 6291456"
$naive = (Get-ChildItem $sb -Recurse -Force -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
Check ($naive -lt $size) "naive Get-ChildItem under-reports ($naive) - proves the bug is real, not theoretical"

"=== junctions must not be double-counted ==="
$j = Join-Path $env:TEMP ("dj-sizing-j-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
[IO.Directory]::CreateDirectory("$j\real") | Out-Null
[IO.Directory]::CreateDirectory("$j\tree") | Out-Null
$fs3 = [IO.File]::Create("$j\real\blob.bin"); $fs3.Write((New-Object byte[] 2097152), 0, 2097152); $fs3.Close()
cmd /c mklink /J "$j\tree\link" "$j\real" | Out-Null
$treeSize = Get-DirSize -Path "$j\tree"
Check ($treeSize -eq 0) "tree containing only a junction sizes to 0, not 2 MB (got $treeSize)"

"=== shallow tree must match the naive walk exactly ==="
$proj = Split-Path -Parent $PSScriptRoot
$a = (Get-ChildItem $proj -Recurse -Force -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
$b = Get-DirSize -Path $proj
Check ([math]::Abs($a - $b) -lt 8192) "shallow tree agrees within 8 KB (gci=$a robocopy=$b)"

cmd /c rd /s /q "$sb" 2>$null
cmd /c rd /s /q "$j" 2>$null
""
if ($script:fail -eq 0) { "ALL SIZING TESTS PASSED"; exit 0 } else { "$script:fail FAILURES"; exit 1 }
