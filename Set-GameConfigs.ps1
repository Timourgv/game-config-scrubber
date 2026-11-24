#Requires -Version 7.0
<#
.SYNOPSIS
    Backs up and scrubs game config files: disables MotionBlur, DepthOfField,
    ChromaticAberration, FilmGrain and Vignette, and enforces a 3440x1440
    default resolution across every installed game.

.DESCRIPTION
    Scans the standard PC-gaming config roots ("Documents\My Games" and
    %LOCALAPPDATA%, plus %APPDATA% with -IncludeRoaming) for .ini / .cfg files
    containing known graphics and resolution keys, and edits them in place:

        MotionBlur*, DepthOfField*, ChromaticAberration*, FilmGrain*,
        Vignette*   ->  0 (or False for boolean-style keys)
        ResolutionSizeX / ResolutionSizeY, LastUserConfirmedResSizeX / Y,
        ResX / ResY ->  3440 x 1440  (overridable with -Width / -Height)

    Safety model:
      * A default run is a DRY RUN: it only reports what would change.
        Pass -Apply to actually modify files.
      * Before any file is written, it is copied into a timestamped run
        folder under -BackupRoot, together with a manifest.json that lets
        -Restore roll the whole run back.
      * Only exact known key names (plus any -ExtraDisableKeys regexes) are
        touched. Untouched lines, comments, encoding, BOM and line endings
        are preserved byte-for-byte (files without a BOM are round-tripped
        as ISO-8859-1 so even ANSI configs survive untouched bytes intact).
      * -WhatIf / -Confirm are supported (requires -Apply).
      * The default -ExcludePattern skips noisy non-game folders, including
        "Packages" (UWP). UWP game configs live under
        %LOCALAPPDATA%\Packages\<Game>\LocalState: pass your own
        -ExcludePattern to include them.

    Keys are matched case-insensitively at line start, before '='. Lines
    inside sections like [/Script/Engine.GameUserSettings] are handled the
    same way. Files are never re-parsed with a generic INI parser, so
    duplicated keys, odd spacing and inline comments all survive.

.PARAMETER Apply
        Actually write the changes (default is dry-run).

.PARAMETER AddMissing
        In Unreal-style files that already matched, append missing
        well-known keys: ResolutionSizeX/Y + LastUserConfirmedResSizeX/Y into
        [/Script/Engine.GameUserSettings], and r.MotionBlurQuality=0,
        r.DepthOfFieldQuality=0, r.SceneColorFringeQuality=0 into
        [SystemSettings]. Keys are only inserted into sections that already
        exist in the file; nothing is appended to arbitrary files.

.PARAMETER IncludeRoaming
        Also scan %APPDATA% (Roaming).

.PARAMETER ScanRoots
        Override the default roots entirely (e.g. also Steam's folder).

.PARAMETER ExtraDisableKeys
        Additional regexes matched against key names, e.g. '^r_MotionBlur$'.

.PARAMETER Width / Height
        Resolution to enforce. Default 3440 x 1440.

.PARAMETER BackupRoot
        Where timestamped backup runs are stored.
        Default: <Documents>\GameConfigBackups

.PARAMETER ExcludePattern
        Regex of folder names to skip while scanning.

.PARAMETER MaxFileSizeKB
        Skip config files larger than this. Default 2048.

.PARAMETER Restore / RestoreRun / ListBackups
        Undo a run (-Restore = latest, -RestoreRun = specific) or list runs.

.EXAMPLE
    # 1. Dry run: see everything that would change, no writes at all
    pwsh -File .\Set-GameConfigs.ps1

.EXAMPLE
    # 2. Backup + apply after a fresh install
    pwsh -File .\Set-GameConfigs.ps1 -Apply

.EXAMPLE
    # 3. Custom resolution, extra game-specific key, append missing UE keys
    pwsh -File .\Set-GameConfigs.ps1 -Apply -AddMissing -Width 2560 -Height 1440 -ExtraDisableKeys '^r_MotionBlur$'

.EXAMPLE
    # 4. Change your mind
    pwsh -File .\Set-GameConfigs.ps1 -ListBackups
    pwsh -File .\Set-GameConfigs.ps1 -Restore
    pwsh -File .\Set-GameConfigs.ps1 -RestoreRun 2026-11-24_18-30-05
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [switch]$Apply,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$AddMissing,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$IncludeRoaming,

    [Parameter(ParameterSetName = 'Run')]
    [string[]]$ScanRoots,

    [Parameter(ParameterSetName = 'Run')]
    [string[]]$ExtraDisableKeys,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 32767)]
    [int]$Width = 3440,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 32767)]
    [int]$Height = 1440,

    [Parameter()]
    [string]$BackupRoot = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GameConfigBackups'),

    [Parameter()]
    [string]$ExcludePattern = '(?i)[\\/](Microsoft|Package Cache|Packages|Temp|Tmp|Cache|Caches|D3DSCache|NVIDIA|AMD|Intel|Google|Chrome|Mozilla|Firefox|pip|Python|npm|node_modules|SquirrelTemp|Docker)(?:[\\/]|$)',

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 1048576)]
    [int]$MaxFileSizeKB = 2048,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$Restore,

    [Parameter(ParameterSetName = 'Restore')]
    [string]$RestoreRun,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListBackups
)

