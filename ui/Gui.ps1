# Drive Janitor - WPF GUI (S6). Owns this file + MainWindow.xaml only.
# Calls S7's Invoke-AllScans / Invoke-Clean (must exist in the caller's scope before
# Show-JanitorWindow runs) from a background runspace so the window never freezes.

Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xml

$script:UiRoot = $PSScriptRoot
Import-Module (Join-Path $script:UiRoot '..\modules\Core.psm1') -Force -ErrorAction Stop

$script:RiskColors = @{
    Safe     = @{ Bg = '#E6F4EA'; Fg = '#2E7D32' }
    Moderate = @{ Bg = '#FFF3CD'; Fg = '#B36B00' }
    Advanced = @{ Bg = '#FDE7E7'; Fg = '#C62828' }
}

function Get-PressureColor {
    # red <10% free, amber <20% free, else green - mirrors drive-bar and risk-badge palette.
    param([double]$PercentFree)
    if ($PercentFree -lt 10) { return '#C62828' }
    if ($PercentFree -lt 20) { return '#B36B00' }
    return '#2E7D32'
}

function New-DriveBarElement {
    param([string]$Letter, [long]$FreeBytes, [long]$TotalBytes)

    $pctFree = if ($TotalBytes -gt 0) { [math]::Round(($FreeBytes / $TotalBytes) * 100, 1) } else { 0 }
    $color = Get-PressureColor -PercentFree $pctFree
    $usedBytes = $TotalBytes - $FreeBytes

    $wrap = New-Object System.Windows.Controls.StackPanel
    $wrap.Margin = '0,0,0,8'

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = "$Letter   $(Format-Size $FreeBytes) free of $(Format-Size $TotalBytes)   ($pctFree% free)"
    $label.Margin = '0,0,0,3'
    $label.FontSize = 12.5
    $wrap.Children.Add($label) | Out-Null

    $track = New-Object System.Windows.Controls.Border
    $track.Height = 16
    $track.CornerRadius = 3
    $track.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E0E0E0')

    $barGrid = New-Object System.Windows.Controls.Grid
    $usedRatio = if ($TotalBytes -gt 0) { [double]$usedBytes / [double]$TotalBytes } else { 0 }
    if ($usedRatio -lt 0.02) { $usedRatio = 0.02 }   # keep the used sliver visible even when tiny
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength($usedRatio, [System.Windows.GridUnitType]::Star)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = New-Object System.Windows.GridLength([double](1 - $usedRatio), [System.Windows.GridUnitType]::Star)
    $barGrid.ColumnDefinitions.Add($c1) | Out-Null
    $barGrid.ColumnDefinitions.Add($c2) | Out-Null

    $usedFill = New-Object System.Windows.Controls.Border
    $usedFill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
    $usedFill.CornerRadius = 3
    [System.Windows.Controls.Grid]::SetColumn($usedFill, 0)
    $barGrid.Children.Add($usedFill) | Out-Null

    $track.Child = $barGrid
    $wrap.Children.Add($track) | Out-Null
    return $wrap
}

function Update-DriveBars {
    param($DrivePanel)
    $DrivePanel.Children.Clear()
    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
    foreach ($d in ($disks | Sort-Object DeviceID)) {
        if ($null -eq $d.Size -or $d.Size -eq 0) { continue }
        $DrivePanel.Children.Add((New-DriveBarElement -Letter $d.DeviceID -FreeBytes $d.FreeSpace -TotalBytes $d.Size)) | Out-Null
    }
}

function New-RiskBadge {
    param([string]$Risk)
    $colors = $script:RiskColors[$Risk]
    if (-not $colors) { $colors = @{ Bg = '#EEEEEE'; Fg = '#555555' } }
    $b = New-Object System.Windows.Controls.Border
    $b.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colors.Bg)
    $b.CornerRadius = 3
    $b.Padding = '6,2'
    $b.VerticalAlignment = 'Center'
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Risk
    $t.FontSize = 11
    $t.FontWeight = 'SemiBold'
    $t.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($colors.Fg)
    $b.Child = $t
    return $b
}

