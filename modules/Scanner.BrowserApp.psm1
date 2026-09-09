# S2 - Chrome/Edge/Brave cache scanner + AI/dev-tool cache scanner. Exports one function per the
# frozen Core contract (modules/Core.psm1). Pure read-only: computes sizes and paths, never deletes.

Set-StrictMode -Version Latest

# No -Force here: Force would evict/reload Core.psm1 even if a caller already imported it
# globally (e.g. S7's orchestrator), stealing it into this module's private scope instead.
Import-Module "$PSScriptRoot\Core.psm1"

function Test-UnderAnyJanitorRoot {
    <# True if $Path resolves to somewhere inside one of the given roots. Fail-closed to $false -
       an unresolvable path is simply excluded from this scanner's results, never treated as a hit. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Roots)
    $rp = Resolve-JanitorPath -Path $Path
    if ($null -eq $rp) { return $false }
    foreach ($r in $Roots) {
        $rr = Resolve-JanitorPath -Path $r
        if ($null -eq $rr) { continue }
        $rr = $rr.TrimEnd('\')
        if ($rp -ieq $rr) { return $true }
        if ($rp -ilike "$rr\*") { return $true }
    }
    return $false
}

function Get-JanitorRunningProcessNote {
    <# The "close X first" clause for a Consequence line, or '' if that process isn't running. #>
    param([Parameter(Mandatory)][string]$ProcessName, [Parameter(Mandatory)][string]$DisplayName)
    if (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue) {
        return " $DisplayName is currently running - close it first, or these files are locked and will be skipped."
    }
    return ''
}

function Invoke-BrowserAppScan {
    <# Chrome/Edge/Brave per-profile caches + on-device model, plus AI/dev-tool caches.
       Pure read-only, no side effects. Never touches profile data (bookmarks/cookies/history/
       Login Data/Web Data/Local Storage/Preferences) - only the four named cache subfolders. #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string[]]$Roots)

    $findings = @()
    $cacheLeaves = @('Cache', 'Code Cache', 'GPUCache', 'Service Worker')

    $browsers = @(
        [pscustomobject]@{ Name = 'Chrome'; Process = 'chrome'; UserData = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data' }
        [pscustomobject]@{ Name = 'Edge';   Process = 'msedge'; UserData = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data' }
        [pscustomobject]@{ Name = 'Brave';  Process = 'brave';  UserData = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' }
    )

    foreach ($browser in $browsers) {
        if (-not (Test-Path -LiteralPath $browser.UserData)) { continue }
        if (Test-PathReparsePoint -Path $browser.UserData) { continue }
        if (-not (Test-UnderAnyJanitorRoot -Path $browser.UserData -Roots $Roots)) { continue }

        $closeNote = Get-JanitorRunningProcessNote -ProcessName $browser.Process -DisplayName $browser.Name

        # Profiles are named Default / Guest Profile / Profile <n> - never hardcode which numbers exist.
        $profiles = Get-ChildItem -LiteralPath $browser.UserData -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(Default|Guest Profile|Profile \d+)$' } |
                    Where-Object { -not (Test-PathReparsePoint -Path $_.FullName) }

        foreach ($prof in $profiles) {
            $paths = @()
            $foundLeaves = @()
            $totalBytes = [long]0
            foreach ($leaf in $cacheLeaves) {
                $leafPath = Join-Path $prof.FullName $leaf
                if (-not (Test-Path -LiteralPath $leafPath)) { continue }
                if (Test-PathReparsePoint -Path $leafPath) { continue }   # never target a symlinked cache dir
                $sz = Get-DirSize -Path $leafPath
                if ($sz -le 0) { continue }
                $paths += $leafPath
                $foundLeaves += $leaf
                $totalBytes += $sz
            }
            if ($paths.Count -eq 0) { continue }

            $findings += New-Finding -Category 'Browser Cache' `
                -Title "$($browser.Name) - $($prof.Name) cache" `
                -Paths $paths -Bytes $totalBytes -Count $paths.Count `
                -Risk Moderate -Action Empty `
                -Detail ("{0} of {1} cache folders present: {2}" -f $paths.Count, $cacheLeaves.Count, ($foundLeaves -join ', ')) `
                -Consequence ("Regenerates automatically as you browse - bookmarks, cookies, saved passwords and history are never touched.$closeNote")
        }

        # The on-device AI model lives once at the User Data root, not per profile - verified on this machine.
        $modelPath = Join-Path $browser.UserData 'OptGuideOnDeviceModel'
        if ((Test-Path -LiteralPath $modelPath) -and -not (Test-PathReparsePoint -Path $modelPath)) {
            $sz = Get-DirSize -Path $modelPath
            if ($sz -gt 0) {
                $findings += New-Finding -Category 'Browser Cache' `
                    -Title "$($browser.Name) - on-device AI model (OptGuideOnDeviceModel)" `
                    -Paths @($modelPath) -Bytes $sz -Count 1 `
                    -Risk Moderate -Action Empty `
                    -Detail 'On-device Gemini Nano model files (Optimization Guide)' `
                    -Consequence ("$($browser.Name) re-downloads this model the next time an on-device AI feature needs it. No browsing data is affected.$closeNote")
            }
        }
    }

    # AI / dev tool caches - fixed known relative locations, never a wide recursive tree walk.
    $vsCodeRoots = @('Code', 'Code - Insiders', 'Code - OSS') |
                   ForEach-Object { Join-Path $env:APPDATA $_ } |
                   Where-Object { Test-Path -LiteralPath $_ }
    $codeCloseNote = Get-JanitorRunningProcessNote -ProcessName 'Code' -DisplayName 'VS Code'

    $candidates = @(
        [pscustomobject]@{ Path = Join-Path $env:USERPROFILE '.cache\codex-runtimes'; Title = 'Codex runtime cache (.cache\codex-runtimes)'; Detail = 'Cached Codex/OpenAI CLI runtime downloads'; Consequence = 'Re-downloaded automatically the next time a Codex-based CLI runs.' }
        [pscustomobject]@{ Path = Join-Path $env:USERPROFILE '.cache\huggingface'; Title = 'Hugging Face cache (.cache\huggingface)'; Detail = 'Cached model/dataset files pulled via the HF hub'; Consequence = 'Any tool that loads a Hugging Face model or dataset re-downloads it on next use - can be slow for large models.' }
        [pscustomobject]@{ Path = Join-Path $env:USERPROFILE '.gemini\antigravity-backup'; Title = 'Antigravity backup cache (.gemini\antigravity-backup)'; Detail = 'Antigravity local backup/cache directory'; Consequence = 'Antigravity recreates this as needed - it is a cache/backup copy, not your active config or chat history.' }
        [pscustomobject]@{ Path = Join-Path $env:USERPROFILE '.codeium\database'; Title = 'Codeium index database (.codeium\database)'; Detail = 'Local index/embedding database Codeium builds from your projects'; Consequence = 'Codeium rebuilds this by re-indexing your projects on next use - a one-time re-index delay, no data lost.' }
    )
    foreach ($vsRoot in $vsCodeRoots) {
        $leafName = Split-Path $vsRoot -Leaf
        $candidates += [pscustomobject]@{ Path = Join-Path $vsRoot 'CachedExtensionVSIXs'; Title = "VS Code extension installer cache ($leafName)"; Detail = 'Downloaded .vsix installers VS Code keeps around'; Consequence = "VS Code re-downloads a .vsix only if it needs to reinstall that exact version. Installed extensions are not removed.$codeCloseNote" }
        $candidates += [pscustomobject]@{ Path = Join-Path $vsRoot 'Code Cache'; Title = "VS Code V8 code cache ($leafName)"; Detail = 'Compiled JS bytecode cache (Electron/V8)'; Consequence = "Rebuilt automatically on next launch - startup is marginally slower once.$codeCloseNote" }
    }

    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        if (Test-PathReparsePoint -Path $c.Path) { continue }
        if (-not (Test-UnderAnyJanitorRoot -Path $c.Path -Roots $Roots)) { continue }
        $sz = Get-DirSize -Path $c.Path
        if ($sz -le 0) { continue }
        $findings += New-Finding -Category 'AI/Dev Tool Cache' -Title $c.Title -Paths @($c.Path) -Bytes $sz -Count 1 `
            -Risk Moderate -Action Empty -Detail $c.Detail -Consequence $c.Consequence
    }

    # ms-playwright* browser-binary bundles - enumerate dynamically, never hardcode the suffix list.
    $playwrightDirs = Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Force -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -like 'ms-playwright*' -and -not (Test-PathReparsePoint -Path $_.FullName) }
    foreach ($pd in $playwrightDirs) {
        if (-not (Test-UnderAnyJanitorRoot -Path $pd.FullName -Roots $Roots)) { continue }
        $sz = Get-DirSize -Path $pd.FullName
        if ($sz -le 0) { continue }
        $findings += New-Finding -Category 'AI/Dev Tool Cache' -Title "Playwright browser bundles ($($pd.Name))" `
            -Paths @($pd.FullName) -Bytes $sz -Count 1 -Risk Moderate -Action Empty `
            -Detail 'Downloaded Chromium/Firefox/WebKit binaries' `
            -Consequence 'Re-downloaded automatically the next time `npx playwright install` or a Playwright-driven script runs.'
    }

    return $findings
}

Export-ModuleMember -Function Invoke-BrowserAppScan