# ---------------------------------------------------------------------------
# Key tables
# ---------------------------------------------------------------------------

# Keys whose presence marks a file as a gameplay-graphics config worth editing.
# All matched case-insensitively, anchored to the full key name.
$defaultDisable = @(
    'b(?:Use)?(?:MotionBlur|DepthOfField|ChromaticAberration|FilmGrain|Vignette)(?:Quality|Amount|Intensity|Strength|Scale|Enabled|Factor|Power)?'
    '(?:MotionBlur|DepthOfField|ChromaticAberration|FilmGrain|Vignette)(?:Quality|Amount|Intensity|Strength|Scale|Enabled|Factor|Power)?'
    'r\.(?:MotionBlur|DepthOfField)Quality'
    'r\.SceneColorFringeQuality'
)
$allDisable = if ($ExtraDisableKeys) { $defaultDisable + $ExtraDisableKeys } else { $defaultDisable }
$DisableRegex = '^(?:' + ($allDisable -join '|') + ')$'

# Resolution keys -> forced values (PowerShell hashtables are case-insensitive).
$ResMap = @{
    'ResolutionSizeX'           = "$Width"
    'ResolutionSizeY'           = "$Height"
    'LastUserConfirmedResSizeX' = "$Width"
    'LastUserConfirmedResSizeY' = "$Height"
    'ResX'                      = "$Width"
    'ResY'                      = "$Height"
}
$ResKeyPattern = ($ResMap.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'

# One precompiled test for "does this file contain anything we manage?"
$HitRegex = [regex]::new(
    "(?im)^[ \t]*(?:$DisableRegex|$ResKeyPattern)[ \t]*=",
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::Multiline
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Read a config file preserving its encoding for a faithful write-back.
function Read-ConfigFile {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $enc; $offset = 0
    if     ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = [System.Text.Encoding]::Unicode;          $offset = 2 }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = [System.Text.Encoding]::BigEndianUnicode; $offset = 2 }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = [System.Text.UTF8Encoding]::new($true); $offset = 3 }
    else { $enc = [System.Text.Encoding]::Latin1 }   # 1:1 byte round-trip, no corruption of ANSI configs
    $text = $enc.GetString($bytes, $offset, $bytes.Length - $offset)
    [pscustomobject]@{ Text = $text; Encoding = $enc }
}

function Get-DisabledValue {
    param([string]$Key, [string]$OldValue)
    if ($OldValue -match '^(?i)(true|on|enabled|yes)$')    { return 'False' }
    if ($OldValue -match '^(?i)(false|off|disabled|no)$')  { return 'False' }
    return '0'
}

