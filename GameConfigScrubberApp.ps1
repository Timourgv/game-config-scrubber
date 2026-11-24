#Requires -Version 7.0
<#
.SYNOPSIS
    Game Config Scrubber - a small WPF app that backs up and scrubs game
    config files: disables MotionBlur, DepthOfField, ChromaticAberration,
    FilmGrain and Vignette, and enforces a 3440x1440 default resolution.

.DESCRIPTION
    A GUI wrapper around the same engine as Set-GameConfigs.ps1 (the CLI
    version). One window, no dependencies beyond PowerShell 7 on Windows.

    * Pick which effects to disable (all five on by default)
    * Pick the resolution to enforce (3440x1440 by default)
    * Scan "Documents\My Games", %LOCALAPPDATA%, %APPDATA% and/or custom
      folders (e.g. the Steam userdata folder, a second drive's profile...)
    * Preview every change in a table BEFORE anything is written
    * Apply copies every original to a timestamped backup run first,
      then edits the files; a manifest.json + changes.csv land in the run
      folder. This is the same backup format as the CLI, so you can list /
      restore GUI runs with the CLI and vice versa.
    * Restore any previous run from the dropdown.

    Usage:
        pwsh -File .\GameConfigScrubberApp.ps1
        pwsh -File .\GameConfigScrubberApp.ps1 -BackupRoot D:\CfgBackups

    If your execution policy blocks scripts:
        pwsh -ExecutionPolicy Bypass -File .\GameConfigScrubberApp.ps1

    Technical notes:
      * The window runs on a dedicated STA thread (pwsh console threads are
        MTA, which WPF file dialogs do not tolerate).
      * Scans run on a background runspace with a DispatcherTimer polling
        for completion, so the window stays responsive; Apply/Restore are
        fast and run inline.
      * Only exact known key names are touched; encoding, BOM and line
        endings of untouched lines are preserved byte-for-byte (BOM-less
        ANSI files are round-tripped as ISO-8859-1 to never corrupt bytes).
#>
param(
    [string]$BackupRoot = ''
)

# ===========================================================================
# 1. Core library (shared logic; injected into background scan runspaces too)
# ===========================================================================
$CoreDef = @'
function Read-ConfigFile {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $enc = $null; $offset = 0
    if     ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode;          $offset = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [System.Text.Encoding]::BigEndianUnicode; $offset = 2 }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = [System.Text.UTF8Encoding]::new($true); $offset = 3 }
    else { $enc = [System.Text.Encoding]::Latin1 }   # 1:1 byte round-trip for ANSI configs
    $text = $enc.GetString($bytes, $offset, $bytes.Length - $offset)
    [pscustomobject]@{ Text = $text; Encoding = $enc }
}

function Get-DisabledValue {
    param([string]$OldValue)
    if ($OldValue -match '^(?i)(true|on|enabled|yes)$')    { return 'False' }
    if ($OldValue -match '^(?i)(false|off|disabled|no)$') { return 'False' }
    return '0'
}

function ConvertTo-DisableRegex {
    param([string[]]$Effects, [string[]]$ExtraKeys)
    $suffix = '(?:Quality|Amount|Intensity|Strength|Scale|Enabled|Factor|Power)?'
    $cvar = @{
        'MotionBlur'          = 'r\.MotionBlurQuality'
        'DepthOfField'        = 'r\.DepthOfFieldQuality'
        'ChromaticAberration' = 'r\.SceneColorFringeQuality'
        'FilmGrain'           = $null
        'Vignette'            = $null
    }
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Effects) {
        $all.Add("b(?:Use)?$e$suffix")
        $all.Add("$e$suffix")
        if ($cvar[$e]) { $all.Add([string]$cvar[$e]) }
    }
    if ($ExtraKeys) { foreach ($k in $ExtraKeys) { $all.Add($k) } }
    '^(?:' + ($all -join '|') + ')$'
}

