# Acceptance test for the safety guard. Must be 100% green before any clean ships.
Import-Module (Join-Path $PSScriptRoot '..\modules\Core.psm1') -Force -ErrorAction Stop

$script:fail = 0
function T($p, $expect, $why) {
    $r = Test-PathProtected $p
    $ok = ($r -eq $expect)
    if (-not $ok) { $script:fail++ }
    "{0}  got={1,-5} want={2,-5} {3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $r, $expect, $why
}

"=== must BLOCK ==="
T 'C:\' $true 'drive root'
T 'D:\' $true 'drive root'
T 'C:\Windows' $true 'windows'
T 'C:\Windows\System32' $true 'system32'
T 'C:\Windows\WinSxS' $true 'component store - DISM only'
T 'C:\Program Files' $true 'installed software'
T 'C:\Program Files (x86)' $true 'installed software'
T 'C:\Users' $true 'all profiles'
T 'C:\Users\VA-007' $true 'profile root'
T 'D:\projects\MobileApp\chat-app\.git' $true 'git metadata'
T 'D:\projects\MobileApp\chat-app\android\.git\objects' $true 'git as ancestor'
T 'C:\Users\VA-007\.gradle\caches\modules-2' $true 'dependency jars - costly re-download'
T 'C:\Users\VA-007\.gradle\caches\modules-2\files-2.1' $true 'inside dependency jars'
T 'D:\projects\MobileApp\chat-app\src' $true 'source leaf'
T 'D:\projects\MobileApp\chat-app\src\components\Chat' $true 'source ancestor'
T 'D:\projects\foo\app' $true 'app AS delete target'
T 'D:\projects\foo\components' $true 'components leaf'
T 'C:\pagefile.sys' $true 'pagefile'
T 'C:\hiberfil.sys' $true 'hibernation'
T 'D:\System Volume Information' $true 'volume metadata'
T 'D:\projects' $true 'too shallow'
T 'C:\Users\VA-007\tools\drive-janitor\logs' $true 'tool own dir'
T '' $true 'empty string'
T 'not-a-path' $true 'malformed'
T 'relative\path' $true 'relative path'

"--- protected roots must cover their whole SUBTREE, not just the exact string ---"
T 'C:\Program Files\SomeApp' $true 'installed app dir'
T 'C:\Program Files\SomeApp\bin\build' $true 'build dir inside installed software'
T 'C:\Program Files (x86)\SomeApp\dist' $true 'dist inside installed software'
T 'C:\Windows\SomethingImportant' $true 'anything under Windows'
T 'C:\ProgramData\SomeApp\cache' $true 'anything under ProgramData'
T "$env:USERPROFILE\Desktop" $true 'Desktop is user data'
T "$env:USERPROFILE\Documents\work" $true 'Documents subtree is user data'
T "$env:USERPROFILE\Pictures\2026" $true 'Pictures subtree is user data'
T "$env:USERPROFILE\OneDrive\stuff" $true 'OneDrive subtree is user data'
T "$env:USERPROFILE\Downloads" $true 'Downloads is NEVER deletable by this tool'
T "$env:USERPROFILE\Downloads\installer.exe" $true 'a file in Downloads'
T "$env:USERPROFILE\Downloads\subfolder\thing.zip" $true 'anything nested in Downloads'
T 'C:\Documents and Settings\VA-007\Downloads\x.zip' $true 'Downloads reached via the legacy alias'

"--- but the narrow disposable carve-outs must still be cleanable ---"
T 'C:\Windows\Temp' $false 'Windows Temp is a real clean target'
T 'C:\Windows\Temp\somefile' $false 'inside Windows Temp'
T 'C:\Windows\SoftwareDistribution\Download' $false 'Windows Update cache is a real clean target'

"--- legacy OS junction aliases (qa-backend-round-1 Finding 1) ---"
T 'C:\Documents and Settings' $true 'legacy alias root'
T 'C:\Documents and Settings\VA-007' $true 'alias resolves to the real profile root'
T 'C:\Documents and Settings\VA-007\.gradle\caches\modules-2' $true 'alias into dependency jars'
T 'C:\Documents and Settings\VA-007\Desktop' $true 'alias into a real user folder'
T 'C:\Users\All Users\something' $true 'All Users alias into ProgramData'

"--- 'styles' must NOT block legitimate python cache cleans (Finding 4) ---"
T 'C:\Users\VA-007\AppData\Local\Programs\Python\Python311\Lib\site-packages\pip\_vendor\pygments\styles\__pycache__' $false 'pygments styles __pycache__ is cleanable'
T 'C:\Users\VA-007\.venv\Lib\site-packages\openpyxl\styles\__pycache__' $false 'openpyxl styles __pycache__ is cleanable'
T 'D:\projects\app\src\styles' $true 'but a real source styles dir is still protected (under src)'
T 'D:\projects\app\styles' $true 'and styles as the delete target is still protected'

"--- installed tooling that merely LOOKS like build output ---"
T 'C:\Users\VA-007\AppData\Local\Android\Sdk\ndk\27.1.12297006\build' $true 'NDK build dir IS the ndk-build toolchain'
T 'C:\Users\VA-007\AppData\Local\Android\Sdk' $true 'Android SDK root'
T 'C:\Users\VA-007\AppData\Local\Android\Sdk\platform-tools' $true 'installed SDK component'
T 'C:\Users\VA-007\AppData\Local\Android\Sdk\ndk\27.1.12297006\build\cmake' $true 'inside NDK toolchain'

"--- canonicalization bypasses (plan-review-1 structural #1) ---"
T 'C:\Windows\System32 ' $true 'trailing space resolves to real System32'
T 'C:\Windows\System32.' $true 'trailing dot resolves to real System32'
T 'C:\Windows\System32   ' $true 'multiple trailing spaces'
T '  C:\Windows\System32' $true 'leading whitespace'
T 'C:\Windows\..\Windows\System32' $true 'dot-dot traversal back into System32'
T 'D:\projects\foo\..\..\..\Windows' $true 'traversal to a protected root'
T 'C:\Users\VA-007\..\VA-007' $true 'traversal resolving to profile root'
T 'C:\PROGRA~1' $true '8.3 short name refused'
T 'C:\Users\VA-007\.gradle\caches\..\caches\modules-2' $true 'traversal into dependency jars'
T '\\server\share\thing' $true 'UNC refused'
T 'C:\Windows\System32:$DATA' $true 'alternate data stream refused'
T 'D:\projects\MobileApp\chat-app\android\app\build\..\..\..\src' $true 'traversal landing in source'

"--- canonicalization must NOT over-block legitimate targets ---"
T 'D:\projects\MobileApp\chat-app\android\app\..\app\build' $false 'harmless traversal, still a build dir'

"=== must ALLOW ==="
T 'D:\projects\MobileApp\chat-app\android\app\build' $false 'gradle app module build - biggest target'
T 'D:\projects\MobileApp\chat-app\android\app\.cxx' $false 'cmake output'
T 'D:\projects\MobileApp\chat-app\node_modules\react-native-reanimated\android\build' $false 'build inside node_modules'
T 'C:\Users\VA-007\.gradle\caches\9.0.0' $false 'transient gradle version cache'
T 'C:\Users\VA-007\AppData\Local\Temp\foo' $false 'temp'
T 'D:\projects\Next-Calendar-schedule\.next' $false 'next build output'
T 'D:\projects\foo\dist' $false 'dist'

""
if ($script:fail -eq 0) { "ALL GUARD TESTS PASSED"; exit 0 } else { "$script:fail FAILURES"; exit 1 }