# Line-preserving edit pass. Returns new text + human-readable change records.
function Edit-ConfigText {
    param([string]$Text)
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
        if ($key -match $DisableRegex)       { $newVal = Get-DisabledValue $key $val }
        elseif ($ResMap.ContainsKey($key))   { $newVal = $ResMap[$key] }
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

        $wantGs = [ordered]@{
            'ResolutionSizeX'            = "$Width"
            'ResolutionSizeY'            = "$Height"
            'LastUserConfirmedResSizeX'  = "$Width"
            'LastUserConfirmedResSizeY'  = "$Height"
        }
        if ($gs -ge 0) {
            $missing = foreach ($name in @($wantGs.Keys)) {
                $present = $false
                foreach ($l in $list) { if ($l -match ('^[ \t]*' + [regex]::Escape($name) + '[ \t]*=')) { $present = $true; break } }
                if (-not $present) { $name }
            }
            $missing = @($missing)
            if ($missing.Count -gt 0) {
                $list.Insert($gs + 1, "; added by Set-GameConfigs.ps1 $stamp")
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
                $list.Insert($ss + 1, "; added by Set-GameConfigs.ps1 $stamp")
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

# ---------------------------------------------------------------------------
# Backup listing / restore
# ---------------------------------------------------------------------------

function Get-BackupRuns {
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }
    @(Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending)
}

function Show-BackupRuns {
    $runs = Get-BackupRuns
    if (-not $runs) { Write-Host "No backup runs found in '$BackupRoot'." -ForegroundColor Yellow; return }
    $rows = foreach ($r in $runs) {
        $mf = Join-Path $r.FullName 'manifest.json'
        $n = if (Test-Path -LiteralPath $mf) { @((Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).files).Count } else { 0 }
        [pscustomobject]@{ Run = $r.Name; Files = $n }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

function Invoke-RestoreRun {
    $runs = Get-BackupRuns
    if (-not $runs) { Write-Host "No backup runs found in '$BackupRoot'." -ForegroundColor Yellow; return }
    $dir = if ($RestoreRun) { $runs | Where-Object Name -eq $RestoreRun | Select-Object -First 1 } else { $runs[0] }
    if (-not $dir) { Write-Host "No backup run named '$RestoreRun'. Use -ListBackups." -ForegroundColor Red; return }

    $mf = Join-Path $dir.FullName 'manifest.json'
    $files = (Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json).files
    $restored = 0
    foreach ($f in $files) {
        $src = Join-Path $dir.FullName $f.backupRel
        if (-not (Test-Path -LiteralPath $src)) { Write-Host "  missing in backup: $($f.backupRel)" -ForegroundColor Yellow; continue }
        if ($WhatIfPreference) { Write-Host "What if: restoring $($f.target)"; continue }
        $dstDir = Split-Path -Parent $f.target
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $f.target -Force
        $restored++
    }
    Write-Host "Restored $restored file(s) from run '$($dir.Name)'." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($ListBackups) { Show-BackupRuns; return }
if ($Restore)     { Invoke-RestoreRun; return }

# --- pick scan roots ------------------------------------------------------
if ($ScanRoots) {
    $roots = @($ScanRoots)
} else {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $roots = @()
    $myGames = Join-Path $docs 'My Games'
    if (Test-Path -LiteralPath $myGames)     { $roots += $myGames }
    if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath $env:LOCALAPPDATA)) { $roots += $env:LOCALAPPDATA }
    if ($IncludeRoaming -and $env:APPDATA -and (Test-Path -LiteralPath $env:APPDATA)) { $roots += $env:APPDATA }
}
$roots = @($roots | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') } | Sort-Object -Unique)
if (-not $roots) { Write-Host "No existing scan roots found." -ForegroundColor Red; return }

Write-Host "== Set-GameConfigs ==" -ForegroundColor Cyan
Write-Host ("Resolution target : {0}x{1}" -f $Width, $Height)
Write-Host ("Backup root       : {0}" -f $BackupRoot)
Write-Host "Scan roots:"
$roots | ForEach-Object { Write-Host "  $_" }

# --- collect config files -------------------------------------------------
Write-Host "Scanning for .ini / .cfg files (this can take a minute on first run)..."
$configFiles = [System.Collections.Generic.List[object]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$maxBytes = $MaxFileSizeKB * 1KB
$backupRootFull = if ($BackupRoot) { [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd('\', '/') } else { $null }

foreach ($root in $roots) {
    $label = Split-Path -Leaf $root
    $items = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.ini', '.cfg' -and $_.Length -le $maxBytes }
    foreach ($it in $items) {
        if (-not $seen.Add($it.FullName)) { continue }
        if ($backupRootFull -and $it.FullName.StartsWith($backupRootFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($ExcludePattern -and $it.FullName -match $ExcludePattern) { continue }
        $configFiles.Add([pscustomobject]@{
            Path = $it.FullName
            Root = $root
            Rel  = $label.Trim('\', '/') + $it.FullName.Substring($root.Length)
        })
    }
}
Write-Host ("Found {0} candidate config files." -f $configFiles.Count)

# --- decide edits ----------------------------------------------------------
$pending = [System.Collections.Generic.List[object]]::new()
$unreadable = 0

foreach ($cf in $configFiles) {
    try {
        $raw = Read-ConfigFile -LiteralPath $cf.Path
    } catch { $unreadable++; continue }
    if ($raw.Text.Contains([char]0)) { continue }          # binary file, skip
    if (-not $HitRegex.IsMatch($raw.Text))  { continue }   # nothing we manage

    $edit = Edit-ConfigText -Text $raw.Text
    if ($edit.Changes.Count -eq 0) { continue }

    $pending.Add([pscustomobject]@{
        Target   = $cf.Path
        BackupRel = $cf.Rel.TrimStart('\', '/')
        NewText  = $edit.Text
        Encoding = $raw.Encoding
        Changes  = $edit.Changes
    })
}

# --- report ----------------------------------------------------------------
if ($pending.Count -eq 0) {
    Write-Host "Nothing to change: all matching configs are already compliant." -ForegroundColor Green
    if ($unreadable) { Write-Host "($unreadable files were unreadable/skipped.)" -ForegroundColor DarkGray }
    return
}

$rows = foreach ($p in $pending) {
    foreach ($c in $p.Changes) {
        [pscustomobject]@{ File = $p.Target; Line = $c.Line; Key = $c.Key; Old = $c.Old; New = $c.New }
    }
}
Write-Host ""
Write-Host ("{0} file(s), {1} change(s):" -f $pending.Count, $rows.Count) -ForegroundColor Cyan
$rows | Format-Table File, Line, Key, Old, New -AutoSize | Out-String -Width 300 | Write-Host

if (-not $Apply) {
    Write-Host "DRY RUN - nothing was written. Re-run with -Apply to backup and apply these changes." -ForegroundColor Yellow
    return
}

# --- backup + write ---------------------------------------------------------
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$runDir = Join-Path $BackupRoot $stamp
$written = [System.Collections.Generic.List[object]]::new()

foreach ($p in $pending) {
    if (-not $PSCmdlet.ShouldProcess($p.Target, "backup + apply config scrub")) { continue }
    try {
        $dest = Join-Path $runDir $p.BackupRel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $p.Target -Destination $dest -Force
        [System.IO.File]::WriteAllText($p.Target, $p.NewText, $p.Encoding)
        $written.Add([ordered]@{ target = $p.Target; backupRel = $p.BackupRel })
        Write-Host ("edited: {0}" -f $p.Target) -ForegroundColor Green
    } catch {
        Write-Host ("FAILED: {0} :: {1}" -f $p.Target, $_.Exception.Message) -ForegroundColor Red
    }
}

if ($written.Count -gt 0) {
    $manifest = [ordered]@{
        run    = $stamp
        width  = $Width
        height = $Height
        files  = @($written)
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding utf8
    $rows | Select-Object @{ n = 'File'; e = { $_.File } }, Line, Key, Old, New |
        Export-Csv -LiteralPath (Join-Path $runDir 'changes.csv') -NoTypeInformation -Encoding utf8
    Write-Host ""
    Write-Host ("Backup of originals: {0}" -f $runDir) -ForegroundColor Cyan
    Write-Host ("Undo anytime with:   pwsh -File .\Set-GameConfigs.ps1 -Restore") -ForegroundColor Cyan
    Write-Host ("{0} file(s) updated." -f $written.Count) -ForegroundColor Green
}