function New-FindingRow {
    param($Finding, [scriptblock]$OnToggle)

    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,4,0,4'
    foreach ($w in @(28, '*', 90, 90, 90)) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        if ($w -eq '*') { $cd.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) }
        else { $cd.Width = New-Object System.Windows.GridLength([double]$w) }
        $row.ColumnDefinitions.Add($cd) | Out-Null
    }

    # Report-action findings are informational only - a checkbox there would let a user
    # try to "select" something the cleaner will always skip. Leave the cell empty instead.
    if ($Finding.Action -ne 'Report') {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.IsChecked = [bool]$Finding.Selected
        $cb.VerticalAlignment = 'Center'
        $cb.Tag = $Finding
        $cb.Add_Checked({ param($s, $e) $s.Tag.Selected = $true; & $script:OnSelectionChanged })
        $cb.Add_Unchecked({ param($s, $e) $s.Tag.Selected = $false; & $script:OnSelectionChanged })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $row.Children.Add($cb) | Out-Null
    }

    $textStack = New-Object System.Windows.Controls.StackPanel
    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = $Finding.Title
    $title.FontWeight = 'SemiBold'
    $title.TextWrapping = 'Wrap'
    $textStack.Children.Add($title) | Out-Null

    if ($Finding.Consequence) {
        $cons = New-Object System.Windows.Controls.TextBlock
        $cons.Text = $Finding.Consequence
        $cons.Foreground = '#777777'
        $cons.FontSize = 11.5
        $cons.TextWrapping = 'Wrap'
        $cons.Margin = '0,2,0,0'
        $textStack.Children.Add($cons) | Out-Null
    }
    if ($Finding.Action -eq 'Report') {
        $tag = New-Object System.Windows.Controls.TextBlock
        $tag.Text = 'Report only - not cleanable from this tool'
        $tag.Foreground = '#999999'
        $tag.FontStyle = 'Italic'
        $tag.FontSize = 11
        $tag.Margin = '0,2,0,0'
        $textStack.Children.Add($tag) | Out-Null
    }
    $row.ToolTip = $Finding.Consequence
    [System.Windows.Controls.Grid]::SetColumn($textStack, 1)
    $row.Children.Add($textStack) | Out-Null

    $badge = New-RiskBadge -Risk $Finding.Risk
    $badge.HorizontalAlignment = 'Left'
    [System.Windows.Controls.Grid]::SetColumn($badge, 2)
    $row.Children.Add($badge) | Out-Null

    $size = New-Object System.Windows.Controls.TextBlock
    $size.Text = Format-Size $Finding.Bytes
    $size.HorizontalAlignment = 'Right'
    $size.VerticalAlignment = 'Center'
    $size.FontWeight = 'SemiBold'
    [System.Windows.Controls.Grid]::SetColumn($size, 3)
    $row.Children.Add($size) | Out-Null

    $count = New-Object System.Windows.Controls.TextBlock
    $count.Text = "$($Finding.Count) item$(if ($Finding.Count -ne 1) { 's' })"
    $count.HorizontalAlignment = 'Right'
    $count.VerticalAlignment = 'Center'
    $count.Foreground = '#777777'
    $count.FontSize = 11.5
    [System.Windows.Controls.Grid]::SetColumn($count, 4)
    $row.Children.Add($count) | Out-Null

    return $row
}

function New-CategoryExpander {
    param([string]$Category, [object[]]$Findings)

    $totalBytes = ($Findings | Measure-Object -Property Bytes -Sum).Sum
    $totalCount = ($Findings | Measure-Object -Property Count -Sum).Sum

    $exp = New-Object System.Windows.Controls.Expander
    $exp.IsExpanded = $true
    $exp.Margin = '0,0,0,10'
    $exp.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E5E5E5')
    $exp.BorderThickness = '1'
    $exp.Padding = '6'

    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = "$Category   ($totalCount items, $(Format-Size $totalBytes))"
    $header.FontWeight = 'Bold'
    $header.FontSize = 13.5
    $exp.Header = $header

    $body = New-Object System.Windows.Controls.StackPanel
    $body.Margin = '10,6,0,0'
    foreach ($f in $Findings) {
        $body.Children.Add((New-FindingRow -Finding $f)) | Out-Null
    }
    $exp.Content = $body
    return $exp
}

function Show-PathListModal {
    param($Owner, [string]$Title, [string[]]$Paths, [string]$SummaryLine)

    $win = New-Object System.Windows.Window
    $win.Title = $Title
    $win.Width = 640
    $win.Height = 480
    $win.Owner = $Owner
    $win.WindowStartupLocation = 'CenterOwner'
    $win.WindowStyle = 'ToolWindow'

    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = 12
    $r0 = New-Object System.Windows.Controls.RowDefinition; $r0.Height = 'Auto'
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = 'Auto'
    $grid.RowDefinitions.Add($r0) | Out-Null; $grid.RowDefinitions.Add($r1) | Out-Null; $grid.RowDefinitions.Add($r2) | Out-Null

    $summary = New-Object System.Windows.Controls.TextBlock
    $summary.Text = $SummaryLine
    $summary.FontWeight = 'SemiBold'
    $summary.Margin = '0,0,0,8'
    [System.Windows.Controls.Grid]::SetRow($summary, 0)
    $grid.Children.Add($summary) | Out-Null

    $list = New-Object System.Windows.Controls.ListBox
    $list.ItemsSource = $Paths
    $list.FontFamily = 'Consolas'
    $list.FontSize = 11.5
    [System.Windows.Controls.Grid]::SetRow($list, 1)
    $grid.Children.Add($list) | Out-Null

    $btn = New-Object System.Windows.Controls.Button
    $btn.Content = 'Close'
    $btn.Padding = '18,6'
    $btn.HorizontalAlignment = 'Right'
    $btn.Margin = '0,10,0,0'
    $btn.Add_Click({ $win.Close() }.GetNewClosure())
    [System.Windows.Controls.Grid]::SetRow($btn, 2)
    $grid.Children.Add($btn) | Out-Null

    $win.Content = $grid
    $win.ShowDialog() | Out-Null
}

