# Game Config Scrubber

**Stop re-tweaking the same five settings in every game you install.**

Game Config Scrubber scans your PC game configuration folders (`Documents\My Games`, `%LOCALAPPDATA%`, and more), creates a **timestamped backup of every file before touching it**, and then automatically:

- disables **Motion Blur**, **Depth of Field**, **Chromatic Aberration**, **Film Grain** and **Vignette**
- enforces your resolution of choice (defaults to **3440x1440**)

Both a CLI and a desktop GUI are included. They share the same engine and the same backup format, so a run created by one can be restored by the other.

## Contents

| File | What it is |
| ---- | ---- |
| `Set-GameConfigs.ps1` | One-shot CLI utility (dry-run by default) |
| `GameConfigScrubberApp.ps1` | WPF desktop app with a preview table and one-click restore |

## Requirements

- Windows 10/11
- PowerShell 7+ (`pwsh`) — no other dependencies

## Quick start

Clone (or use **Code → Download ZIP**), then preview first — the CLI never writes anything unless you pass `-Apply`:

```powershell
pwsh -ExecutionPolicy Bypass -File .\Set-GameConfigs.ps1        # dry run: full report, zero writes
pwsh -ExecutionPolicy Bypass -File .\Set-GameConfigs.ps1 -Apply # timestamped backup + apply
```

Or launch the app:

```powershell
pwsh -ExecutionPolicy Bypass -File .\GameConfigScrubberApp.ps1
```

The `Bypass` flag only affects that one invocation; your machine-wide policy is unchanged.

## What it edits

Only exact, well-known key names are touched (matched case-insensitively at line start). Everything else is left byte-for-byte alone.

| Category | Keys | New value |
| ---- | ---- | ---- |
| Motion blur | `MotionBlur`, `MotionBlurAmount/Quality/...`, `bMotionBlur`, `r.MotionBlurQuality` | `0` (or `False` for boolean keys) |
| Depth of field | `DepthOfField`, `DepthOfFieldQuality`, `r.DepthOfFieldQuality` | `0` / `False` |
| Chromatic aberration | `ChromaticAberration`, `r.SceneColorFringeQuality` | `0` / `False` |
| Film grain | `FilmGrain`, `FilmGrainIntensity/Quality/...` | `0` / `False` |
| Vignette | `Vignette`, `VignetteIntensity/Strength/...` | `0` / `False` |
| Resolution (UE) | `ResolutionSizeX/Y`, `LastUserConfirmedResSizeX/Y` | 3440x1440 by default |
| Resolution (generic) | `ResX`, `ResY` | 3440x1440 by default |

## Safety model

- **Preview first.** The CLI dry-runs unless you pass `-Apply`; the GUI shows every change in a table before the Apply button writes anything.
- **Backup before write.** Each run copies every original into `Documents\GameConfigBackups\<timestamp>\`, alongside a `manifest.json` (what was changed and where the backups are) and a `changes.csv` (the full change list).
- **One-click restore.** `pwsh -File .\Set-GameConfigs.ps1 -Restore` (or `-RestoreRun <name>`, `-ListBackups`), or the dropdown in the GUI.
- **Byte-safe editing.** Untouched lines, comments, encoding, BOM and line endings are preserved. BOM-less ANSI files are round-tripped as ISO-8859-1 so no byte ever gets corrupted.
- **Known folders skipped.** Antivirus/browser/tool caches that live in the same roots (Microsoft, caches, NVIDIA/AMD, UWP `Packages` unless you opt in...) are excluded from scanning.

## CLI usage

```powershell
# include Roaming configs and a custom root, different resolution
pwsh -File .\Set-GameConfigs.ps1 -IncludeRoaming -ScanRoots D:\Games\Profiles -Width 2560 -Height 1440 -Apply

# teach it a game-specific key name (regex, matched against the key)
pwsh -File .\Set-GameConfigs.ps1 -ExtraDisableKeys '^r_MotionBlur$' -Apply

# insert missing Unreal defaults into existing sections of matching files
pwsh -File .\Set-GameConfigs.ps1 -AddMissing -Apply

# change of heart
pwsh -File .\Set-GameConfigs.ps1 -ListBackups
pwsh -File .\Set-GameConfigs.ps1 -Restore

# standard PowerShell safety switches work too
pwsh -File .\Set-GameConfigs.ps1 -Apply -WhatIf
```

Main parameters: `-Apply`, `-AddMissing`, `-IncludeRoaming`, `-ScanRoots`, `-ExtraDisableKeys`, `-Width`/`-Height`, `-BackupRoot`, `-ExcludePattern`, `-MaxFileSizeKB`, `-Restore`, `-RestoreRun`, `-ListBackups`, and the built-in `-WhatIf`/`-Confirm`.

## GUI walkthrough

1. **Targets** — toggle each effect and set the resolution (all five effects and 3440x1440 are pre-selected).
2. **Scan roots** — `Documents\My Games`, `%LOCALAPPDATA%`, `%APPDATA%`, an opt-in for UWP games (`Packages`), plus any custom folders via Browse/Add.
3. **Scan for changes** — the app sweeps in the background and lists every pending File/Key/Old→New edit.
4. **Apply (backs up first)** — confirmed via dialog, then originals are copied to a new timestamped run and the edits are written.
5. **Restore selected run** — pick any previous run from the dropdown and roll it back.

Closing the window mid-scan cancels the scan cleanly.

## Notes and limitations

- Steam Cloud and some launchers keep their own copy of configs and may re-download over your edits; just re-run after every fresh install — that is exactly the workflow this tool exists for.
- Keys that do not exist yet in a config are only inserted with `-AddMissing`/the GUI checkbox, and only into Unreal sections that already exist in the file.
- Games with exotic key names are not hardcoded: extend with `-ExtraDisableKeys` regexes.
- Run it as the user account that plays the games. No admin rights needed.

## License

[MIT](./LICENSE) — © 2026 Timourgv
