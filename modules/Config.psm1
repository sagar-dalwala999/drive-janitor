# Drive Janitor — persisted settings (roots, thresholds, exclusions, last scan).
# Owned by S7. Load/save must never throw — a corrupt config.json falls back to defaults.

Set-StrictMode -Version Latest

$script:ToolRoot = Split-Path -Parent $PSScriptRoot

function Get-JanitorConfigPath {
    Join-Path $script:ToolRoot 'config.json'
}

function Get-DefaultJanitorConfig {
    # Field names match what ui/Gui.ps1 actually reads/writes (MinSizeMB, AgeDays) - the prior
    # schema (MinSizeBytes, AgeThresholdDays) silently dropped both on every load because the
    # merge below only copies a loaded property onto a default field of the SAME name.
    [pscustomobject]@{
        Roots      = @('C:\', 'D:\')
        MinSizeMB  = 10
        AgeDays    = 90
        Exclusions = @()
        # Off by default: ~60% of a full scan's runtime, and its findings are report-only.
        FindDuplicates = $false
        LastScan   = $null
    }
}

# Legacy field names from before the MinSizeMB/AgeDays rename (FIX 2) - migrated on load so a
# config.json written by an older build never silently loses its saved thresholds.
$script:LegacyFieldMap = @{ MinSizeBytes = 'MinSizeMB'; AgeThresholdDays = 'AgeDays' }

function ConvertTo-JanitorConfigArray {
    <# Guards the single-element-array-to-scalar collapse. The real mechanism (verified via a
       real fixture run, not assumed): PowerShell unwraps a 1-element array back to its bare
       scalar element when a function returns it through the normal output stream - "return
       @(...)" is NOT enough by itself. The leading unary comma below is load-bearing: it forces
       the array itself onto the pipeline as a single object instead of something to enumerate.
       Always returns a real array, empty entries stripped. #>
    param($Value)
    if ($null -eq $Value) { return ,@() }
    return ,@($Value | Where-Object { $_ -ne $null -and $_ -ne '' })
}

function Get-JanitorConfig {
    <# Loads config.json. Missing file -> defaults. Corrupt/unreadable file -> defaults,
       never throws. Unknown/legacy fields in the file are merged onto defaults so an older
       or hand-edited config.json never drops a field the app expects. #>
    [CmdletBinding()]
    param([string]$Path = (Get-JanitorConfigPath))

    $default = Get-DefaultJanitorConfig
    if (-not (Test-Path -LiteralPath $Path)) { return $default }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        $loaded = $raw | ConvertFrom-Json -ErrorAction Stop

        $merged = $default.PSObject.Copy()
        foreach ($prop in $loaded.PSObject.Properties) {
            $name = $prop.Name
            if ($script:LegacyFieldMap.ContainsKey($name) -and -not ($loaded.PSObject.Properties.Name -contains $script:LegacyFieldMap[$name])) {
                $name = $script:LegacyFieldMap[$name]   # e.g. MinSizeBytes (bytes) predates MinSizeMB - best-effort MB conversion below
            }
            if ($merged.PSObject.Properties.Name -contains $name) {
                $value = $prop.Value
                if ($name -eq 'MinSizeMB' -and $prop.Name -eq 'MinSizeBytes' -and $value) { $value = [int]([long]$value / 1MB) }
                $merged.($name) = $value
            }
        }

        # ConvertFrom-Json/ConvertTo-Json can collapse a 1-element array to a bare scalar - force
        # every array-shaped field back into a real array regardless of element count.
        $merged.Roots = ConvertTo-JanitorConfigArray $merged.Roots
        if ($merged.Roots.Count -eq 0) { $merged.Roots = $default.Roots }
        $merged.Exclusions = ConvertTo-JanitorConfigArray $merged.Exclusions

        if ($null -eq $merged.MinSizeMB) { $merged.MinSizeMB = $default.MinSizeMB }
        if ($null -eq $merged.AgeDays)   { $merged.AgeDays   = $default.AgeDays }

        return $merged
    } catch {
        Write-Warning "config.json is corrupt or unreadable ($_) - using defaults."
        return $default
    }
}

function Save-JanitorConfig {
    <# Writes config.json. Returns $true/$false instead of throwing so callers (GUI included)
       can show a message instead of crashing on a locked/read-only file. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Path = (Get-JanitorConfigPath)
    )
    try {
        # Belt-and-suspenders against the same array collapse on the way out. Do NOT wrap these
        # calls in another @() - ConvertTo-JanitorConfigArray's own unary comma already prevents
        # collapse, and a second @() would nest a 1-element result inside another array.
        $out = [ordered]@{
            Roots      = ConvertTo-JanitorConfigArray (Get-JanitorConfigField $Config 'Roots')
            MinSizeMB  = Get-JanitorConfigField $Config 'MinSizeMB'
            AgeDays    = Get-JanitorConfigField $Config 'AgeDays'
            Exclusions = ConvertTo-JanitorConfigArray (Get-JanitorConfigField $Config 'Exclusions')
            LastScan   = Get-JanitorConfigField $Config 'LastScan'
        }
        $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
        return $true
    } catch {
        Write-Warning "failed to save config.json: $_"
        return $false
    }
}

function Get-JanitorConfigField {
    <# $Config may be a Hashtable (ui/Gui.ps1 builds one) or a PSCustomObject - probe both
       shapes rather than assuming one, so Save-JanitorConfig never throws on a valid caller. #>
    param($Config, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Config) { return $null }
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains($Name)) { return $Config[$Name] }
        return $null
    }
    if ($Config.PSObject.Properties.Name -contains $Name) { return $Config.$Name }
    return $null
}

Export-ModuleMember -Function Get-JanitorConfig, Save-JanitorConfig, Get-DefaultJanitorConfig, Get-JanitorConfigPath