function Show-ConfirmDialog {
    # A custom modal instead of [System.Windows.MessageBox]::Show(): the native MessageBox
    # never returns when invoked from a click handler on a window already inside its own
    # ShowDialog() pump on this host (verified via isolated repro) - a frozen confirm dialog
    # would violate the "UI must never freeze" rule. This uses the same proven Window+ShowDialog
    # pattern as Show-PathListModal above.
    #
    # Callback-style, not a return value: a script-scoped result variable read AFTER
    # ShowDialog() unblocks was observed to read stale/reset state on this host (verified via
    # isolated logging). $OnConfirm runs synchronously from inside the Yes/OK click handler
    # instead, and is carried on the button's own .Tag - the same Tag-carries-state pattern
    # already proven reliable for the finding checkboxes in New-FindingRow - rather than a
    # $script: variable, since that too was observed to reset during the dialog's own pump.
    param($Owner, [string]$Title, [string]$Message, [ValidateSet('YesNo', 'OK')][string]$Buttons = 'OK', [string]$Icon = 'Info', [scriptblock]$OnConfirm = $null)

    $win = New-Object System.Windows.Window
    $win.Title = $Title
    $win.SizeToContent = 'WidthAndHeight'
    $win.MinWidth = 360
    $win.Owner = $Owner
    $win.WindowStartupLocation = 'CenterOwner'
    $win.WindowStyle = 'ToolWindow'
    $win.ResizeMode = 'NoResize'

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = 18

    $msgBlock = New-Object System.Windows.Controls.TextBlock
    $msgBlock.Text = $Message
    $msgBlock.TextWrapping = 'Wrap'
    $msgBlock.MaxWidth = 420
    if ($Icon -eq 'Error') { $msgBlock.Foreground = '#C62828' }
    elseif ($Icon -eq 'Warning') { $msgBlock.Foreground = '#B36B00' }
    $panel.Children.Add($msgBlock) | Out-Null

    $btnRow = New-Object System.Windows.Controls.StackPanel
    $btnRow.Orientation = 'Horizontal'
    $btnRow.HorizontalAlignment = 'Right'
    $btnRow.Margin = '0,16,0,0'

    # Confirmed + Callback ride on $win.Tag; the actual callback fires from Closed, not from
    # the button's own Click - invoking Invoke-InBackgroundRunspace (which starts a second
    # DispatcherTimer) from directly inside the Yes handler was observed to hang on this host,
    # apparently because we are still nested inside this dialog's own ShowDialog() pump at that
    # point. Closed fires once the modal has fully torn down, so the callback runs back at the
    # outer (main window) dispatcher level instead.
    $win.Tag = @{ Confirmed = $false; Callback = $OnConfirm }

    if ($Buttons -eq 'YesNo') {
        $yesBtn = New-Object System.Windows.Controls.Button
        $yesBtn.Content = 'Yes'; $yesBtn.Padding = '18,6'; $yesBtn.Margin = '0,0,8,0'
        $yesBtn.Add_Click({ $win.Tag.Confirmed = $true; $win.Close() }.GetNewClosure())
        $btnRow.Children.Add($yesBtn) | Out-Null

        $noBtn = New-Object System.Windows.Controls.Button
        $noBtn.Content = 'No'; $noBtn.Padding = '18,6'
        $noBtn.Add_Click({ $win.Close() }.GetNewClosure())
        $btnRow.Children.Add($noBtn) | Out-Null
    } else {
        $okBtn = New-Object System.Windows.Controls.Button
        $okBtn.Content = 'OK'; $okBtn.Padding = '18,6'; $okBtn.IsDefault = $true
        $okBtn.Add_Click({ $win.Tag.Confirmed = $true; $win.Close() }.GetNewClosure())
        $btnRow.Children.Add($okBtn) | Out-Null
    }
    $win.Add_Closed({
        if ($win.Tag.Confirmed -and $win.Tag.Callback) { & $win.Tag.Callback }
    }.GetNewClosure())

    $panel.Children.Add($btnRow) | Out-Null
    $win.Content = $panel
    $win.ShowDialog() | Out-Null
}

function Get-SelectedFindings {
    # Inlined at every call site instead of invoked here (see those sites) - calling this named
    # function from inside a WPF event-delegate closure (DispatcherTimer.Tick, Button.Click) was
    # reproduced to throw a StrictMode "'Count' cannot be found" PropertyNotFoundException that
    # bypasses even a try/catch wrapped directly around the call (verified via bisected logging,
    # 2026-08-24) - a $ErrorActionPreference='Continue' + StrictMode interaction specific to
    # scriptblocks invoked as .NET delegates, not normal script flow. Kept here only as reference/
    # for any FUTURE call from plain synchronous script code, where it is safe.
    @($script:AllFindings | Where-Object { $_.Action -ne 'Report' -and $_.Selected })
}

