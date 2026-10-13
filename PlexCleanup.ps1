#------------------------------[ HELP INFO ]-------------------------------

<#
.SYNOPSIS
Cleans up unused and outdated Plex Media Server data on a Windows system.

.DESCRIPTION
The script runs in two phases:

1. Maintenance (Plex Media Server must be running): empties trash in every library, cleans bundles (orphaned posters, artwork and thumbnails), and optimizes the database. The script waits for Plex to finish each task.

2. File cleanup (Plex Media Server is stopped and then restarted): deletes the contents of the following folders, which Plex recreates on its own:

- Cache\PhotoTranscoder
- Cache\Transcode
- Updates
- Crash Reports
- Diagnostics

It also deletes old automatic database backups (files like 'com.plexapp.plugins.library.db-2026-10-11') from the 'Plug-in Support\Databases' folder, keeping the most recent ones.

The script never touches the Metadata and Media folders directly (bundle cleanup takes care of them) or the active database files.

Use the -WhatIf switch to see what would be removed without changing anything.

.PARAMETER PlexAppDataDir
Path to the Plex app data folder. Default: '$env:LOCALAPPDATA\Plex Media Server'.

.PARAMETER PlexServerPath
Path to the Plex Media Server executable used to restart Plex. Default: path of the running process or '$env:ProgramFiles\Plex\Plex Media Server\Plex Media Server.exe'.

.PARAMETER PlexUrl
Base URL of the local Plex Media Server. Default: 'http://127.0.0.1:32400'.

.PARAMETER PlexToken
Plex authentication token. Default: read from the 'PlexOnlineToken' value of the current user's Plex registry key.

.PARAMETER KeepDbBackups
Number of the most recent automatic database backups to keep for each database. Default: 1.

.PARAMETER TimeoutMinutes
Maximum time to wait for each maintenance task to complete. If it is exceeded, the script stops without touching any files. Default: 60.

.PARAMETER SkipMaintenance
Skips the maintenance phase (empty trash, clean bundles, optimize database).

.PARAMETER SkipFiles
Skips the file cleanup phase (Plex Media Server will not be stopped).

.PARAMETER NoRestart
Does not restart Plex Media Server after the file cleanup.

.EXAMPLE
.\PlexCleanup.ps1 -WhatIf
Shows what would be done without changing anything.

.EXAMPLE
.\PlexCleanup.ps1
Runs maintenance tasks, then stops Plex, deletes unused files and restarts Plex.

.EXAMPLE
.\PlexCleanup.ps1 -SkipMaintenance -KeepDbBackups 0
Only deletes unused files, including all automatic database backups.
#>

#------------------------------[ PARAMETERS ]------------------------------

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]
    $PlexAppDataDir = "$env:LOCALAPPDATA\Plex Media Server",

    [string]
    $PlexServerPath = $null,

    [string]
    $PlexUrl = "http://127.0.0.1:32400",

    [string]
    $PlexToken = $null,

    [ValidateRange(0,[int]::MaxValue)]
    [int]
    $KeepDbBackups = 1,

    [ValidateRange(1,[int]::MaxValue)]
    [int]
    $TimeoutMinutes = 60,

    [switch]
    $SkipMaintenance,

    [switch]
    $SkipFiles,

    [switch]
    $NoRestart
)

#-------------------------------[ CONSTANTS ]------------------------------

# Name of the Plex Media Server process (without the '.exe' extension).
$PLEX_PROCESS_NAME = "Plex Media Server"

# Plex registry key holding the authentication token.
$PLEX_REG_KEY = "HKCU:\Software\Plex, Inc.\Plex Media Server"

# Folders (relative to the Plex app data folder) which contents can be deleted.
$CLEANUP_DIRS = @(
    "Cache\PhotoTranscoder",
    "Cache\Transcode",
    "Updates",
    "Crash Reports",
    "Diagnostics"
)

# Folder holding the Plex databases and their automatic backups.
$DATABASES_DIR = "Plug-in Support\Databases"

# Automatic database backup file name format, e.g. 'xyz.db-2026-10-11'.
$REGEX_DB_BACKUP = '^(.+\.db)-\d{4}-\d{2}-\d{2}$'

#-------------------------------[ FUNCTIONS ]------------------------------

#--------------------------------------------------------------------------
# FormatSize
#   Converts number of bytes to a human-readable string.
function FormatSize {
    param (
        [long]
        $bytes
    )

    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }

    return "$bytes bytes"
}