function New-ResolutionMap {
    param([int]$Width, [int]$Height)
    @{
        'ResolutionSizeX'           = "$Width"
        'ResolutionSizeY'           = "$Height"
        'LastUserConfirmedResSizeX' = "$Width"
        'LastUserConfirmedResSizeY' = "$Height"
        'ResX'                      = "$Width"
        'ResY'                      = "$Height"
    }
}

function New-HitRegex {
    param([string]$DisableRegex, [hashtable]$ResMap)
    $inner = $DisableRegex.Trim('^', '$')
    if ($ResMap -and $ResMap.Count -gt 0) {
        $resPattern = ($ResMap.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $inner = "$inner|$resPattern"
    }
    [regex]::new("(?im)^[ \t]*(?:$inner)[ \t]*=")
}

function Edit-ConfigText {
    param(
        [string]$Text,
        [string]$DisableRegex,
        [hashtable]$ResMap,
        [bool]$AddMissing,
        [int]$Width,
        [int]$Height
    )
    $changes = [System.Collections.Generic.List[object]]::new()

    $nl = if ($Text -match "`r`n") { "`r`n" } elseif ($Text -match "`n") { "`n" } else { "`r`n" }
    $lines = [regex]::Split($Text, '\r?\n')

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^[ \t]*(?<key>[^=;#\[\]]+?)[ \t]*=(?<rest>.*)$')
        if (-not $m.Success) { continue }

        $key = $m.Groups['key'].Value.Trim()
        $rest = $m.Groups['rest'].Value

        # keep an inline " ; comment" (or " # comment") if present
        $cm = [regex]::Match($rest, '^(?<val>.*?)(?<com>[ \t]+[;#].*)?$')
        $val = $cm.Groups['val'].Value.Trim()
        $com = $cm.Groups['com'].Value

        $newVal = $null
        if ($key -match $DisableRegex)      { $newVal = Get-DisabledValue $val }
        elseif ($ResMap.ContainsKey($key))  { $newVal = [string]$ResMap[$key] }
        if ($null -eq $newVal -or $newVal -eq $val) { continue }

        $indent = [regex]::Match($lines[$i], '^[ \t]*').Value
        $lines[$i] = "$indent$key=$newVal$com"
        $changes.Add([pscustomobject]@{ Line = $i + 1; Key = $key; Old = $val; New = $newVal })
    }

    # -AddMissing: insert well-known UE keys only into sections that exist.
    if ($AddMissing) {
        $list = [System.Collections.Generic.List[string]]::new()
        $list.AddRange([string[]]$lines)
        $stamp = (Get-Date).ToString('yyyy-MM-dd')

        $gs = -1; $ss = -1
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($gs -lt 0 -and $list[$i] -match '^[ \t]*\[/Script/Engine\.GameUserSettings\][ \t]*$') { $gs = $i }
            if ($ss -lt 0 -and $list[$i] -match '^[ \t]*\[SystemSettings\][ \t]*$')                  { $ss = $i }
        }

        if ($gs -ge 0) {
            $wantGs = [ordered]@{
                'ResolutionSizeX'           = "$Width"
                'ResolutionSizeY'           = "$Height"
                'LastUserConfirmedResSizeX' = "$Width"
                'LastUserConfirmedResSizeY' = "$Height"
            }
            $missing = foreach ($name in @($wantGs.Keys)) {
                $present = $false
                foreach ($l in $list) { if ($l -match ('^[ \t]*' + [regex]::Escape($name) + '[ \t]*=')) { $present = $true; break } }
                if (-not $present) { $name }
            }
            $missing = @($missing)
            if ($missing.Count -gt 0) {
                $list.Insert($gs + 1, "; added by GameConfigScrubber $stamp")
                $idx = $gs + 1
                foreach ($name in $missing) {
                    $idx++
                    $list.Insert($idx, "$name=$($wantGs[$name])")
                    $changes.Add([pscustomobject]@{ Line = $idx + 1; Key = $name; Old = '(absent)'; New = $wantGs[$name] })
                }
            }
        }

        if ($ss -ge 0) {
            $wantSs = [ordered]@{
                'r.MotionBlurQuality'       = '0'
                'r.DepthOfFieldQuality'     = '0'
                'r.SceneColorFringeQuality' = '0'
            }
            $missing = foreach ($name in @($wantSs.Keys)) {
                $present = $false
                foreach ($l in $list) { if ($l -match ('^[ \t]*' + [regex]::Escape($name) + '[ \t]*=')) { $present = $true; break } }
                if (-not $present) { $name }
            }
            $missing = @($missing)
            if ($missing.Count -gt 0) {
                $list.Insert($ss + 1, "; added by GameConfigScrubber $stamp")
                $idx = $ss + 1
                foreach ($name in $missing) {
                    $idx++
                    $list.Insert($idx, "$name=$($wantSs[$name])")
                    $changes.Add([pscustomobject]@{ Line = $idx + 1; Key = $name; Old = '(absent)'; New = $wantSs[$name] })
                }
            }
        }

        $lines = $list.ToArray()
    }

    [pscustomobject]@{ Text = ($lines -join $nl); Changes = $changes }
}
'@

# ===========================================================================
# 2. Background scan job (CoreDef gets injected at the token line)
# ===========================================================================
$ScanBody = @'
param($Request)
#CORE_FUNCTIONS#

$DisableRegex = ConvertTo-DisableRegex -Effects $Request.Effects -ExtraKeys $Request.ExtraDisableKeys
$ResMap = if ($Request.EnforceRes) { New-ResolutionMap -Width $Request.Width -Height $Request.Height } else { @{} }
$HitRegex = New-HitRegex -DisableRegex $DisableRegex -ResMap $ResMap

$configFiles = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$maxBytes = $Request.MaxFileSizeKB * 1KB
$backupRootFull = if ($Request.BackupRoot) { [System.IO.Path]::GetFullPath($Request.BackupRoot).TrimEnd('\', '/') } else { $null }
$rootErrors = [System.Collections.Generic.List[string]]::new()

foreach ($root in $Request.Roots) {
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { $rootErrors.Add($rootFull); continue }
    $label = Split-Path -Leaf $rootFull
    $items = Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue
    foreach ($it in $items) {
        if ($it.Extension -ne '.ini' -and $it.Extension -ne '.cfg') { continue }
        if ($it.Length -gt $maxBytes) { continue }
        if (-not $seen.Add($it.FullName)) { continue }
        if ($backupRootFull -and $it.FullName.StartsWith($backupRootFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($Request.ExcludePattern -and $it.FullName -match $Request.ExcludePattern) { continue }
        $rel = $it.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        $configFiles.Add([pscustomobject]@{ Path = $it.FullName; Label = $label; Rel = $rel })
    }
}

$pending = [System.Collections.Generic.List[object]]::new()
$unreadable = 0
foreach ($cf in $configFiles) {
    try { $raw = Read-ConfigFile -LiteralPath $cf.Path } catch { $unreadable++; continue }
    if ($raw.Text.Contains([char]0)) { continue }         # binary file
    if (-not $HitRegex.IsMatch($raw.Text)) { continue }   # nothing we manage
    $edit = Edit-ConfigText -Text $raw.Text -DisableRegex $DisableRegex -ResMap $ResMap -AddMissing $Request.AddMissing -Width $Request.Width -Height $Request.Height
    if (-not $edit.Changes -or $edit.Changes.Count -eq 0) { continue }
    $pending.Add([pscustomobject]@{
        Target    = $cf.Path
        BackupRel = ($cf.Label + '/' + $cf.Rel)
        NewText   = $edit.Text
        Encoding  = $raw.Encoding
        Changes   = $edit.Changes
    })
}

[pscustomobject]@{
    Pending    = $pending
    Scanned    = $configFiles.Count
    Unreadable = $unreadable
    RootErrors = $rootErrors
}
'@
$ScanJobText = $ScanBody.Replace('#CORE_FUNCTIONS#', $CoreDef)

# ===========================================================================
# 3. WPF window layout
# ===========================================================================
$XamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Game Config Scrubber" Height="700" Width="1000"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <GroupBox Grid.Row="0" Header="Effects to disable / resolution" Padding="8">
      <StackPanel>
        <WrapPanel>
          <CheckBox x:Name="ChkMotionBlur" Content="Motion Blur" IsChecked="True" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkDepthOfField" Content="Depth of Field" IsChecked="True" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkChromaticAberration" Content="Chromatic Aberration" IsChecked="True" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkFilmGrain" Content="Film Grain" IsChecked="True" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkVignette" Content="Vignette" IsChecked="True" Margin="0,0,16,0"/>
        </WrapPanel>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
          <TextBlock Text="Resolution:" VerticalAlignment="Center"/>
          <TextBox x:Name="TxtWidth" Width="70" Text="3440" Margin="8,0,0,0"/>
          <TextBlock Text="x" Margin="6,0,6,0" VerticalAlignment="Center"/>
          <TextBox x:Name="TxtHeight" Width="70" Text="1440"/>
          <CheckBox x:Name="ChkEnforceRes" Content="Enforce" IsChecked="True" Margin="16,0,0,0" VerticalAlignment="Center"/>
          <CheckBox x:Name="ChkAddMissing" Content="Insert missing keys into existing Unreal sections" Margin="24,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
      </StackPanel>
    </GroupBox>

    <GroupBox Grid.Row="1" Header="Scan roots" Padding="8" Margin="0,10,0,0">
      <StackPanel>
        <WrapPanel>
          <CheckBox x:Name="ChkMyGames" Content="Documents\My Games" IsChecked="True" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkLocal" Content="%LOCALAPPDATA%" IsChecked="True" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkRoaming" Content="%APPDATA% (Roaming)" Margin="0,0,16,0"/>
          <CheckBox x:Name="ChkUwp" Content="Scan UWP games (Packages folder)" Margin="0,0,16,0"/>
        </WrapPanel>
        <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
          <TextBox x:Name="TxtCustomRoot" Width="440"/>
          <Button x:Name="BtnBrowse" Content="Browse..." Width="90" Margin="8,0,0,0"/>
          <Button x:Name="BtnAddRoot" Content="Add root" Width="90" Margin="8,0,0,0"/>
        </StackPanel>
        <ListBox x:Name="LstCustomRoots" Height="52" Margin="0,8,0,0"/>
        <Button x:Name="BtnRemoveRoot" Content="Remove selected root" Width="160" HorizontalAlignment="Left" Margin="0,8,0,0"/>
      </StackPanel>
    </GroupBox>

    <DataGrid Grid.Row="2" x:Name="DgChanges" Margin="0,12,0,0" IsReadOnly="True"
              AutoGenerateColumns="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal">
      <DataGrid.Columns>
        <DataGridTextColumn Header="File" Binding="{Binding File}" Width="*"/>
        <DataGridTextColumn Header="Key" Binding="{Binding Key}" Width="220"/>
        <DataGridTextColumn Header="Old" Binding="{Binding Old}" Width="110"/>
        <DataGridTextColumn Header="New" Binding="{Binding New}" Width="110"/>
      </DataGrid.Columns>
    </DataGrid>

    <WrapPanel Grid.Row="3" Margin="0,12,0,0">
      <Button x:Name="BtnScan" Content="Scan for changes" Width="140" Height="32" Margin="0,0,12,0"/>
      <Button x:Name="BtnApply" Content="Apply (backs up first)" Width="180" Height="32" Margin="0,0,12,0"/>
      <Button x:Name="BtnRestore" Content="Restore selected run" Width="160" Height="32" Margin="0,0,12,0"/>
      <ComboBox x:Name="CmbRuns" Width="190" Height="32" Margin="0,0,12,0"/>
      <Button x:Name="BtnOpenBackups" Content="Open backup folder" Width="160" Height="32"/>
    </WrapPanel>

    <TextBlock Grid.Row="4" x:Name="TxtStatus" Margin="0,10,0,0" TextWrapping="Wrap"
               Text="Ready."/>
  </Grid>
</Window>
'@

# ===========================================================================
# 4. App body (executed on a dedicated STA runspace)
# ===========================================================================
$AppBody = @'
param([string]$CoreDef, [string]$XamlText, [string]$BackupRoot, [string]$ScanJobText)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms   # FolderBrowserDialog only

# default backup root: Documents\GameConfigBackups (same as the CLI)
if (-not $BackupRoot) { $BackupRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GameConfigBackups' }
# the scan handler runs on this runspace's script scope
$script:ScanJobText = $ScanJobText

$ExcludeWithUwp    = '(?i)[\\/](Microsoft|Package Cache|Temp|Tmp|Cache|Caches|D3DSCache|NVIDIA|AMD|Intel|Google|Chrome|Mozilla|Firefox|pip|Python|npm|node_modules|SquirrelTemp|Docker|Packages)(?:[\\/]|$)'
$ExcludeWithoutUwp = '(?i)[\\/](Microsoft|Package Cache|Temp|Tmp|Cache|Caches|D3DSCache|NVIDIA|AMD|Intel|Google|Chrome|Mozilla|Firefox|pip|Python|npm|node_modules|SquirrelTemp|Docker)(?:[\\/]|$)'

$window = [Windows.Markup.XamlReader]::Parse($XamlText)

function Get-Ctrl([string]$Name) { $window.FindName($Name) }
function Show-Status([string]$Msg) { (Get-Ctrl 'TxtStatus').Text = $Msg }
function Msg([string]$Text, [string]$Title, [switch]$IsError) {
    $icon = if ($IsError) { [System.Windows.MessageBoxImage]::Error } else { [System.Windows.MessageBoxImage]::Information }
    [System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]::OK, $icon) | Out-Null
}

function Set-Busy([bool]$Busy) {
    $script:Busy = $Busy
    foreach ($n in 'BtnScan','BtnApply','BtnRestore','BtnBrowse','BtnAddRoot','BtnRemoveRoot','BtnOpenBackups') {
        (Get-Ctrl $n).IsEnabled = -not $Busy
    }
    $window.Cursor = if ($Busy) { [System.Windows.Input.Cursors]::Wait } else { [System.Windows.Input.Cursors]::Arrow }
}

$script:Pending    = [System.Collections.Generic.List[object]]::new()
$script:ScanPS     = $null
$script:ScanHandle = $null
$script:ScanTimer  = $null
$script:Busy       = $false

function Refresh-Runs {
    $cmb = Get-Ctrl 'CmbRuns'
    $cmb.Items.Clear()
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return }
    $runs = @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending)
    foreach ($r in $runs) { $null = $cmb.Items.Add($r.Name) }
    if ($runs.Count -gt 0) { $cmb.SelectedIndex = 0 }
}

function New-ScanRequest {
    $roots = [System.Collections.Generic.List[string]]::new()
    if ((Get-Ctrl 'ChkMyGames').IsChecked) { $roots.Add((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games')) }
    if ((Get-Ctrl 'ChkLocal').IsChecked)  { $roots.Add($env:LOCALAPPDATA) }
    if ((Get-Ctrl 'ChkRoaming').IsChecked) { $roots.Add($env:APPDATA) }
    $lst = Get-Ctrl 'LstCustomRoots'
    foreach ($it in $lst.Items) { $roots.Add([string]$it) }

    $w = 0; $h = 0
    if (-not [int]::TryParse((Get-Ctrl 'TxtWidth').Text.Trim(), [ref]$w) -or
        -not [int]::TryParse((Get-Ctrl 'TxtHeight').Text.Trim(), [ref]$h)) {
        throw 'Width and Height must be whole numbers.'
    }
    if ($w -lt 100 -or $h -lt 100) { throw 'Width and Height look wrong.' }
    if (-not $roots.Count) { throw 'Pick at least one scan root.' }

    $effects = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(
        @('ChkMotionBlur', 'MotionBlur'), @('ChkDepthOfField', 'DepthOfField'),
        @('ChkChromaticAberration', 'ChromaticAberration'), @('ChkFilmGrain', 'FilmGrain'),
        @('ChkVignette', 'Vignette'))) {
        if ((Get-Ctrl $pair[0]).IsChecked) { $effects.Add($pair[1]) }
    }
    if (-not $effects.Count) { throw 'Pick at least one effect to disable.' }

    @{
        Roots            = $roots.ToArray()
        Effects          = $effects.ToArray()
        Width            = $w
        Height           = $h
        EnforceRes       = [bool](Get-Ctrl 'ChkEnforceRes').IsChecked
        AddMissing       = [bool](Get-Ctrl 'ChkAddMissing').IsChecked
        ExcludePattern   = if ((Get-Ctrl 'ChkUwp').IsChecked) { $ExcludeWithUwp } else { $ExcludeWithoutUwp }
        BackupRoot       = $BackupRoot
        MaxFileSizeKB    = 2048
        ExtraDisableKeys = $null
    }
}

function Finalize-Scan {
    $result = $null
    try {
        $outputs = $script:ScanPS.EndInvoke($script:ScanHandle)
        $result  = @($outputs)[-1]
        $errCount = $script:ScanPS.Streams.Error.Count
    } catch {
        $result = $null
    }
    try { $script:ScanPS.Runspace.Dispose() } catch {}
    try { $script:ScanPS.Dispose() } catch {}
    $script:ScanPS = $null; $script:ScanHandle = $null

    if ($null -eq $result) {
        Set-Busy $false
        Show-Status 'Scan failed. See the console window for details.'
        Msg 'The scan failed. Run this app from a console (pwsh -File ...) to see the error.', 'Scan failed' -IsError
        return
    }

    $script:Pending = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $result.Pending) { $script:Pending.Add($p) }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $script:Pending) {
        foreach ($c in $p.Changes) {
            $rows.Add([pscustomobject]@{ File = $p.Target; Key = $c.Key; Old = $c.Old; New = $c.New })
        }
    }
    (Get-Ctrl 'DgChanges').ItemsSource = $rows.ToArray()

    $status = '{0} file(s) with {1} pending change(s) ({2} configs scanned, {3} unreadable). Review, then Apply.' -f `
        $script:Pending.Count, $rows.Count, $result.Scanned, $result.Unreadable
    if ($result.RootErrors.Count -gt 0) { $status += '  Skipped missing roots: ' + ($result.RootErrors -join ', ') }
    Show-Status $status
    Set-Busy $false
}

# ---- handlers --------------------------------------------------------------
$btnScan = Get-Ctrl 'BtnScan'
$btnScan.Add_Click({
    try {
        if ($script:Busy) { return }
        $request = New-ScanRequest
        $script:Pending = [System.Collections.Generic.List[object]]::new()
        Set-Busy $true
        Show-Status 'Scanning config files... (a full %LOCALAPPDATA% sweep can take up to a minute)'

        $ps = [powershell]::Create()
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:ScanJobText)      # built by the launcher, passed via script scope
        $null = $ps.AddParameters(@{ Request = $request })
        $script:ScanPS = $ps
        $script:ScanHandle = $ps.BeginInvoke()

        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromMilliseconds(300)
        $timer.Add_Tick({
            param($sender, $e)
            if (-not $script:ScanHandle -or -not $script:ScanHandle.IsCompleted) { return }
            $sender.Stop()
            $script:ScanTimer = $null
            Finalize-Scan
        })
        $script:ScanTimer = $timer
        $timer.Start()
    } catch {
        Set-Busy $false
        Msg $_.Exception.Message, 'Scan' -IsError
    }
})

$btnApply = Get-Ctrl 'BtnApply'
$btnApply.Add_Click({
    try {
        if ($script:Busy) { return }
        if (-not $script:Pending -or $script:Pending.Count -eq 0) {
            Msg 'Nothing to apply. Click "Scan for changes" first - the app only writes what a scan found.' ,'Apply'
            return
        }
        $changeCount = 0
        foreach ($p in $script:Pending) { $changeCount += $p.Changes.Count }
        $answer = [System.Windows.MessageBox]::Show(
            "Apply $changeCount change(s) to $($script:Pending.Count) config file(s)?`n`nEvery original is copied first to:`n$BackupRoot\<timestamp>",
            'Apply changes', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

        Set-Busy $true
        Show-Status 'Applying (backing up first)...'
        $stamp  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
        $runDir = Join-Path $BackupRoot $stamp
        $written = [System.Collections.Generic.List[object]]::new()
        $failed = 0
        $rows = [System.Collections.Generic.List[object]]::new()

        foreach ($p in $script:Pending) {
            try {
                $dest = Join-Path $runDir $p.BackupRel
                $destDir = Split-Path -Parent $dest
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
                Copy-Item -LiteralPath $p.Target -Destination $dest -Force
                [System.IO.File]::WriteAllText($p.Target, $p.NewText, $p.Encoding)
                $written.Add([ordered]@{ target = $p.Target; backupRel = $p.BackupRel })
                foreach ($c in $p.Changes) { $rows.Add([pscustomobject]@{ File = $p.Target; Line = $c.Line; Key = $c.Key; Old = $c.Old; New = $c.New }) }
            } catch { $failed++ }
        }

        if ($written.Count -gt 0) {
            $manifest = [ordered]@{ run = $stamp; width = 0; height = 0; files = @($written) }
            if ((Get-Ctrl 'ChkEnforceRes').IsChecked) { $manifest.width = [int](Get-Ctrl 'TxtWidth').Text; $manifest.height = [int](Get-Ctrl 'TxtHeight').Text }
            $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding utf8
            $rows | Export-Csv -LiteralPath (Join-Path $runDir 'changes.csv') -NoTypeInformation -Encoding utf8
        }

        $script:Pending = [System.Collections.Generic.List[object]]::new()
        (Get-Ctrl 'DgChanges').ItemsSource = $null
        Refresh-Runs
        Set-Busy $false
        if ($failed -gt 0) {
            Show-Status ("Applied to {0} file(s); {1} failed (check the console for reasons)." -f $written.Count, $failed)
        } else {
            Show-Status ("Done: {0} file(s) updated. Backup run: {1}" -f $written.Count, $runDir)
            Msg "Applied to $($written.Count) file(s).`n`nBackup (restore from the dropdown anytime):`n$runDir", 'Applied'
        }
    } catch {
        Set-Busy $false
        Msg $_.Exception.Message, 'Apply' -IsError
    }
})

$btnRestore = Get-Ctrl 'BtnRestore'
$btnRestore.Add_Click({
    try {
        if ($script:Busy) { return }
        $cmb = Get-Ctrl 'CmbRuns'
        $runName = [string]$cmb.SelectedItem
        if (-not $runName) { Msg 'No backup run selected (or none exist yet).', 'Restore'; return }
        $dir = Join-Path $BackupRoot $runName
        $mf = Join-Path $dir 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { Msg "Run '$runName' has no manifest.json.", 'Restore' -IsError; return }
        $files = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).files
        $answer = [System.Windows.MessageBox]::Show(
            "Restore $($files.Count) file(s) from run '$runName'? Current files are overwritten with the backed-up originals.",
            'Restore', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

        Set-Busy $true
        $restored = 0; $missing = 0
        foreach ($f in $files) {
            $src = Join-Path $dir $f.backupRel
            if (-not (Test-Path -LiteralPath $src)) { $missing++; continue }
            $dstDir = Split-Path -Parent $f.target
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $f.target -Force
            $restored++
        }
        Set-Busy $false
        Show-Status ("Restored {0} file(s) from '{1}'{2}" -f $restored, $runName, $(if ($missing) { " ($missing missing in backup)" } else { '' }))
        Msg "Restored $restored file(s) from '$runName'. Rescan to see the new state.", 'Restore'
    } catch {
        Set-Busy $false
        Msg $_.Exception.Message, 'Restore' -IsError
    }
})

$btnBrowse = Get-Ctrl 'BtnBrowse'
$btnBrowse.Add_Click({
    try {
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        $dlg.Description = 'Pick a folder that contains game config files'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            (Get-Ctrl 'TxtCustomRoot').Text = $dlg.SelectedPath
        }
    } catch { Msg $_.Exception.Message, 'Browse' -IsError }
})