function Invoke-InBackgroundRunspace {
    # Runs $FunctionName (captured from the caller's already-loaded scope, e.g. S7's
    # DriveJanitor.ps1) on a real background thread. Progress crosses the runspace boundary
    # as plain data in a synchronized hashtable - a UI-thread DispatcherTimer polls it and
    # calls $OnProgress itself, so $OnProgress's closure over WPF controls never has to
    # execute inside a delegate invoked from the background thread's context.
    param(
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][scriptblock]$OnProgress,
        [Parameter(Mandatory)][scriptblock]$OnDone,
        [Parameter(Mandatory)][scriptblock]$OnError
    )

    $cmd = Get-Command $FunctionName -ErrorAction SilentlyContinue
    if (-not $cmd) {
        & $OnError "S7 has not defined $FunctionName yet - cannot run."
        return
    }

    $sync = [hashtable]::Synchronized(@{ LastProgress = $null })

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $funcEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($FunctionName, $cmd.ScriptBlock)
    $iss.Commands.Add($funcEntry)
    $varEntry = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('Sync', $sync, '')
    $iss.Variables.Add($varEntry)

    # Transferring $FunctionName's scriptblock does not carry its own module dependencies
    # (e.g. Invoke-AllScans calling New-Finding from Core.psm1) - re-import every module
    # already loaded in this (UI-thread) session so those internal calls resolve too.
    $modulePaths = @(Get-Module | Where-Object { $_.Path } | Select-Object -ExpandProperty Path -Unique)
    if ($modulePaths.Count -gt 0) { $iss.ImportPSModule($modulePaths) }

    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()

    # SessionStateFunctionEntry transplants ONLY the function's own scriptblock - it does NOT
    # carry $script:-scoped variables from the caller's script (e.g. DriveJanitor.ps1's own
    # $script:ScannerSpecs, which Invoke-AllScans reads). Without this, $script:ScannerSpecs
    # resolves empty in the new runspace and the scanner loop silently never runs: zero
    # findings, zero errors, no crash - reproduced + root-caused 2026-08-24. Adding these via
    # InitialSessionState.Variables BEFORE Open() does NOT fix it (verified); SetVariable on the
    # opened runspace's own SessionStateProxy does - it lands where $script: lookups find it.
    # Copy ONLY plain data. A WPF object handed to another runspace keeps its thread affinity,
    # and when the background thread releases it the Dispatcher is torn down - the window closes,
    # ShowDialog() returns and the script ends with exit code 0. That reads as "it just closed
    # by itself" with no exception and no log line, and it only shows up on scans long enough
    # for the runspace to outlive the UI's expectations. Measured 2026-08-25.
    foreach ($v in (Get-Variable -Scope Script)) {
        if ($v.Name -in @('Sync', 'null', 'true', 'false')) { continue }
        $val = $v.Value
        if ($null -ne $val) {
            if ($val -is [System.Windows.Threading.DispatcherObject]) { continue }
            $t = $val.GetType().FullName
            if ($t -like 'System.Windows.*' -or $t -like 'MS.Internal.*') { continue }
            # A collection can hide one too (e.g. a list of controls).
            if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
                $hasUi = $false
                foreach ($item in $val) {
                    if ($null -ne $item -and $item -is [System.Windows.Threading.DispatcherObject]) { $hasUi = $true; break }
                }
                if ($hasUi) { continue }
            }
        }
        try { $rs.SessionStateProxy.SetVariable($v.Name, $val) } catch { }
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs

    $progressCb = [scriptblock]::Create('param($p) $Sync.LastProgress = $p')

    $script = [scriptblock]::Create("param(`$Args1, `$Cb) $FunctionName @Args1 -ProgressCallback `$Cb")
    $ps.AddScript($script).AddArgument($Arguments).AddArgument($progressCb) | Out-Null
    $handle = $ps.BeginInvoke()
    $lastSeen = $null

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        $p = $sync.LastProgress
        if ($p -and -not [object]::ReferenceEquals($p, $lastSeen)) {
            $lastSeen = $p
            & $OnProgress $p
        }
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        try {
            $result = $ps.EndInvoke($handle)
            if ($ps.HadErrors) {
                $msg = ($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join "`n"
                & $OnError $msg
            } else {
                & $OnDone $result
            }
        } catch {
            & $OnError $_.Exception.Message
        } finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

function Show-JanitorWindow {
    [CmdletBinding()]
    param([string[]]$DefaultRoots = @('C:\', 'D:\'))

    # Every cross-callback reference below is $script:-scoped, not captured via GetNewClosure().
    # Windows PowerShell 5.1's GetNewClosure() does not reliably re-capture a variable whose
    # value is itself a closure (e.g. $render) once nested three-plus closures deep (click
    # handler -> onDone -> timer tick) - it silently resolves to $null instead of throwing.
    # $script: scope sidesteps that: it is a plain named-scope lookup, not a closure snapshot.
    [xml]$xamlDoc = Get-Content -LiteralPath (Join-Path $script:UiRoot 'MainWindow.xaml') -Raw
    $reader = New-Object System.Xml.XmlNodeReader $xamlDoc
    $script:Win = [System.Windows.Markup.XamlReader]::Load($reader)

    $script:DrivePanel    = $script:Win.FindName('DrivePanel')
    $script:BtnScan       = $script:Win.FindName('BtnScan')
    $script:BtnDryRun     = $script:Win.FindName('BtnDryRun')
    $script:BtnClean      = $script:Win.FindName('BtnClean')
    $script:BtnExportCsv  = $script:Win.FindName('BtnExportCsv')
    $script:BtnAdvToggle  = $script:Win.FindName('BtnAdvancedToggle')
    $script:AdvPanel      = $script:Win.FindName('AdvancedPanel')
    $script:TxtRoots      = $script:Win.FindName('TxtCustomRoots')
    $script:TxtExcl       = $script:Win.FindName('TxtExclusions')
    $script:TxtMinSize    = $script:Win.FindName('TxtMinSizeMB')
    $script:TxtAge        = $script:Win.FindName('TxtAgeDays')
    $script:ChkDupes      = $script:Win.FindName('ChkFindDuplicates')
    $script:TxtAdvError   = $script:Win.FindName('TxtAdvValidationError')
    $script:BtnSaveAdv    = $script:Win.FindName('BtnSaveAdvanced')
    $script:ProgressPanel = $script:Win.FindName('ProgressPanel')
    $script:ProgressBar   = $script:Win.FindName('ScanProgressBar')
    $script:TxtCurPath    = $script:Win.FindName('TxtCurrentPath')
    $script:TxtStatus     = $script:Win.FindName('TxtStatus')
    $script:FindingsScroll= $script:Win.FindName('FindingsScroll')
    $script:FindingsPanel = $script:Win.FindName('FindingsPanel')
    $script:TxtEmpty      = $script:Win.FindName('TxtEmptyState')
    $script:TxtSelected   = $script:Win.FindName('TxtSelectedTotal')
    $script:ResultPanel   = $script:Win.FindName('ResultPanel')
    $script:ResultContent = $script:Win.FindName('ResultContent')

    # Global safety net: an unhandled exception in ANY click/event handler (ours or a future
    # one) used to propagate straight through this thread's Dispatcher and kill ShowDialog() -
    # exactly the "GUI load failed: ... Count ... " crash QA reproduced 3/3. Setting e.Handled
    # keeps the window alive; the user sees it in the status bar instead of the window vanishing.
    $dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
    $dispatcher.add_UnhandledException({
        param($sender, $e)
        try { Write-JanitorLog -Level 'ERROR' -Message "Unhandled UI exception: $($e.Exception)" } catch { }
        try {
            if ($script:TxtStatus) { $script:TxtStatus.Text = "Error: $($e.Exception.Message)" }
            if ($script:ProgressPanel) { $script:ProgressPanel.Visibility = 'Collapsed' }
            if ($script:BtnScan) { $script:BtnScan.IsEnabled = $true }
            if ($script:BtnAdvToggle) { $script:BtnAdvToggle.IsEnabled = $true }
        } catch { }
        $e.Handled = $true
    })

    $script:AllFindings = @()
    $script:Config = @{ Roots = @($DefaultRoots); MinSizeMB = 0; AgeDays = 0; Exclusions = @(); FindDuplicates = $false }

    $script:OnSelectionChanged = {
        $selected = @($script:AllFindings | Where-Object { $_.Action -ne 'Report' -and $_.Selected })
        $sum = ($selected | Measure-Object -Property Bytes -Sum).Sum
        if (-not $sum) { $sum = 0 }
        $script:TxtSelected.Text = "Selected: $(Format-Size $sum)"
        $script:BtnDryRun.IsEnabled = ($selected.Count -gt 0)
        $script:BtnClean.IsEnabled  = ($selected.Count -gt 0)
    }

    Update-DriveBars -DrivePanel $script:DrivePanel

    # Soft dependency on S7's Config.psm1 - GUI degrades to in-memory-only settings if absent.
    $getCfg = Get-Command Get-JanitorConfig -ErrorAction SilentlyContinue
    if ($getCfg) {
        try {
            $loaded = & $getCfg
            if ($loaded) {
                if ($loaded.Roots) { $script:Config.Roots = @($loaded.Roots) }
                if ($null -ne $loaded.MinSizeMB) { $script:Config.MinSizeMB = [int]$loaded.MinSizeMB }
                if ($null -ne $loaded.AgeDays) { $script:Config.AgeDays = [int]$loaded.AgeDays }
                if ($null -ne $loaded.FindDuplicates) { $script:Config.FindDuplicates = [bool]$loaded.FindDuplicates }
                if ($loaded.Exclusions) { $script:Config.Exclusions = @($loaded.Exclusions) }
            }
        } catch { }
    }
    $script:TxtRoots.Text = ($script:Config.Roots -join "`r`n")
    $script:TxtExcl.Text  = ($script:Config.Exclusions -join "`r`n")
    $script:TxtMinSize.Text = [string]$script:Config.MinSizeMB
    $script:TxtAge.Text     = [string]$script:Config.AgeDays
    if ($script:ChkDupes) { $script:ChkDupes.IsChecked = [bool]$script:Config.FindDuplicates }
    $script:DefaultRootsForSave = @($DefaultRoots)

    $script:BtnAdvToggle.Add_Click({
        if ($script:AdvPanel.Visibility -eq 'Visible') {
            $script:AdvPanel.Visibility = 'Collapsed'
            $script:BtnAdvToggle.Content = 'Advanced (show)'
        } else {
            $script:AdvPanel.Visibility = 'Visible'
            $script:BtnAdvToggle.Content = 'Advanced (hide)'
        }
    })

    $script:RedBorder = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#C62828')

    $script:BtnSaveAdv.Add_Click({
        $roots = @($script:TxtRoots.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $excl  = @($script:TxtExcl.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })

        $minMb = 0
        $minSizeValid = [int]::TryParse($script:TxtMinSize.Text.Trim(), [ref]$minMb) -and $minMb -ge 0
        $ageD = 0
        $ageValid = [int]::TryParse($script:TxtAge.Text.Trim(), [ref]$ageD) -and $ageD -ge 0

        if ($minSizeValid) { $script:TxtMinSize.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty) }
        else { $script:TxtMinSize.BorderBrush = $script:RedBorder }
        if ($ageValid) { $script:TxtAge.ClearValue([System.Windows.Controls.Control]::BorderBrushProperty) }
        else { $script:TxtAge.BorderBrush = $script:RedBorder }

        if (-not $minSizeValid -or -not $ageValid) {
            $problems = @()
            if (-not $minSizeValid) { $problems += 'Min size (MB) must be a whole number 0 or greater.' }
            if (-not $ageValid) { $problems += 'Age threshold (days) must be a whole number 0 or greater.' }
            $script:TxtAdvError.Text = ($problems -join ' ')
            $script:TxtAdvError.Visibility = 'Visible'
            $script:TxtStatus.Text = 'Settings not saved - fix the highlighted field(s)'
            return
        }
        $script:TxtAdvError.Visibility = 'Collapsed'

        $script:Config = @{ Roots = $(if ($roots.Count) { $roots } else { $script:DefaultRootsForSave }); MinSizeMB = $minMb; AgeDays = $ageD; Exclusions = $excl; FindDuplicates = [bool]($script:ChkDupes -and $script:ChkDupes.IsChecked) }

        $saveCfg = Get-Command Save-JanitorConfig -ErrorAction SilentlyContinue
        if ($saveCfg) { try { & $saveCfg -Config $script:Config } catch { } }
        $script:TxtStatus.Text = 'Settings saved'
    })

    $script:Render = {
        $script:FindingsPanel.Children.Clear()
        $script:BtnExportCsv.IsEnabled = ($script:AllFindings.Count -gt 0)
        if ($script:AllFindings.Count -eq 0) {
            $script:TxtEmpty.Visibility = 'Visible'
            $script:FindingsScroll.Visibility = 'Collapsed'
            return
        }
        $script:TxtEmpty.Visibility = 'Collapsed'
        $script:FindingsScroll.Visibility = 'Visible'
        $groups = $script:AllFindings | Group-Object -Property Category | Sort-Object Name
        foreach ($g in $groups) {
            $script:FindingsPanel.Children.Add((New-CategoryExpander -Category $g.Name -Findings $g.Group)) | Out-Null
        }
        & $script:OnSelectionChanged
    }

    $script:SetBusy = {
        param([bool]$Busy, [string]$Status)
        $script:BtnScan.IsEnabled = -not $Busy
        $script:BtnAdvToggle.IsEnabled = -not $Busy
        if (-not $Busy) {
            # Inlined, not Get-SelectedFindings(...) - calling that named function from here
            # (reached via a DispatcherTimer.Tick delegate, not normal script flow) reproduced a
            # StrictMode 'Count' PropertyNotFoundException that bypassed a try/catch wrapped
            # directly around the call. Verified fixed by inlining. See Get-SelectedFindings's
            # own comment above for the full diagnosis.
            $selected = @($script:AllFindings | Where-Object { $_.Action -ne 'Report' -and $_.Selected })
            $script:BtnDryRun.IsEnabled = ($selected.Count -gt 0)
            $script:BtnClean.IsEnabled  = ($selected.Count -gt 0)
            $script:BtnExportCsv.IsEnabled = ($script:AllFindings.Count -gt 0)
        } else {
            $script:BtnDryRun.IsEnabled = $false
            $script:BtnClean.IsEnabled = $false
            $script:BtnExportCsv.IsEnabled = $false
        }
        $script:ProgressPanel.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
        $script:TxtStatus.Text = $Status
        if ($Busy) { $script:ProgressBar.Value = 0; $script:TxtCurPath.Text = '' }
    }

    $script:BtnScan.Add_Click({
        $script:ResultPanel.Visibility = 'Collapsed'
        & $script:SetBusy $true 'Scanning...'

        $onProgress = {
            param($p)
            $script:ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$p.PercentComplete))
            $script:TxtCurPath.Text = "$($p.Stage): $($p.CurrentPath)"
        }

        $onDone = {
            param($findings)
            $minBytes = [long]$script:Config.MinSizeMB * 1MB
            $excl = @($script:Config.Exclusions)
            $filtered = @($findings | Where-Object {
                if ($_.Bytes -lt $minBytes) { return $false }
                if ($excl.Count -eq 0) { return $true }
                $allExcluded = $true
                foreach ($p in $_.Paths) {
                    $hit = $false
                    foreach ($e in $excl) { if ($p -ilike "$e*") { $hit = $true; break } }
                    if (-not $hit) { $allExcluded = $false; break }
                }
                -not $allExcluded
            })
            $script:AllFindings = $filtered
            & $script:Render
            & $script:SetBusy $false 'Scan complete'
        }

        $onError = {
            param($msg)
            & $script:SetBusy $false 'Scan failed'
            Show-ConfirmDialog -Owner $script:Win -Title 'Drive Janitor' -Message "Scan failed:`n$msg" -Buttons OK -Icon Error | Out-Null
        }

        Invoke-InBackgroundRunspace -FunctionName 'Invoke-AllScans' `
            -Arguments @{ Roots = @($script:Config.Roots); IncludeDuplicates = [bool]$script:Config.FindDuplicates } `
            -OnProgress $onProgress -OnDone $onDone -OnError $onError
    })

    $script:BtnDryRun.Add_Click({
        $selected = @($script:AllFindings | Where-Object { $_.Action -ne 'Report' -and $_.Selected })
        if ($selected.Count -eq 0) {
            Show-ConfirmDialog -Owner $script:Win -Title 'Drive Janitor' -Message 'Nothing selected.' -Buttons OK | Out-Null
            return
        }
        $paths = @($selected | ForEach-Object { $_.Paths } | Where-Object { $_ })
        $total = ($selected | Measure-Object -Property Bytes -Sum).Sum
        Show-PathListModal -Owner $script:Win -Title 'Dry run - paths that would be removed' -Paths $paths `
            -SummaryLine "$($paths.Count) path(s), $(Format-Size $total) total. Nothing has been touched."
    })

    $script:BtnClean.Add_Click({
        $selected = @($script:AllFindings | Where-Object { $_.Action -ne 'Report' -and $_.Selected })
        if ($selected.Count -eq 0) {
            Show-ConfirmDialog -Owner $script:Win -Title 'Drive Janitor' -Message 'Nothing selected.' -Buttons OK | Out-Null
            return
        }
        $total = ($selected | Measure-Object -Property Bytes -Sum).Sum
        $advCount = @($selected | Where-Object { $_.Risk -eq 'Advanced' }).Count
        $msg = "This will permanently remove $(Format-Size $total) across $($selected.Count) item(s)," + `
               " including $advCount Advanced-risk item(s). This cannot be undone.`n`nContinue?"

        # Built inline (not via the reusable Show-ConfirmDialog) so the Yes handler sits at the
        # exact same closure depth as the working Scan flow - routing the post-confirm action
        # through a second function's Tag/Closed-event indirection was observed to lose $script:
        # scope resolution on this host (verified via isolated logging: $script:ResultPanel read
        # as $null only through that path, never through a direct one-hop click handler).
        $confirmWin = New-Object System.Windows.Window
        $confirmWin.Title = 'Confirm clean'
        $confirmWin.SizeToContent = 'WidthAndHeight'
        $confirmWin.MinWidth = 360
        $confirmWin.Owner = $script:Win
        $confirmWin.WindowStartupLocation = 'CenterOwner'
        $confirmWin.WindowStyle = 'ToolWindow'
        $confirmWin.ResizeMode = 'NoResize'

        $confirmPanel = New-Object System.Windows.Controls.StackPanel
        $confirmPanel.Margin = 18
        $confirmMsgBlock = New-Object System.Windows.Controls.TextBlock
        $confirmMsgBlock.Text = $msg
        $confirmMsgBlock.TextWrapping = 'Wrap'
        $confirmMsgBlock.MaxWidth = 420
        $confirmMsgBlock.Foreground = '#B36B00'
        $confirmPanel.Children.Add($confirmMsgBlock) | Out-Null

        $confirmBtnRow = New-Object System.Windows.Controls.StackPanel
        $confirmBtnRow.Orientation = 'Horizontal'
        $confirmBtnRow.HorizontalAlignment = 'Right'
        $confirmBtnRow.Margin = '0,16,0,0'

        $yesBtn = New-Object System.Windows.Controls.Button
        $yesBtn.Content = 'Yes'; $yesBtn.Padding = '18,6'; $yesBtn.Margin = '0,0,8,0'
        $yesBtn.Add_Click({ $confirmWin.Close() }.GetNewClosure())
        $confirmBtnRow.Children.Add($yesBtn) | Out-Null

        $noBtn = New-Object System.Windows.Controls.Button
        $noBtn.Content = 'No'; $noBtn.Padding = '18,6'
        $noBtn.Add_Click({ $confirmWin.Tag = 'cancelled'; $confirmWin.Close() }.GetNewClosure())
        $confirmBtnRow.Children.Add($noBtn) | Out-Null

        $confirmPanel.Children.Add($confirmBtnRow) | Out-Null
        $confirmWin.Content = $confirmPanel
        $confirmWin.ShowDialog() | Out-Null
        if ($confirmWin.Tag -eq 'cancelled') { return }

        $script:ResultPanel.Visibility = 'Collapsed'
        & $script:SetBusy $true 'Cleaning...'

        $onProgress = {
            param($p)
            $script:ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, [int]$p.PercentComplete))
            $script:TxtCurPath.Text = "$($p.CurrentPath)"
        }

        $onDone = {
            param($resultArr)
            $result = $resultArr | Select-Object -Last 1
            & $script:SetBusy $false 'Clean complete'
            Show-CleanResult -ResultContent $script:ResultContent -ResultPanel $script:ResultPanel -Result $result
            $script:AllFindings = @()
            & $script:Render
        }

        $onError = {
            param($msg)
            & $script:SetBusy $false 'Clean failed'
            Show-ConfirmDialog -Owner $script:Win -Title 'Drive Janitor' -Message "Clean failed:`n$msg" -Buttons OK -Icon Error | Out-Null
        }

        Invoke-InBackgroundRunspace -FunctionName 'Invoke-Clean' `
            -Arguments @{ Findings = @($selected) } `
            -OnProgress $onProgress -OnDone $onDone -OnError $onError
    })

    $script:BtnExportCsv.Add_Click({
        if ($script:AllFindings.Count -eq 0) { return }
        $exportCmd = Get-Command Export-FindingsCsv -ErrorAction SilentlyContinue
        if (-not $exportCmd) {
            Show-ConfirmDialog -Owner $script:Win -Title 'Drive Janitor' -Message 'CSV export is unavailable in this build.' -Buttons OK -Icon Error | Out-Null
            return
        }
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dlg.FileName = "drive-janitor-findings-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $ok = $dlg.ShowDialog($script:Win)
        if (-not $ok) { return }
        try {
            & $exportCmd -Findings @($script:AllFindings) -Path $dlg.FileName
            $script:TxtStatus.Text = "Exported to $($dlg.FileName)"
        } catch {
            Show-ConfirmDialog -Owner $script:Win -Title 'Drive Janitor' -Message "Export failed:`n$_" -Buttons OK -Icon Error | Out-Null
        }
    })

    & $script:Render
    $script:Win.ShowDialog() | Out-Null
}