#--------------------------------------------------------------------------
# GetSize
#   Returns the total size of the files and folders (including subfolders).
function GetSize {
    param (
        [object[]]
        $items
    )

    [long]$size = 0

    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            $size += (Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        } else {
            $size += $item.Length
        }
    }

    return $size
}

#--------------------------------------------------------------------------
# RemoveItems
#   Deletes the specified files and folders and returns their total size.
function RemoveItems {
    param (
        [string]
        $label,

        [object[]]
        $items
    )

    if (!$items -or $items.Count -eq 0) {
        Write-Host "  ${label}: nothing to remove."
        return [long]0
    }

    $size = GetSize $items

    if ($PSCmdlet.ShouldProcess("$label ($($items.Count) item(s), $(FormatSize $size))", "Remove")) {
        foreach ($item in $items) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Cannot remove '$($item.FullName)': $($_.Exception.Message)"
            }
        }

        Write-Host "  ${label}: removed $($items.Count) item(s), $(FormatSize $size)."
    }

    return $size
}

#--------------------------------------------------------------------------
# GetPlexProcess
#   Returns the running Plex Media Server process (if any).
function GetPlexProcess {
    return Get-Process -Name $PLEX_PROCESS_NAME -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

#--------------------------------------------------------------------------
# InvokePlex
#   Calls the local Plex Media Server API and returns the JSON response.
function InvokePlex {
    param (
        [string]
        $path,

        [string]
        $method = "Get"
    )

    $headers = @{ "Accept" = "application/json" }

    if ($Script:PlexToken) {
        $headers["X-Plex-Token"] = $Script:PlexToken
    }

    return Invoke-RestMethod -Uri ($Script:PlexUrl + $path) -Method $method `
        -Headers $headers -ErrorAction Stop
}

#--------------------------------------------------------------------------
# WaitPlexIdle
#   Waits until Plex Media Server has no running activities.
function WaitPlexIdle {
    param (
        [string]
        $task
    )

    $deadline = (Get-Date).AddMinutes($Script:TimeoutMinutes)

    # Give Plex a moment to register the new activity.
    Start-Sleep -Seconds 5

    while ($true) {
        $activities = @((InvokePlex "/activities").MediaContainer.Activity |
            Where-Object { $_ })

        if ($activities.Count -eq 0) {
            return
        }

        $titles = ($activities | ForEach-Object {
            "$($_.title) ($($_.progress)%)"
        }) -join ", "

        if ((Get-Date) -gt $deadline) {
            throw "Timed out waiting for '$task' to complete. Still running: $titles."
        }

        Write-Host "    Waiting: $titles"
        Start-Sleep -Seconds 10
    }
}

#--------------------------------------------------------------------------
# StopPlex
#   Stops Plex Media Server (gracefully first, forcefully if needed).
function StopPlex {
    Write-Host "Stopping Plex Media Server."

    $null = & taskkill.exe /im "$PLEX_PROCESS_NAME.exe" 2>&1

    $timeoutSeconds = 60
    while (($timeoutSeconds -gt 0) -and (GetPlexProcess)) {
        Start-Sleep -Seconds 1
        $timeoutSeconds--
    }

    if (GetPlexProcess) {
        Write-Verbose "Failed to stop Plex Media Server gracefully; killing it."
        $null = & taskkill.exe /f /t /im "$PLEX_PROCESS_NAME.exe" 2>&1
        Start-Sleep -Seconds 3
    }

    if (GetPlexProcess) {
        throw "Cannot stop Plex Media Server."
    }
}

#--------------------------------------------------------------------------
# StartPlex
#   Starts Plex Media Server (as a non-elevated user).
function StartPlex {
    if (!(Test-Path -LiteralPath $Script:PlexServerPath -PathType Leaf)) {
        Write-Warning "Cannot start Plex Media Server: '$Script:PlexServerPath' does not exist."
        return
    }

    Write-Host "Starting Plex Media Server."

    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())

    # Starting Plex as Administrator messes up share mappings, so drop elevation.
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        runas /trustlevel:0x20000 "$Script:PlexServerPath"
    } else {
        Start-Process -FilePath $Script:PlexServerPath
    }
}

#--------------------------------------------------------------------------
# RunMaintenance
#   Empties library trash, cleans bundles and optimizes the database.
function RunMaintenance {
    if (!$Script:PlexToken) {
        $Script:PlexToken = (Get-ItemProperty -Path $PLEX_REG_KEY -Name PlexOnlineToken `
            -ErrorAction SilentlyContinue).PlexOnlineToken
    }

    if (!$Script:PlexToken) {
        Write-Warning "Plex token not found; trying without it (use -PlexToken if requests fail)."
    }

    Write-Host "Running Plex maintenance tasks."

    $sections = @((InvokePlex "/library/sections").MediaContainer.Directory |
        Where-Object { $_ })

    foreach ($section in $sections) {
        if ($PSCmdlet.ShouldProcess("Library '$($section.title)'", "Empty trash")) {
            Write-Host "  Emptying trash: $($section.title)"
            $null = InvokePlex "/library/sections/$($section.key)/emptyTrash" "Put"
            WaitPlexIdle "Empty trash"
        }
    }

    if ($PSCmdlet.ShouldProcess("Plex library", "Clean bundles")) {
        Write-Host "  Cleaning bundles."
        $null = InvokePlex "/library/clean/bundles?async=1" "Put"
        WaitPlexIdle "Clean bundles"
    }

    if ($PSCmdlet.ShouldProcess("Plex database", "Optimize")) {
        Write-Host "  Optimizing database."
        $null = InvokePlex "/library/optimize?async=1" "Put"
        WaitPlexIdle "Optimize database"
    }
}

