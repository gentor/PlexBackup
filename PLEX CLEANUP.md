# Plex cleanup

The [PlexCleanup.ps1](PlexCleanup.ps1) script removes unused and outdated Plex Media Server data to free up disk space (and to make backups smaller). It is independent from the backup script, but it is a good idea to run it right before a backup.

## What it does

The script runs in two phases.

### 1. Maintenance

Requires Plex Media Server to be running. The script calls the local Plex API (`http://127.0.0.1:32400`) to run the same tasks you can start from Plex Web:

| Task | Plex Web equivalent | Effect |
|---|---|---|
| Empty trash (every library) | Library __...__ > __Empty Trash__ | Removes entries for files that no longer exist |
| Clean bundles | __Settings__ > __Troubleshooting__ > __Clean Bundles__ | Deletes posters, artwork and thumbnails of removed items (`Metadata` and `Media` folders) |
| Optimize database | __Settings__ > __Troubleshooting__ > __Optimize Database__ | Compacts the library database |

The script waits for Plex to finish each task (it checks the running Plex activities). If Plex is still busy after `TimeoutMinutes` (60 by default), the script stops without stopping Plex or deleting any files, so the database is never interrupted in the middle of optimization. Note that any other running activity (such as a library scan) also counts as "busy".

The Plex authentication token is read from the `PlexOnlineToken` value under the `HKEY_CURRENT_USER\Software\Plex, Inc.\Plex Media Server` registry key, so run the script as the same user that runs Plex Media Server (or pass the token via the `PlexToken` parameter).

### 2. File cleanup

The script stops Plex Media Server, deletes the following data, and starts Plex again:

| Location (under the Plex app data folder) | Contents |
|---|---|
| `Cache\PhotoTranscoder` | Resized images cache (often the biggest one) |
| `Cache\Transcode` | Leftover transcoder temp files |
| `Updates` | Downloaded Plex installers |
| `Crash Reports` | Crash dumps |
| `Diagnostics` | Diagnostic archives |
| `Plug-in Support\Databases\*.db-YYYY-MM-DD` | Old automatic database backups (the most recent one is kept by default) |

Plex recreates all of these as needed. The script never deletes the `Metadata` and `Media` folders directly (the database references their files; bundle cleanup takes care of them) or the active database files.

At the end, the script reports how much space was freed.

## Usage

Unlike the backup script, the cleanup script does not need to run as Administrator. Run it from PowerShell as the user running Plex Media Server.

The easiest way is to double-click [RunPlexCleanup.bat](RunPlexCleanup.bat): it runs the script (bypassing the PowerShell execution policy) and keeps the window open at the end. Any arguments are passed to the script, e.g. `RunPlexCleanup.bat -WhatIf`.

Preview what will be done (nothing is changed):

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexCleanup.ps1 -WhatIf
```

Run the full cleanup:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexCleanup.ps1
```

Only delete files (skip the Plex maintenance tasks):

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexCleanup.ps1 -SkipMaintenance
```

Only run the maintenance tasks (do not stop Plex):

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexCleanup.ps1 -SkipFiles
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `PlexAppDataDir` | `$env:LOCALAPPDATA\Plex Media Server` | Plex app data folder |
| `PlexServerPath` | Running process path, or `$env:ProgramFiles\Plex\Plex Media Server\Plex Media Server.exe` | Plex Media Server executable (used to restart Plex) |
| `PlexUrl` | `http://127.0.0.1:32400` | Local Plex Media Server address |
| `PlexToken` | Read from the registry | Plex authentication token |
| `KeepDbBackups` | `1` | Number of the most recent automatic database backups to keep per database (`0` deletes all of them) |
| `TimeoutMinutes` | `60` | Maximum time to wait for each maintenance task |
| `SkipMaintenance` | | Skip the maintenance phase |
| `SkipFiles` | | Skip the file cleanup phase (Plex is not stopped) |
| `NoRestart` | | Do not restart Plex after the file cleanup |
| `WhatIf` | | Show what would be done without changing anything |
| `Verbose` | | Show additional details |

If Plex Media Server is not running, the maintenance phase is skipped (with a warning) and only files are cleaned up.

## Keeping Plex clean automatically

To have Plex do most of the maintenance on its own, enable the following options in Plex Web:

- __Settings__ > __Scheduled Tasks__: __Remove old bundles every week__, __Optimize database every week__ and __Remove old cache files every week__
- __Settings__ > __Library__: __Empty trash automatically after every scan__

You can also run the cleanup script on a schedule using Windows Task Scheduler (see [Scheduled Plex backup](SCHEDULED%20PLEX%20BACKUP.md) for the general steps), e.g. right before the scheduled backup.