function Show-CleanResult {
    param($ResultContent, $ResultPanel, $Result)

    $ResultContent.Children.Clear()
    if (-not $Result) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = 'Clean finished but returned no result object.'
        $ResultContent.Children.Add($t) | Out-Null
        $ResultPanel.Visibility = 'Visible'
        return
    }

    $predicted = [long]$Result.Predicted
    $actual = [long]$Result.ActualPathBytes
    $pctOff = if ($predicted -gt 0) { [math]::Round((([math]::Abs($actual - $predicted)) / $predicted) * 100, 1) } else { 0 }
    $withinTarget = ($pctOff -le 5)

    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = 'Clean complete'
    $head.FontWeight = 'Bold'
    $head.FontSize = 15
    $head.Margin = '0,0,0,6'
    $ResultContent.Children.Add($head) | Out-Null

    $headline = New-Object System.Windows.Controls.TextBlock
    $headline.Text = "Reclaimed: $(Format-Size $actual)  (predicted $(Format-Size $predicted), off by $pctOff% $(if ($withinTarget) { '- within target' } else { '- outside 5% target' }))"
    $headline.FontWeight = 'SemiBold'
    $headline.FontSize = 13
    $headline.Foreground = if ($withinTarget) { '#2E7D32' } else { '#B36B00' }
    $headline.Margin = '0,0,0,4'
    $ResultContent.Children.Add($headline) | Out-Null

    if ($Result.ActualDriveDeltaBytes) {
        foreach ($k in $Result.ActualDriveDeltaBytes.Keys) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = "$k free-space delta: $(Format-Size $Result.ActualDriveDeltaBytes[$k])  (approximate - other processes write to disk during a multi-minute clean; not the pass/fail number)"
            $t.Foreground = '#777777'
            $t.FontSize = 11.5
            $t.TextWrapping = 'Wrap'
            $ResultContent.Children.Add($t) | Out-Null
        }
    }

    $counts = New-Object System.Windows.Controls.TextBlock
    $counts.Margin = '0,8,0,0'
    $counts.Text = "Cleaned: $(@($Result.Cleaned).Count)   Skipped: $(@($Result.Skipped).Count)   Blocked: $(@($Result.Blocked).Count)   Errors: $(@($Result.Errors).Count)"
    $counts.FontWeight = 'SemiBold'
    $ResultContent.Children.Add($counts) | Out-Null

    foreach ($section in @('Skipped', 'Blocked', 'Errors')) {
        $items = @($Result.$section)
        if ($items.Count -eq 0) { continue }
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "$section ($($items.Count)):"
        $lbl.Margin = '0,6,0,2'
        $lbl.FontWeight = 'SemiBold'
        $ResultContent.Children.Add($lbl) | Out-Null
        $lb = New-Object System.Windows.Controls.ListBox
        $lb.MaxHeight = 100
        $lb.FontFamily = 'Consolas'
        $lb.FontSize = 11
        $lb.ItemsSource = @($items | ForEach-Object {
            if ($_ -is [hashtable] -and $_.ContainsKey('Path')) { "$($_.Path) - $($_.Message)" }
            elseif ($_.PSObject.Properties['Path']) { "$($_.Path) - $($_.Message)" }
            else { [string]$_ }
        })
        $ResultContent.Children.Add($lb) | Out-Null
    }

    $ResultPanel.Visibility = 'Visible'
}