#--------------------------------------------------------------------------
# RunFileCleanup
#   Deletes unused files and returns their total size.
function RunFileCleanup {
    [long]$total = 0

    Write-Host "Removing unused files."

    foreach ($dir in $CLEANUP_DIRS) {
        $path = Join-Path $Script:PlexAppDataDir $dir

        if (Test-Path -LiteralPath $path -PathType Container) {
            $total += RemoveItems $dir @(Get-ChildItem -LiteralPath $path -Force)
        }
    }

    $dbPath = Join-Path $Script:PlexAppDataDir $DATABASES_DIR

    if (Test-Path -LiteralPath $dbPath -PathType Container) {
        # Keep the most recent backups of each database (ISO dates sort by name).
        $oldBackups = @(Get-ChildItem -LiteralPath $dbPath -File -Force |
            Where-Object { $_.Name -match $REGEX_DB_BACKUP } |
                Group-Object { $_.Name -replace '-\d{4}-\d{2}-\d{2}$', '' } |
                    ForEach-Object {
                        $_.Group | Sort-Object Name -Descending |
                            Select-Object -Skip $Script:KeepDbBackups
                    })

        $total += RemoveItems "Old database backups" $oldBackups
    }

    return $total
}

#---------------------------------[ MAIN ]---------------------------------

if (!(Test-Path -LiteralPath $PlexAppDataDir -PathType Container)) {
    Write-Error "Plex app data folder '$PlexAppDataDir' does not exist."
    exit 1
}

$plexProcess = GetPlexProcess

if (!$PlexServerPath) {
    if ($plexProcess -and $plexProcess.Path) {
        $PlexServerPath = $plexProcess.Path
    } else {
        $PlexServerPath = Join-Path $env:ProgramFiles "Plex\Plex Media Server\Plex Media Server.exe"
    }
}

Write-Host "Plex app data folder: $PlexAppDataDir"

# Phase 1: maintenance tasks (require running Plex).
if (!$SkipMaintenance) {
    if (!$plexProcess) {
        Write-Warning ("Plex Media Server is not running; skipping maintenance tasks " +
            "(start Plex to run them or use -SkipMaintenance).")
    } else {
        try {
            RunMaintenance
        }
        catch {
            # Do not stop Plex while a maintenance task (e.g. optimize) may still be running.
            Write-Error ("Maintenance failed; no files were removed: $($_.Exception.Message) " +
                "(use -SkipMaintenance to skip this phase).")
            exit 1
        }
    }
}

# Phase 2: file cleanup (requires stopped Plex).
if (!$SkipFiles) {
    $stopped = $false
    $exitCode = 0

    try {
        if ((GetPlexProcess) -and $PSCmdlet.ShouldProcess("Plex Media Server", "Stop")) {
            StopPlex
            $stopped = $true
        }

        $total = RunFileCleanup

        if ($WhatIfPreference) {
            Write-Host "Would free: $(FormatSize $total)."
        } else {
            Write-Host "Freed: $(FormatSize $total)."
        }
    }
    catch {
        Write-Error "File cleanup failed: $($_.Exception.Message)"
        $exitCode = 1
    }
    finally {
        if ($stopped -and !$NoRestart) {
            StartPlex
        }
    }

    if ($exitCode) {
        exit $exitCode
    }
}

Write-Host "Done."
