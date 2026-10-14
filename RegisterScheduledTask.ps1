#------------------------------[ HELP INFO ]-------------------------------

<#
.SYNOPSIS
Registers a Windows scheduled task running the Plex backup, Plex cleanup or USB disk check script.

.DESCRIPTION
Creates (or replaces) a scheduled task that runs one or more of the following scripts (from the same folder as this script) on a weekly schedule:

- Cleanup: PlexCleanup.ps1 (default task name 'Plex Cleanup', every week on Sunday at 06:00)
- Backup: PlexBackup.ps1 (default task name 'Plex Backup', every week on Sunday at 06:00)
- CheckUsbDisks: CheckUsbDisks.ps1 (default task name 'Check USB Disks', every 4 weeks on Saturday at 06:00)

The default times are after Plex's default maintenance window (02:00-05:00, see Settings > Scheduled Tasks in Plex), so that the scripts do not wait for (or interrupt) Plex maintenance tasks.

If several scripts are specified, the task runs them one after another, in the specified order (e.g. 'Cleanup,Backup' cleans up Plex and then backs it up), so they never stop or start Plex Media Server at the same time. The defaults of the first script apply.

The task runs as the current user, with highest privileges, and only when the user is logged on: Plex Media Server and Docker Desktop run in the user's desktop session, so the scripts must run there, too, to restart them. The console window is minimized.

The task has no time limit (backups and disk checks can take hours). If the computer is off at the scheduled time, the run is skipped until the next scheduled time (so that it does not stop Plex in the middle of the day).

The script must run as Administrator (as the user running Plex Media Server).

.PARAMETER Task
Scripts to run: Cleanup, Backup, CheckUsbDisks (one or more, in the order to run them). Not needed with -Unregister if TaskName is specified.

.PARAMETER TaskName
Name of the scheduled task. Default: depends on the scripts (see above).

.PARAMETER DriveLetter
Drive letters of the volumes to check (passed to CheckUsbDisks.ps1). Default: all volumes on USB disks.

.PARAMETER ScriptArguments
Additional arguments passed to the script, e.g. '-Inactive' for PlexBackup.ps1 or '-SkipDocker' for CheckUsbDisks.ps1. Only allowed with a single script.

.PARAMETER DaysOfWeek
Days of the week to run the task on. Default: depends on the scripts (see above).

.PARAMETER WeeksInterval
Run the task every this many weeks. Default: depends on the scripts (see above).

.PARAMETER At
Time of day to run the task. Default: depends on the scripts (see above).

.PARAMETER Unregister
Removes the scheduled task.

.EXAMPLE
.\RegisterScheduledTask.ps1 -Task Cleanup,Backup
Cleans up and then backs up Plex every week on Sunday at 06:00 (task 'Plex Cleanup + Plex Backup').

.EXAMPLE
.\RegisterScheduledTask.ps1 -Task CheckUsbDisks -DriveLetter E,F,G
Checks drives E:, F: and G: every 4 weeks on Saturday at 06:00.

.EXAMPLE
.\RegisterScheduledTask.ps1 -Task CheckUsbDisks -DriveLetter H -TaskName "Check USB Disk H" -DaysOfWeek Wednesday
Checks drive H: every 4 weeks on Wednesday at 06:00 (in a separate task).

.EXAMPLE
.\RegisterScheduledTask.ps1 -Task Cleanup,Backup -Unregister
Removes the 'Plex Cleanup + Plex Backup' scheduled task.
#>

#------------------------------[ PARAMETERS ]------------------------------

[CmdletBinding()]
param (
    [string[]]
    $Task = @(),

    [string]
    $TaskName = $null,

    [string[]]
    $DriveLetter = @(),

    [string]
    $ScriptArguments = "",

    [string[]]
    $DaysOfWeek = @(),

    [ValidateRange(0,52)]
    [int]
    $WeeksInterval = 0,

    [string]
    $At = $null,

    [switch]
    $Unregister
)

#-------------------------------[ CONSTANTS ]------------------------------

# Scripts (in the same folder as this script) and their default schedules.
$SCRIPTS = @{
    Cleanup = @{
        Script        = "PlexCleanup.ps1"
        TaskName      = "Plex Cleanup"
        DaysOfWeek    = @("Sunday")
        WeeksInterval = 1
        At            = "06:00"
    }
    Backup = @{
        Script        = "PlexBackup.ps1"
        TaskName      = "Plex Backup"
        DaysOfWeek    = @("Sunday")
        WeeksInterval = 1
        At            = "06:00"
    }
    CheckUsbDisks = @{
        Script        = "CheckUsbDisks.ps1"
        TaskName      = "Check USB Disks"
        DaysOfWeek    = @("Saturday")
        WeeksInterval = 4
        At            = "06:00"
    }
}

