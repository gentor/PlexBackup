# Check USB disks

The [CheckUsbDisks.ps1](../CheckUsbDisks.ps1) script checks and repairs the file systems of external USB disks (such as the disks holding Plex libraries or backups) with `chkdsk /F`. Because `chkdsk /F` needs exclusive access to a volume, the script stops the apps using the disks first and starts them again when the checks are done.

## What it does

1. Finds every volume (with a drive letter) on the USB disks. The system drive is never checked, and only `NTFS`, `FAT`, `FAT32` and `exFAT` volumes are supported.
2. Finds the apps using these volumes:
    - processes started from a volume or referencing it in their command line,
    - processes holding open files on a volume (requires [Sysinternals Handle](https://learn.microsoft.com/en-us/sysinternals/downloads/handle), see below),
    - services installed on a volume,
    - processes and services listed in the `Processes` and `Services` parameters (`Plex Media Server` by default, so that Plex does not scan the libraries while they are offline),
    - Docker containers with bind mounts (or bind volumes) on a volume,
    - WSL distributions and Docker Desktop disk images stored on a volume (see [Docker and WSL](#docker-and-wsl)).
3. Waits until Plex Media Server has no running tasks (such as a library scan or database optimization) and nobody is watching anything, so that Plex is not interrupted in the middle of a task (see [Waiting for Plex](#waiting-for-plex)).
4. Stops these apps: Docker containers via `docker stop`, services (along with the services depending on them) via the Service Control Manager, processes gracefully first and forcefully after `TimeoutSeconds`.
5. Runs `chkdsk <drive>: /F /X` for each volume, one at a time.
6. Starts the stopped apps and Docker containers again (even if a check fails), and reports the result of each check.

Notes:

- Windows does not tell USB 2 and USB 3 disks apart, so all USB disks are checked. Use the `DriveLetter` parameter to check specific volumes only.
- The `/X` switch forces the volume to dismount before the check. This closes the files kept open by apps the script does not stop: system processes (such as Explorer, Windows Search, Windows Defender or driver hosts like `WUDFHost.exe`; in general, any process started from the Windows folder unless it is listed in `Processes`) and apps it did not detect.
- Processes are restarted with the same command line, as a non-elevated user (the same way PlexBackup restarts Plex). Processes run by other users are stopped, but not restarted. Child processes (such as Plex Transcoder) are not restarted on their own; their parent apps start them as needed.
- Checking a large disk can take a long time (hours if it has bad sectors), and the apps stay stopped until all checks finish.

## Waiting for Plex

Before stopping Plex Media Server, the script checks the local Plex API (`http://127.0.0.1:32400`) every 30 seconds until Plex has no running activities (scans, media analysis, thumbnail generation, database optimization and so on) and no playback sessions. If Plex is still busy after `PlexIdleTimeoutMinutes` (60 by default), the script exits with an error **without stopping or checking anything**, so try again later, or use `-PlexIdleTimeoutMinutes 0` to stop Plex without waiting.

The Plex token is read from the registry (as in [Plex cleanup](PLEX%20CLEANUP.md)), so run the script as the user running Plex Media Server. If the script cannot reach Plex, it prints a warning and goes on.

Plex is then stopped gracefully (the same way as with __Exit__ in its tray menu). Only if it is still running after `TimeoutSeconds` is it killed, and the script prints a warning (also in the log file).

## Docker and WSL

Docker containers run in a Linux VM, so Windows does not show which files they use. The script asks Docker instead (the `docker` command must be available, which it is with Docker Desktop):

- Containers with bind mounts on a checked volume (e.g. `H:\Media:/media` in a compose file) are stopped with `docker stop` before the checks and started with `docker start` after them. Other containers keep running.
- If the disk image of a WSL distribution or of Docker Desktop (__Settings__ > __Resources__ > __Advanced__ > __Disk image location__) is stored on a checked volume, the VM itself uses the disk, and a forced dismount could corrupt it (along with the data of every container). In this case, the script stops all running containers, quits Docker Desktop and shuts down WSL (`wsl --shutdown`, which stops all WSL distributions). After the checks, it starts Docker Desktop, waits for the Docker engine (up to 5 minutes) and starts the containers it stopped. Other WSL distributions start the next time you use them.

Use the `SkipDocker` switch to leave Docker and WSL alone (only if no disk image is stored on the checked volumes).

## Sysinternals Handle

Without [Handle](https://learn.microsoft.com/en-us/sysinternals/downloads/handle), the script cannot see which processes have files open on the disks (e.g. a media player playing a video from the disk).

If `handle64.exe` (`handle64a.exe` on ARM, `handle.exe` on 32-bit Windows) is not in the script folder or in `PATH`, the script downloads it from `https://download.sysinternals.com/files/Handle.zip` (even with `-WhatIf`), checks that it has a valid Microsoft signature and saves it in the script folder, so the download happens only once. By downloading it, you accept the [Sysinternals license](https://learn.microsoft.com/en-us/sysinternals/license-terms). To use a copy from somewhere else, pass its location via the `HandlePath` parameter. If the download fails (e.g. no internet access), the script works without the tool, but prints a warning.

## Usage

The script must run as Administrator. The easiest way is to double-click [RunCheckUsbDisks.bat](../RunCheckUsbDisks.bat): it asks for elevation, runs the script (bypassing the PowerShell execution policy) and keeps the window open at the end. Any arguments are passed to the script, e.g. `RunCheckUsbDisks.bat -WhatIf`.

Preview the volumes that would be checked and the apps that would be stopped (nothing is changed):

```PowerShell
powershell -ExecutionPolicy Bypass -File .\CheckUsbDisks.ps1 -WhatIf
```

Check all USB volumes:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\CheckUsbDisks.ps1
```

Check drives `H:` and `I:` only, and also stop qBittorrent:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\CheckUsbDisks.ps1 -DriveLetter H,I -Processes "Plex Media Server,qbittorrent"
```

## Scheduled check

To run the check on a schedule, register a scheduled task with [RegisterScheduledTask.bat](../RegisterScheduledTask.bat) (see [Scheduled tasks](SCHEDULED%20TASKS.md)):

```
RegisterScheduledTask.bat -Task CheckUsbDisks -DriveLetter E,F,G
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `DriveLetter` | All volumes on USB disks | Drive letters of the volumes to check |
| `Processes` | `Plex Media Server` | Names of the processes (without `.exe`) to stop even if they do not appear to use the volumes |
| `Services` | | Names of the services to stop even if they do not appear to use the volumes |
| `HandlePath` | `handle64.exe` from the script folder or `PATH`, downloaded if missing | Sysinternals Handle tool |
| `TimeoutSeconds` | `60` | Maximum time to wait for the apps (and Docker containers) to exit gracefully before they are killed |
| `PlexUrl` | `http://127.0.0.1:32400` | Local Plex Media Server address |
| `PlexToken` | Read from the registry | Plex authentication token |
| `PlexIdleTimeoutMinutes` | `60` | Maximum time to wait for Plex to finish its tasks and playback sessions (`0`: do not wait) |
| `SkipDocker` | | Do not stop Docker containers, Docker Desktop or WSL |
| `NoRestart` | | Do not start the stopped apps after the checks |
| `LogFile` | `Logs\CheckUsbDisks_<date>_<time>.log` in the script folder | Log file receiving all script output |
| `NoLog` | | Do not write a log file |
| `WhatIf` | | Show what would be done without changing anything |
| `Verbose` | | Show additional details |

## Log files

Everything the script prints (including the `chkdsk` output for each volume) is also saved to a log file: `Logs\CheckUsbDisks_<date>_<time>.log` in the script folder (a new file for every run). Use the `LogFile` parameter to save it elsewhere, or the `NoLog` switch to skip it. No log file is written with `-WhatIf`.

The log file must not be on a checked volume (it is dismounted during the check). If it would be, the script saves it in `C:\ProgramData\CheckUsbDisks\Logs` instead (the console and the end of the log show where it went).

## Exit codes

The script exits with code `0` if every volume was checked successfully (the `chkdsk` exit codes `0` (no errors), `1` (errors fixed) or `2` (cleanup performed)), and with code `1` otherwise (e.g. `chkdsk` exit code `3`: the volume could not be checked or errors could not be fixed).
