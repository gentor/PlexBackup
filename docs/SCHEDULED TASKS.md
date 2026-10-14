# Scheduled tasks

The [RegisterScheduledTask.ps1](../RegisterScheduledTask.ps1) script creates Windows scheduled tasks running the scripts of this repository:

| Task | Script | Default task name | Default schedule |
|---|---|---|---|
| `Cleanup` | [PlexCleanup.ps1](../PlexCleanup.ps1) ([details](PLEX%20CLEANUP.md)) | `Plex Cleanup` | Every week on Sunday at 06:00 |
| `Backup` | [PlexBackup.ps1](../PlexBackup.ps1) ([details](../README.md)) | `Plex Backup` | Every week on Sunday at 06:00 |
| `CheckUsbDisks` | [CheckUsbDisks.ps1](../CheckUsbDisks.ps1) ([details](CHECK%20USB%20DISKS.md)) | `Check USB Disks` | Every 4 weeks on Saturday at 06:00 |

The default times are after Plex's default maintenance window (02:00-05:00, see __Settings__ > __Scheduled Tasks__ in Plex). `PlexCleanup.ps1` and `CheckUsbDisks.ps1` wait for running Plex tasks to finish before stopping Plex (and give up after a while), so a task scheduled during Plex maintenance (e.g. while it generates video thumbnails) may wait for a long time and then do nothing.

## Usage

Log on as the user running Plex Media Server and double-click [RegisterScheduledTask.bat](../RegisterScheduledTask.bat) with the arguments below (from a command prompt or PowerShell). It asks for elevation and keeps the window open at the end.

A typical setup is two tasks: a weekly cleanup and backup, and a check of the USB disks every 4 weeks:

```
RegisterScheduledTask.bat -Task Cleanup,Backup
RegisterScheduledTask.bat -Task CheckUsbDisks -DriveLetter E,F,G
```

If you specify several scripts, the task runs them one after another, in the specified order, so they never stop or start Plex Media Server at the same time. `Cleanup,Backup` cleans up Plex first, which makes the backup smaller. The task is named after the scripts (`Plex Cleanup + Plex Backup`) and uses the schedule of the first one.

Each script uses its own settings: `PlexBackup.ps1` reads its [config file](../README.md#config-file) (`PlexBackup.ps1.json`). `PlexCleanup.ps1` and `CheckUsbDisks.ps1` write log files to the `Logs` folder next to the scripts; `PlexBackup.ps1` writes one if [logging](../README.md#logging) is enabled (by default, in the backup folder).

Registering a task with the same name again replaces it. Use a different `TaskName` to create several tasks for the same script, e.g. to check a big disk on a different day:

```
RegisterScheduledTask.bat -Task CheckUsbDisks -DriveLetter E,F,G
RegisterScheduledTask.bat -Task CheckUsbDisks -DriveLetter H -TaskName "Check USB Disk H" -DaysOfWeek Wednesday
```

Remove a task:

```
RegisterScheduledTask.bat -Task Cleanup,Backup -Unregister
RegisterScheduledTask.bat -TaskName "Check USB Disk H" -Unregister
```

To pass arguments to a script (only with a single script per task), run the PowerShell script directly from an elevated PowerShell prompt:

```PowerShell
powershell -ExecutionPolicy Bypass -Command "& .\RegisterScheduledTask.ps1 -Task Backup -ScriptArguments '-Inactive'"
```

## Task settings

Every task:

- runs as the current user, with highest privileges, and __only when the user is logged on__: Plex Media Server and Docker Desktop run in the user's desktop session, so the scripts must run there to restart them (see [Scheduled Plex backup](SCHEDULED%20PLEX%20BACKUP.md#issues) for tips on automatic logon),
- shows the script's console window minimized,
- has no time limit (backups and disk checks can take hours),
- is skipped (until the next scheduled time) if the computer is off or the user is logged off at the scheduled time, so that it does not stop Plex in the middle of the day.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `Task` | | Scripts to run: `Cleanup`, `Backup`, `CheckUsbDisks` (one or more, in the order to run them) |
| `TaskName` | Named after the scripts | Name of the scheduled task |
| `DriveLetter` | All volumes on USB disks | Drive letters of the volumes to check (`CheckUsbDisks` only) |
| `ScriptArguments` | | Additional arguments for the script (single script only) |
| `DaysOfWeek` | Depends on the first script | Days of the week to run the task on, e.g. `Saturday,Sunday` |
| `WeeksInterval` | Depends on the first script | Run the task every this many weeks |
| `At` | Depends on the first script | Time of day to run the task, e.g. `02:30` |
| `Unregister` | | Remove the scheduled task |

## Tips

- Do not schedule tasks that stop Plex at overlapping times (all scripts stop it), and keep them out of Plex's own maintenance window (__Settings__ > __Scheduled Tasks__).
- To run a task right away (e.g. to test it), right-click it in Task Scheduler and select __Run__.
- The __Last Run Result__ column in Task Scheduler shows the exit code of the last script the task ran (`0x0` on success).