#-------------------------------[ FUNCTIONS ]------------------------------

#--------------------------------------------------------------------------
# SplitList
#   Splits lists like 'E,F,G' ('powershell -File' passes them as a single string).
function SplitList {
    param (
        [string[]]
        $values
    )

    return @($values -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

#---------------------------------[ MAIN ]---------------------------------

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())

if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "The script must run as Administrator."
    exit 1
}

$Task        = SplitList $Task
$DriveLetter = SplitList $DriveLetter
$DaysOfWeek  = SplitList $DaysOfWeek

if (($Task.Count -eq 0) -and !($Unregister -and $TaskName)) {
    Write-Error "Specify the scripts to run via -Task (use: $($SCRIPTS.Keys -join ', '))."
    exit 1
}

foreach ($name in $Task) {
    if (!$SCRIPTS.ContainsKey($name)) {
        Write-Error "Unknown task '$name' (use: $($SCRIPTS.Keys -join ', '))."
        exit 1
    }
}

# Use the canonical spelling (hashtable keys are case-insensitive).
$Task = @($Task | ForEach-Object { $key = $_; $SCRIPTS.Keys | Where-Object { $_ -eq $key } })

if (($Task.Count -gt 1) -and $ScriptArguments) {
    Write-Error "ScriptArguments can only be used with a single task."
    exit 1
}

if ($DriveLetter.Count -gt 0 -and ("CheckUsbDisks" -notin $Task)) {
    Write-Error "DriveLetter can only be used with the CheckUsbDisks task."
    exit 1
}

if (!$TaskName) {
    $TaskName = ($Task | ForEach-Object { $SCRIPTS[$_].TaskName }) -join " + "
}

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'."
    } else {
        Write-Host "Scheduled task '$TaskName' does not exist."
    }

    exit 0
}

$defaults = $SCRIPTS[$Task[0]]

if ($DaysOfWeek.Count -eq 0) {
    $DaysOfWeek = $defaults.DaysOfWeek
}

if ($WeeksInterval -eq 0) {
    $WeeksInterval = $defaults.WeeksInterval
}

if (!$At) {
    $At = $defaults.At
}

try {
    $days = @($DaysOfWeek | ForEach-Object { [DayOfWeek]$_ })
    $time = [datetime]$At
}
catch {
    Write-Error "Invalid schedule: $($_.Exception.Message)"
    exit 1
}

# One action per script: Task Scheduler runs them one after another.
$actions = @()
$commands = @()

foreach ($name in $Task) {
    $scriptPath = Join-Path $PSScriptRoot $SCRIPTS[$name].Script

    if (!(Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Error "Script '$scriptPath' does not exist."
        exit 1
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$scriptPath`""

    if (($name -eq "CheckUsbDisks") -and ($DriveLetter.Count -gt 0)) {
        $arguments += " -DriveLetter $($DriveLetter -join ',')"
    }

    if ($ScriptArguments) {
        $arguments += " $ScriptArguments"
    }

    $actions += New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments `
        -WorkingDirectory $env:SystemRoot

    $commands += "powershell.exe $arguments"
}

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval $WeeksInterval -DaysOfWeek $days -At $time

# Interactive: run in the user's desktop session (where Plex and Docker Desktop run).
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

# No time limit: backups and disk checks can take hours.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

$description = "Runs $(($Task | ForEach-Object { $SCRIPTS[$_].Script }) -join ', then ') from '$PSScriptRoot'."

try {
    $null = Register-ScheduledTask -TaskName $TaskName -Description $description `
        -Action $actions -Trigger $trigger -Principal $taskPrincipal -Settings $settings `
        -Force -ErrorAction Stop
}
catch {
    Write-Error "Cannot register scheduled task '$TaskName': $($_.Exception.Message)"
    exit 1
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName

Write-Host "Registered scheduled task '$TaskName'."
Write-Host "  User:     $user (only when logged on, with highest privileges)"
Write-Host "  Schedule: every $WeeksInterval week(s) on $($days -join ', ') at $($time.ToString('HH:mm'))"
Write-Host "  Commands:"
$commands | ForEach-Object { Write-Host "    $_" }
Write-Host "  Next run: $($info.NextRunTime)"
Write-Host "Done."