$btnAddRoot = Get-Ctrl 'BtnAddRoot'
$btnAddRoot.Add_Click({
    $path = (Get-Ctrl 'TxtCustomRoot').Text.Trim()
    if (-not $path) { return }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Msg "Folder not found: $path", 'Add root' -IsError; return }
    $lst = Get-Ctrl 'LstCustomRoots'
    foreach ($it in $lst.Items) { if ([string]$it -ieq $path) { (Get-Ctrl 'TxtCustomRoot').Text = ''; return } }
    $null = $lst.Items.Add($path)
    (Get-Ctrl 'TxtCustomRoot').Text = ''
    Show-Status "Added extra scan root: $path"
})

$btnRemoveRoot = Get-Ctrl 'BtnRemoveRoot'
$btnRemoveRoot.Add_Click({
    $lst = Get-Ctrl 'LstCustomRoots'
    if ($lst.SelectedItem) { $lst.Items.Remove($lst.SelectedItem) }
})

$btnOpenBackups = Get-Ctrl 'BtnOpenBackups'
$btnOpenBackups.Add_Click({
    if (-not (Test-Path -LiteralPath $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null }
    Invoke-Item -LiteralPath $BackupRoot
})

$window.Add_Closing({
    if ($script:ScanTimer) { $script:ScanTimer.Stop() }
    if ($script:ScanPS) {
        try { $script:ScanPS.Stop() } catch {}
        try { $script:ScanPS.Dispose() } catch {}
        try { $script:ScanPS.Runspace.Dispose() } catch {}
    }
})

# ---- start -----------------------------------------------------------------
Refresh-Runs
Show-Status ("Ready. Pick targets and roots, then click `"Scan for changes`". Backups go to: {0}" -f $BackupRoot)
$null = $window.ShowDialog()
'@

# ===========================================================================
# 5. Launcher: STA runspace, keep the process alive while the window is up
# ===========================================================================
$appPs = [powershell]::Create()
$appPs.Runspace.ApartmentState = 'STA'
$appPs.Runspace.ThreadOptions  = 'ReuseThread'
$null = $appPs.AddScript($AppBody)
$null = $appPs.AddParameter('CoreDef', $CoreDef)
$null = $appPs.AddParameter('XamlText', $XamlText)
$null = $appPs.AddParameter('BackupRoot', $BackupRoot)
$null = $appPs.AddParameter('ScanJobText', $ScanJobText)

# Keep the console thread parked while the window runs; EndInvoke surfaces
# anything the app threw after the window closes.
$async = $appPs.BeginInvoke()
$async.AsyncWaitHandle.WaitOne()

try { $null = $appPs.EndInvoke($async) } catch {
    Write-Host "The app crashed: $($_.Exception.Message)" -ForegroundColor Red
}
foreach ($er in $appPs.Streams.Error) { Write-Host $er.ToString() -ForegroundColor Red }
$appPs.Dispose()

if ($appPs.Streams.Error.Count -gt 0) {
    Write-Host ''
    Read-Host 'Press Enter to close'
}
