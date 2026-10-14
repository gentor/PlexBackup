#------------------------------[ HELP INFO ]-------------------------------

<#
.SYNOPSIS
Checks and repairs the file systems of external USB disks using 'chkdsk /F'.

.DESCRIPTION
The script finds every volume (with a drive letter) on the external USB disks and:

1. Finds the apps using these volumes:

- processes started from a volume or referencing it in their command line,
- processes holding open files on a volume (requires Sysinternals Handle, see the HandlePath parameter),
- services installed on a volume,
- processes and services specified via the Processes (Plex Media Server by default) and Services parameters,
- Docker containers with bind mounts (or volumes) on a volume,
- WSL distributions and Docker Desktop disk images stored on a volume.

2. Waits until Plex Media Server (if it must be stopped) has no running tasks (such as a library scan or database optimization) and no playback sessions, so that it is not interrupted in the middle of a task. If Plex is still busy after PlexIdleTimeoutMinutes, the script exits without stopping or checking anything.

3. Stops these apps (services are stopped along with the services depending on them). If a WSL or Docker Desktop disk image is stored on a volume, the script stops all running Docker containers, quits Docker Desktop and shuts down WSL ('wsl --shutdown').

4. Runs 'chkdsk <drive>: /F /X' for each volume, one at a time.

5. Starts the stopped apps again (even if a check fails), including Docker Desktop and the stopped Docker containers.

Windows does not tell USB 2 and USB 3 disks apart, so all USB disks are checked; use the DriveLetter parameter to pick specific volumes. The system drive is never checked.

Processes are restarted with the same command line, as a non-elevated user. Processes owned by other users are stopped but not restarted. System processes (such as Explorer, Windows Search, Windows Defender, drivers, and any other process started from the Windows folder unless it is listed in the Processes parameter) are never stopped: the /X switch forces the volume to dismount, which closes their open files.

The script must run as Administrator. Use the -WhatIf switch to see what would be done without changing anything.

.PARAMETER DriveLetter
Drive letters of the volumes to check (e.g. 'H', 'I:'). Default: all volumes on USB disks.

.PARAMETER Processes
Names of the processes (without the '.exe' extension) to stop even if they do not appear to use the volumes. Default: 'Plex Media Server' (Plex libraries may live on the USB disks; Plex must not scan them while they are being checked).

.PARAMETER Services
Names of the services to stop even if they do not appear to use the volumes.

.PARAMETER HandlePath
Path to the Sysinternals Handle tool (handle64.exe, handle64a.exe or handle.exe) used to find processes holding open files on the volumes. Default: the tool from the script folder or PATH; if it is not there, the script downloads it from Sysinternals to the script folder (and verifies its Microsoft signature). Without it, only the processes started from the volumes or referencing them in the command line are detected.

.PARAMETER TimeoutSeconds
Maximum time to wait for the apps to exit gracefully before they are killed. Default: 60.

.PARAMETER PlexUrl
Base URL of the local Plex Media Server. Default: 'http://127.0.0.1:32400'.

.PARAMETER PlexToken
Plex authentication token. Default: read from the 'PlexOnlineToken' value of the current user's Plex registry key.

.PARAMETER PlexIdleTimeoutMinutes
Maximum time to wait for Plex Media Server to finish its tasks and playback sessions before stopping it. If it is exceeded, the script exits without stopping or checking anything. Use 0 to stop Plex without waiting. Default: 60.

.PARAMETER SkipDocker
Does not stop Docker containers, Docker Desktop or WSL. Do not use it if a WSL or Docker Desktop disk image is stored on a checked volume: the forced dismount can corrupt it.

.PARAMETER NoRestart
Does not start the stopped apps after the checks.

.PARAMETER LogFile
Path to the log file receiving all script output (including the chkdsk output). Default: 'Logs\CheckUsbDisks_<date>_<time>.log' in the script folder. If the log file would be on a checked volume, the default '$env:ProgramData\CheckUsbDisks\Logs' folder is used instead. No log file is written with -WhatIf.

.PARAMETER NoLog
Does not write a log file.

.EXAMPLE
.\CheckUsbDisks.ps1 -WhatIf
Shows the volumes that would be checked and the apps that would be stopped.

.EXAMPLE
.\CheckUsbDisks.ps1
Stops the apps using the USB disks, checks every USB volume and starts the apps again.

.EXAMPLE
.\CheckUsbDisks.ps1 -DriveLetter H -Processes "Plex Media Server","qbittorrent"
Checks drive H: after stopping Plex Media Server, qBittorrent and the apps using drive H:.
#>

#------------------------------[ PARAMETERS ]------------------------------

[CmdletBinding(SupportsShouldProcess)]
param (
    [string[]]
    $DriveLetter = @(),

    [string[]]
    $Processes = @("Plex Media Server"),

    [string[]]
    $Services = @(),

    [string]
    $HandlePath = $null,

    [ValidateRange(1,[int]::MaxValue)]
    [int]
    $TimeoutSeconds = 60,

    [string]
    $PlexUrl = "http://127.0.0.1:32400",

    [string]
    $PlexToken = $null,

    [ValidateRange(0,[int]::MaxValue)]
    [int]
    $PlexIdleTimeoutMinutes = 60,

    [switch]
    $SkipDocker,

    [switch]
    $NoRestart,

    [string]
    $LogFile = $null,

    [switch]
    $NoLog
)

#-------------------------------[ CONSTANTS ]------------------------------

# File systems supported by chkdsk.
$SUPPORTED_FILE_SYSTEMS = @("NTFS", "FAT", "FAT32", "exFAT")

# Processes that must never be stopped (chkdsk /X closes their open files).
$PROTECTED_PROCESSES = @(
    "System", "Idle", "Registry", "Memory Compression", "Secure System",
    "smss", "csrss", "wininit", "winlogon", "services", "lsass", "LsaIso",
    "svchost", "dwm", "explorer", "sihost", "fontdrvhost", "conhost", "dllhost",
    "RuntimeBroker", "taskhostw", "ctfmon", "audiodg", "WmiPrvSE",
    "SearchIndexer", "SearchProtocolHost", "SearchFilterHost",
    "MsMpEng", "NisSrv", "MpDefenderCoreService", "WUDFHost", "chkdsk",
    "wsl", "wslservice", "wslhost", "wslrelay", "vmmem", "vmmemWSL", "vmwp", "vmcompute"
)

# Name of the Plex Media Server process (without the '.exe' extension).
$PLEX_PROCESS_NAME = "Plex Media Server"

# Plex registry key holding the authentication token.
$PLEX_REG_KEY = "HKCU:\Software\Plex, Inc.\Plex Media Server"

# How often to check whether Plex Media Server is still busy.
$PLEX_IDLE_CHECK_SECONDS = 30

# Docker Desktop processes (stopped via Docker Desktop itself).
$DOCKER_DESKTOP_PROCESS = "Docker Desktop"
$REGEX_DOCKER_PROCESS = '^(Docker Desktop|com\.docker\..+)$'

# Docker Desktop executable used if Docker Desktop is not running at start.
$DOCKER_DESKTOP_PATH = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

# Docker Desktop settings holding the disk image location (newer and older versions).
$DOCKER_SETTINGS_FILES = @(
    "$env:APPDATA\Docker\settings-store.json",
    "$env:APPDATA\Docker\settings.json"
)

# Docker Desktop settings holding disk image folders (WSL 2 and Hyper-V backends).
$DOCKER_DISK_SETTINGS = @("CustomWslDistroDir", "DataFolder")

# Registry key listing the WSL distributions of the current user.
$WSL_REG_KEY = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"

# Maximum time to wait for the Docker engine after starting Docker Desktop.
$DOCKER_START_TIMEOUT_MINUTES = 5

# Sysinternals Handle download.
$HANDLE_URL = "https://download.sysinternals.com/files/Handle.zip"

# Handle executable for this system's architecture.
$HANDLE_EXE = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { "handle64a.exe" }
    "x86"   { "handle.exe" }
    default { "handle64.exe" }
}

# Log file folders: in the script folder, or used if the log would be on a checked volume.
$LOG_DIR          = Join-Path $PSScriptRoot "Logs"
$FALLBACK_LOG_DIR = "$env:ProgramData\CheckUsbDisks\Logs"

# Win32_Service.ProcessId of a stopped service.
$NO_PROCESS = 0

#-------------------------------[ FUNCTIONS ]------------------------------

#--------------------------------------------------------------------------
# IsAdmin
#   Returns true if the script runs as Administrator.
function IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#--------------------------------------------------------------------------
# IsSystemProcess
#   Returns true if the process must never be stopped.
function IsSystemProcess {
    param (
        [object]
        $process
    )

    $name = GetBaseName $process.Name

    if ($name -in $PROTECTED_PROCESSES) {
        return $true
    }

    # Windows components (e.g. driver hosts) are stopped only if explicitly listed.
    $windowsDir = $env:SystemRoot.TrimEnd('\') + '\'

    return ($name -notin $Script:Processes) -and $process.ExecutablePath -and
        $process.ExecutablePath.StartsWith($windowsDir, [StringComparison]::OrdinalIgnoreCase)
}

#--------------------------------------------------------------------------
# GetBaseName
#   Returns the process name without the '.exe' extension.
function GetBaseName {
    param (
        [string]
        $name
    )

    return [IO.Path]::GetFileNameWithoutExtension($name)
}

#--------------------------------------------------------------------------
# ContainsPath
#   Returns true if the text contains the path (case-insensitive).
function ContainsPath {
    param (
        [string]
        $text,

        [string]
        $path
    )

    return $text -and ($text.IndexOf($path, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

#--------------------------------------------------------------------------
# GetVolumes
#   Returns the volumes to check.
function GetVolumes {
    $systemLetter = $env:SystemDrive.TrimEnd(':').ToUpper()

    if ($Script:DriveLetter.Count -gt 0) {
        $volumes = foreach ($letter in $Script:DriveLetter) {
            $letter = $letter.Trim().TrimEnd('\').TrimEnd(':')

            if ($letter -notmatch '^[A-Za-z]$') {
                Write-Warning "Invalid drive letter '$letter'; skipping."
                continue
            }

            $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue

            if (!$volume) {
                Write-Warning "Drive '${letter}:' does not exist; skipping."
                continue
            }

            $volume
        }
    } else {
        $disks = @(Get-Disk | Where-Object {
            ($_.BusType -eq "USB") -and !$_.IsBoot -and !$_.IsSystem -and !$_.IsOffline
        })

        foreach ($disk in $disks) {
            Write-Verbose "USB disk $($disk.Number): $($disk.FriendlyName) ($([math]::Round($disk.Size / 1GB)) GB)."
        }

        if ($disks.Count -eq 0) {
            return
        }

        $volumes = $disks | Get-Partition | Get-Volume -ErrorAction SilentlyContinue
    }

    foreach ($volume in $volumes) {
        $letter = "$($volume.DriveLetter)".ToUpper()

        if ($letter -notmatch '^[A-Z]$') {
            continue
        }

        if ($letter -eq $systemLetter) {
            Write-Warning "Drive '${letter}:' is the system drive; skipping."
            continue
        }

        if ($volume.FileSystem -notin $SUPPORTED_FILE_SYSTEMS) {
            Write-Warning "Drive '${letter}:' has unsupported file system '$($volume.FileSystem)'; skipping."
            continue
        }

        $volume
    }
}

#--------------------------------------------------------------------------
# DownloadHandleExe
#   Downloads the Sysinternals Handle tool to the script folder and returns its path.
function DownloadHandleExe {
    $path    = Join-Path $PSScriptRoot $HANDLE_EXE
    $zipPath = Join-Path $env:TEMP "Handle-$([guid]::NewGuid()).zip"
    $tempDir = Join-Path $env:TEMP "Handle-$([guid]::NewGuid())"

    Write-Host "Downloading Sysinternals Handle from '$HANDLE_URL'."

    try {
        # Windows PowerShell may not enable TLS 1.2 by default.
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # The progress bar slows the download down considerably.
        $progress = $ProgressPreference
        $ProgressPreference = "SilentlyContinue"

        try {
            Invoke-WebRequest -Uri $HANDLE_URL -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        }
        finally {
            $ProgressPreference = $progress
        }

        # The tool is only needed to find apps, so get it even with -WhatIf.
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tempDir -Force -WhatIf:$false -ErrorAction Stop

        $exePath = Join-Path $tempDir $HANDLE_EXE

        if (!(Test-Path -LiteralPath $exePath -PathType Leaf)) {
            throw "'$HANDLE_EXE' not found in the downloaded archive."
        }

        $signature = Get-AuthenticodeSignature -LiteralPath $exePath

        if (($signature.Status -ne "Valid") -or
            ($signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation')) {
            throw "'$HANDLE_EXE' does not have a valid Microsoft signature ($($signature.Status))."
        }

        Copy-Item -LiteralPath $exePath -Destination $path -Force -WhatIf:$false -ErrorAction Stop

        Write-Host "Saved Sysinternals Handle to '$path'."
        return $path
    }
    catch {
        Write-Warning "Cannot download Sysinternals Handle: $($_.Exception.Message)"
        return $null
    }
    finally {
        Remove-Item -LiteralPath $zipPath, $tempDir -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
    }
}

#--------------------------------------------------------------------------
# GetHandleExe
#   Returns the path to the Sysinternals Handle tool (downloads it if needed).
function GetHandleExe {
    if ($Script:HandlePath) {
        if (Test-Path -LiteralPath $Script:HandlePath -PathType Leaf) {
            return $Script:HandlePath
        }

        Write-Warning "Handle tool '$Script:HandlePath' does not exist."
        return $null
    }

    foreach ($name in @($HANDLE_EXE, "handle.exe") | Select-Object -Unique) {
        $path = Join-Path $PSScriptRoot $name

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }

        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1

        if ($command) {
            return $command.Source
        }
    }

    return DownloadHandleExe
}

#--------------------------------------------------------------------------
# GetHandlePids
#   Returns IDs of the processes holding open files on the volume.
function GetHandlePids {
    param (
        [string]
        $handleExe,

        [string]
        $root
    )

    $output = & $handleExe -accepteula -nobanner $root 2>$null

    foreach ($line in $output) {
        if ($line -match '\spid:\s+(\d+)\s') {
            [int]$Matches[1]
        }
    }
}

#--------------------------------------------------------------------------
# GetAncestorPids
#   Returns the IDs of the process and its parents.
function GetAncestorPids {
    param (
        [int]
        $processId,

        [hashtable]
        $processesById
    )

    $ids = @{}

    while ($processId -and !$ids.ContainsKey($processId)) {
        $ids[$processId] = $true

        $process = $processesById[$processId]

        if (!$process) {
            break
        }

        $processId = [int]$process.ParentProcessId
    }

    return $ids
}

#--------------------------------------------------------------------------
# GetArguments
#   Returns the arguments part of a process command line.
function GetArguments {
    param (
        [string]
        $commandLine,

        [string]
        $path
    )

    if (!$commandLine) {
        return ""
    }

    $commandLine = $commandLine.Trim()

    if ($commandLine.StartsWith('"')) {
        $end = $commandLine.IndexOf('"', 1)

        if ($end -lt 0) {
            return ""
        }

        return $commandLine.Substring($end + 1).Trim()
    }

    if ($path -and $commandLine.StartsWith($path, [StringComparison]::OrdinalIgnoreCase)) {
        return $commandLine.Substring($path.Length).Trim()
    }

    $space = $commandLine.IndexOf(' ')

    if ($space -lt 0) {
        return ""
    }

    return $commandLine.Substring($space + 1).Trim()
}

#--------------------------------------------------------------------------
# AddReason
#   Records why an app must be stopped.
function AddReason {
    param (
        [hashtable]
        $reasons,

        [object]
        $key,

        [string]
        $reason
    )

    if (!$reasons.ContainsKey($key)) {
        $reasons[$key] = New-Object Collections.Generic.List[string]
    }

    if (!$reasons[$key].Contains($reason)) {
        $reasons[$key].Add($reason)
    }
}

#--------------------------------------------------------------------------
# GetDriveRegex
#   Returns a regular expression matching paths on the volumes, in Windows and
#   Docker formats, e.g. 'H:\Data', '//h/Data' or '/run/desktop/mnt/host/h/Data'.
function GetDriveRegex {
    param (
        [string[]]
        $letters
    )

    $set = ($letters | ForEach-Object { $_.ToLower() }) -join ''

    return "(?i)^(?:[$set]:(?:[\\/]|$)|(?://|/run/desktop/mnt/host/|/host_mnt/|/mnt/)[$set](?:/|$))"
}

#--------------------------------------------------------------------------
# ConvertFromJsonArray
#   Converts JSON array output of a command to objects.
function ConvertFromJsonArray {
    param (
        [string[]]
        $lines
    )

    $json = ($lines -join "`n") | ConvertFrom-Json

    # Windows PowerShell does not enumerate arrays returned by ConvertFrom-Json.
    return @($json | ForEach-Object { $_ })
}

#--------------------------------------------------------------------------
# GetDockerContainers
#   Returns all running Docker containers (null if Docker is not running).
function GetDockerContainers {
    $ids = @(& $Script:DockerExe ps -q 2>$null)

    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    if ($ids.Count -eq 0) {
        return @()
    }

    $containers = ConvertFromJsonArray (& $Script:DockerExe inspect $ids 2>$null)

    # Volumes created with the 'device' option (e.g. bind volumes) may point to the volumes.
    $volumeNames = @($containers | ForEach-Object { $_.Mounts } |
        Where-Object { ($_.Type -eq "volume") -and $_.Name } |
            ForEach-Object { $_.Name } | Select-Object -Unique)

    $devices = @{}

    if ($volumeNames.Count -gt 0) {
        foreach ($volume in (ConvertFromJsonArray (& $Script:DockerExe volume inspect $volumeNames 2>$null))) {
            if ($volume.Options -and $volume.Options.device) {
                $devices[$volume.Name] = $volume.Options.device
            }
        }
    }

    foreach ($container in $containers) {
        $paths = @(foreach ($mount in $container.Mounts) {
            if ($mount.Type -eq "bind") {
                $mount.Source
            } elseif ($mount.Name -and $devices.ContainsKey($mount.Name)) {
                $devices[$mount.Name]
            }
        })

        [pscustomobject]@{
            Id    = $container.Id
            Name  = $container.Name.TrimStart('/')
            Paths = $paths
        }
    }
}

#--------------------------------------------------------------------------
# GetVirtualDisks
#   Returns the WSL distributions and Docker Desktop disk images on the volumes.
function GetVirtualDisks {
    param (
        [string]
        $driveRegex
    )

    $disks = @()

    foreach ($key in (Get-ChildItem -Path $WSL_REG_KEY -ErrorAction SilentlyContinue)) {
        $distro = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue

        if ($distro.BasePath) {
            $disks += [pscustomobject]@{
                Name = "WSL distribution '$($distro.DistributionName)'"
                Path = $distro.BasePath -replace '^\\\\\?\\', ''
            }
        }
    }

    foreach ($file in $DOCKER_SETTINGS_FILES) {
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) {
            continue
        }

        try {
            $settings = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        }
        catch {
            Write-Verbose "Cannot read '$file': $($_.Exception.Message)"
            continue
        }

        foreach ($name in $DOCKER_DISK_SETTINGS) {
            if ($settings.$name) {
                $disks += [pscustomobject]@{
                    Name = "Docker Desktop disk image"
                    Path = $settings.$name
                }
            }
        }
    }

    return @($disks | Where-Object { $_.Path -match $driveRegex })
}

#--------------------------------------------------------------------------
# StopDockerDesktop
#   Quits Docker Desktop (if running) and shuts down WSL.
function StopDockerDesktop {
    if (Get-Process -Name $DOCKER_DESKTOP_PROCESS -ErrorAction SilentlyContinue) {
        Write-Host "Stopping Docker Desktop."

        if ($Script:DockerExe) {
            $null = & $Script:DockerExe desktop stop 2>&1
        }

        StopProcesses @(Get-Process -Name $DOCKER_DESKTOP_PROCESS -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ ProcessId = $_.Id; Name = "$($_.Name).exe" } })
    }

    Write-Host "Shutting down WSL."
    $null = & wsl.exe --shutdown 2>&1
}

#--------------------------------------------------------------------------
# WaitDocker
#   Waits until the Docker engine responds; returns false on timeout.
function WaitDocker {
    $deadline = (Get-Date).AddMinutes($DOCKER_START_TIMEOUT_MINUTES)

    Write-Host "Waiting for the Docker engine."

    while ((Get-Date) -lt $deadline) {
        $null = & $Script:DockerExe version --format "{{.Server.Version}}" 2>&1

        if ($LASTEXITCODE -eq 0) {
            return $true
        }

        Start-Sleep -Seconds 5
    }

    return $false
}

#--------------------------------------------------------------------------
# InvokePlex
#   Calls the local Plex Media Server API and returns the JSON response.
function InvokePlex {
    param (
        [string]
        $path
    )

    $headers = @{ "Accept" = "application/json" }

    if ($Script:PlexToken) {
        $headers["X-Plex-Token"] = $Script:PlexToken
    }

    return Invoke-RestMethod -Uri ($Script:PlexUrl + $path) -Headers $headers `
        -UseBasicParsing -ErrorAction Stop
}

#--------------------------------------------------------------------------
# GetPlexBusy
#   Returns the descriptions of running Plex activities and playback sessions.
function GetPlexBusy {
    foreach ($activity in @((InvokePlex "/activities").MediaContainer.Activity | Where-Object { $_ })) {
        "$($activity.title) ($($activity.progress)%)"
    }

    foreach ($session in @((InvokePlex "/status/sessions").MediaContainer.Metadata | Where-Object { $_ })) {
        $title = $session.title

        if ($session.grandparentTitle) {
            $title = "$($session.grandparentTitle) - $title"
        }

        "$($session.User.title) playing '$title'"
    }
}

#--------------------------------------------------------------------------
# WaitPlexIdle
#   Waits until Plex Media Server has no running activities or playback
#   sessions; returns false on timeout.
function WaitPlexIdle {
    if (!$Script:PlexToken) {
        $Script:PlexToken = (Get-ItemProperty -Path $PLEX_REG_KEY -Name PlexOnlineToken `
            -ErrorAction SilentlyContinue).PlexOnlineToken
    }

    $deadline = (Get-Date).AddMinutes($Script:PlexIdleTimeoutMinutes)

    while ($true) {
        try {
            $busy = @(GetPlexBusy)
        }
        catch {
            # Do not block the check if Plex cannot tell (it will still be stopped gracefully).
            Write-Warning ("Cannot check whether Plex Media Server is busy (use -PlexToken if " +
                "requests fail): $($_.Exception.Message)")
            return $true
        }

        if ($busy.Count -eq 0) {
            return $true
        }

        $text = $busy -join ", "

        if ((Get-Date) -gt $deadline) {
            Write-Warning "Plex Media Server is still busy: $text."
            return $false
        }

        Write-Host "Waiting for Plex Media Server: $text"
        Start-Sleep -Seconds $PLEX_IDLE_CHECK_SECONDS
    }
}

#--------------------------------------------------------------------------
# ExitScript
#   Stops writing the log file and exits with the specified code.
function ExitScript {
    param (
        [int]
        $code
    )

    if ($Script:logPath) {
        Write-Host "Log file: $Script:logPath"
        $null = Stop-Transcript
    }

    exit $code
}

#--------------------------------------------------------------------------
# StopProcesses
#   Stops the processes (gracefully first, forcefully if needed).
function StopProcesses {
    param (
        [object[]]
        $processes
    )

    # Skip the processes that already exited (e.g. children of the stopped processes).
    $processes = @($processes | Where-Object {
        Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
    })

    if ($processes.Count -eq 0) {
        return
    }

    $remaining = @()

    foreach ($process in $processes) {
        Write-Host "Stopping process: $($process.Name) (PID $($process.ProcessId))."

        $null = & taskkill.exe /pid $process.ProcessId 2>&1

        if ($LASTEXITCODE -eq 0) {
            $remaining += $process
        } else {
            # Console and background processes can only be killed.
            Write-Warning "Cannot stop '$($process.Name)' gracefully; killing it."
            $null = & taskkill.exe /f /pid $process.ProcessId 2>&1
        }
    }

    $deadline = (Get-Date).AddSeconds($Script:TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $remaining = @($remaining | Where-Object {
            Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
        })

        if ($remaining.Count -eq 0) {
            break
        }

        Start-Sleep -Seconds 1
    }

    foreach ($process in $remaining) {
        if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) {
            Write-Warning "Process '$($process.Name)' did not exit in $($Script:TimeoutSeconds) seconds; killing it."
            $null = & taskkill.exe /f /t /pid $process.ProcessId 2>&1
        }
    }

    Start-Sleep -Seconds 3

    foreach ($process in $processes) {
        if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) {
            Write-Warning "Cannot stop process '$($process.Name)' (PID $($process.ProcessId))."
        }
    }
}

#--------------------------------------------------------------------------
# StartProcess
#   Starts the process (as a non-elevated user).
function StartProcess {
    param (
        [object]
        $process
    )

    if (!(Test-Path -LiteralPath $process.Path -PathType Leaf)) {
        Write-Warning "Cannot start '$($process.Name)': '$($process.Path)' does not exist."
        return
    }

    Write-Host "Starting process: $($process.Name)."

    $command = "`"$($process.Path)`""

    if ($process.Arguments) {
        $command += " $($process.Arguments)"
    }

    # Starting apps as Administrator messes up share mappings (and is unsafe), so drop elevation.
    # Runas takes the whole command line as one argument, so escape the embedded quotes.
    $runasArgs = "/trustlevel:0x20000 `"$($command -replace '"', '\"')`""

    try {
        Start-Process -FilePath "runas.exe" -ArgumentList $runasArgs -NoNewWindow `
            -WorkingDirectory (Split-Path -Parent $process.Path) -ErrorAction Stop
    }
    catch {
        Write-Warning "Cannot start '$($process.Name)': $($_.Exception.Message)"
    }
}

#--------------------------------------------------------------------------
# StartLog
#   Starts writing the script output to the log file and returns its path.
function StartLog {
    param (
        [string[]]
        $letters
    )

    $fileName = "CheckUsbDisks_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

    if ($Script:LogFile) {
        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Script:LogFile)
    } else {
        $path = Join-Path $LOG_DIR $fileName
    }

    # The volume is dismounted during the check, so writing the log there would fail.
    if ($path.Substring(0, 1) -in $letters) {
        $fallback = Join-Path $FALLBACK_LOG_DIR $fileName
        Write-Warning "Log file '$path' is on a checked volume; using '$fallback' instead."
        $path = $fallback
    }

    try {
        $dir = Split-Path -Parent $path

        if (!(Test-Path -LiteralPath $dir -PathType Container)) {
            $null = New-Item -Path $dir -ItemType Directory -Force -ErrorAction Stop
        }

        $null = Start-Transcript -LiteralPath $path -Append -ErrorAction Stop
        return $path
    }
    catch {
        Write-Warning "Cannot write log file '$path': $($_.Exception.Message)"
        return $null
    }
}

#--------------------------------------------------------------------------
# CheckVolume
#   Runs chkdsk with the /F switch on the volume and returns its exit code.
function CheckVolume {
    param (
        [string]
        $letter
    )

    Write-Host "Checking drive ${letter}:"

    # /X forces the volume to dismount first, so chkdsk does not ask about it;
    # 'N' declines scheduling the check on restart if the volume cannot be locked.
    "N" | & chkdsk.exe "${letter}:" /F /X | ForEach-Object { Write-Host "  $_" }

    return $LASTEXITCODE
}

#---------------------------------[ MAIN ]---------------------------------

# 'powershell -File' passes lists like 'H,I' as a single string, so split them.
$DriveLetter = @($DriveLetter -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Processes   = @($Processes   -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Services    = @($Services    -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (!(IsAdmin)) {
    Write-Error "The script must run as Administrator."
    exit 1
}

# Load the modules with WhatIf off: otherwise their initialization (creating aliases)
# shows up as 'What if' messages.
$whatIf = $WhatIfPreference
$WhatIfPreference = $false
Import-Module Storage, CimCmdlets
$WhatIfPreference = $whatIf

$volumes = @(GetVolumes)

if ($volumes.Count -eq 0) {
    Write-Host "No USB volumes to check."
    exit 0
}

$logPath = $null

if (!$NoLog -and !$WhatIfPreference) {
    $logPath = StartLog @($volumes | ForEach-Object { "$($_.DriveLetter)" })
}

Write-Host "Volumes to check:"
foreach ($volume in $volumes) {
    Write-Host "  $($volume.DriveLetter): $($volume.FileSystemLabel) ($($volume.FileSystem), $([math]::Round($volume.Size / 1GB)) GB)"
}

# Find the apps using the volumes.
$allProcesses = @(Get-CimInstance -ClassName Win32_Process)
$allServices  = @(Get-CimInstance -ClassName Win32_Service)

$processesById = @{}
foreach ($process in $allProcesses) {
    $processesById[[int]$process.ProcessId] = $process
}

$roots = @($volumes | ForEach-Object { "$($_.DriveLetter):\" })

$processReasons = @{}
$serviceReasons = @{}

foreach ($process in $allProcesses) {
    $name = GetBaseName $process.Name

    if ($name -in $Processes) {
        AddReason $processReasons ([int]$process.ProcessId) "listed in Processes"
    }

    foreach ($root in $roots) {
        if ($process.ExecutablePath -and
            $process.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            AddReason $processReasons ([int]$process.ProcessId) "runs from $root"
        } elseif (ContainsPath $process.CommandLine $root) {
            AddReason $processReasons ([int]$process.ProcessId) "command line references $root"
        }
    }
}

$handleExe = GetHandleExe

if ($handleExe) {
    Write-Verbose "Looking for open files using '$handleExe'."

    foreach ($root in $roots) {
        foreach ($processId in (GetHandlePids $handleExe $root | Select-Object -Unique)) {
            AddReason $processReasons $processId "has open files on $root"
        }
    }
} else {
    Write-Warning ("Sysinternals Handle not found: processes holding open files on the volumes " +
        "will not be detected (put $HANDLE_EXE in the script folder or use -HandlePath).")
}

# Never stop system processes or this script (and its parent processes).
$excludedPids = GetAncestorPids $PID $processesById

foreach ($processId in @($processReasons.Keys)) {
    $process = $processesById[$processId]

    if (!$process) {
        $processReasons.Remove($processId)
        continue
    }

    if ($excludedPids.ContainsKey($processId)) {
        $processReasons.Remove($processId)
    } elseif (IsSystemProcess $process) {
        Write-Verbose ("Not stopping system process '$($process.Name)' (PID $processId, " +
            "$($processReasons[$processId] -join ', ')); chkdsk will close its files.")
        $processReasons.Remove($processId)
    }
}

foreach ($service in $allServices) {
    if ($service.State -ne "Running") {
        continue
    }

    if ($service.Name -in $Services) {
        AddReason $serviceReasons $service.Name "listed in Services"
    }

    foreach ($root in $roots) {
        if (ContainsPath $service.PathName $root) {
            AddReason $serviceReasons $service.Name "installed on $root"
        }
    }

    # Stop a service instead of killing its process.
    $processId = [int]$service.ProcessId

    if (($processId -ne $NO_PROCESS) -and $processReasons.ContainsKey($processId)) {
        foreach ($reason in $processReasons[$processId]) {
            AddReason $serviceReasons $service.Name $reason
        }

        $processReasons.Remove($processId)
    }
}

# Services stopped along with the target services (they must be restarted, too).
$stopServices = New-Object Collections.Generic.List[string]

foreach ($name in $serviceReasons.Keys) {
    if (!$stopServices.Contains($name)) {
        $stopServices.Add($name)
    }
}

foreach ($name in @($stopServices)) {
    foreach ($dependent in (Get-Service -Name $name -ErrorAction SilentlyContinue).DependentServices) {
        if (($dependent.Status -eq "Running") -and !$stopServices.Contains($dependent.Name)) {
            $stopServices.Add($dependent.Name)
            AddReason $serviceReasons $dependent.Name "depends on $name"
        }
    }
}

# Docker containers using the volumes, and WSL/Docker Desktop disk images on them.
$DockerExe = $null
$stopContainers = @()
$virtualDisks = @()
$dockerDesktopPath = $null

if (!$SkipDocker) {
    $driveRegex = GetDriveRegex @($volumes | ForEach-Object { "$($_.DriveLetter)" })

    $command = Get-Command "docker.exe" -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($command) {
        $DockerExe = $command.Source
    }

    $virtualDisks = GetVirtualDisks $driveRegex

    $containers = $null

    if ($DockerExe) {
        $containers = GetDockerContainers
    }

    if ($null -eq $containers) {
        Write-Verbose "No running Docker containers (or Docker is not installed or running)."
        $containers = @()
    }

    $dockerDesktop = Get-Process -Name $DOCKER_DESKTOP_PROCESS -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($dockerDesktop) {
        $dockerDesktopPath = $dockerDesktop.Path

        if (!$dockerDesktopPath) {
            $dockerDesktopPath = $DOCKER_DESKTOP_PATH
        }
    }

    if ($virtualDisks.Count -gt 0) {
        # The whole Docker VM goes down: stop every container (so that it can be restarted,
        # regardless of its restart policy).
        $stopContainers = @($containers | ForEach-Object {
            $_ | Add-Member -NotePropertyName Reason -NotePropertyValue "Docker Desktop and WSL are stopped" -PassThru
        })

        # Docker Desktop and WSL processes are stopped by 'docker desktop stop' and 'wsl --shutdown'.
        foreach ($processId in @($processReasons.Keys)) {
            if ((GetBaseName $processesById[$processId].Name) -match $REGEX_DOCKER_PROCESS) {
                $processReasons.Remove($processId)
            }
        }
    } else {
        $stopContainers = @($containers | ForEach-Object {
            $paths = @($_.Paths | Where-Object { $_ -match $driveRegex })

            if ($paths.Count -gt 0) {
                $_ | Add-Member -NotePropertyName Reason -NotePropertyValue "mounts $($paths -join ', ')" -PassThru
            }
        })
    }
}

# Remember how to restart the processes. Children of other stopped processes (or of the
# stopped services) are not restarted: their parents start them again.
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$parentPids = @{}
foreach ($processId in $processReasons.Keys) {
    $parentPids[$processId] = $true
}

foreach ($service in $allServices) {
    if ($service.Name -in $stopServices) {
        $parentPids[[int]$service.ProcessId] = $true
    }
}

$stopProcesses = @(foreach ($processId in $processReasons.Keys) {
    $process = $processesById[$processId]

    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner `
        -WhatIf:$false -ErrorAction SilentlyContinue
    $ownerName = if ($owner -and $owner.User) { "$($owner.Domain)\$($owner.User)" } else { $null }

    [pscustomobject]@{
        ProcessId = $processId
        Name      = $process.Name
        Path      = $process.ExecutablePath
        Arguments = GetArguments $process.CommandLine $process.ExecutablePath
        Owner     = $ownerName
        IsChild   = $parentPids.ContainsKey([int]$process.ParentProcessId)
    }
})

if (($stopProcesses.Count -eq 0) -and ($stopServices.Count -eq 0) -and
    ($stopContainers.Count -eq 0) -and ($virtualDisks.Count -eq 0)) {
    Write-Host "No apps to stop."
} else {
    Write-Host "Apps to stop:"

    foreach ($disk in $virtualDisks) {
        Write-Host "  Docker Desktop and WSL: $($disk.Name) is stored in $($disk.Path)"
    }

    foreach ($container in $stopContainers) {
        Write-Host "  Docker container $($container.Name): $($container.Reason)"
    }

    foreach ($process in $stopProcesses) {
        Write-Host "  Process $($process.Name) (PID $($process.ProcessId)): $($processReasons[$process.ProcessId] -join ', ')"
    }

    foreach ($name in $stopServices) {
        Write-Host "  Service ${name}: $($serviceReasons[$name] -join ', ')"
    }
}

# Do not interrupt Plex in the middle of a task (e.g. a database optimization) or playback.
$plexToStop = $stopProcesses | Where-Object { (GetBaseName $_.Name) -eq $PLEX_PROCESS_NAME }

if ($plexToStop -and ($PlexIdleTimeoutMinutes -gt 0) -and !$WhatIfPreference) {
    if (!(WaitPlexIdle)) {
        Write-Error ("Plex Media Server is still busy after $PlexIdleTimeoutMinutes minute(s); " +
            "nothing was stopped or checked (use -PlexIdleTimeoutMinutes 0 to stop Plex without waiting).")
        ExitScript 1
    }
}

# Stop the apps, check the volumes, start the apps.
$stoppedProcesses  = @()
$stoppedServices   = @()
$stoppedContainers = @()
$stoppedDocker     = $false
$results = @()
$exitCode = 0

Push-Location -LiteralPath $env:SystemRoot

try {
    if (($stopContainers.Count -gt 0) -and
        $PSCmdlet.ShouldProcess("Docker containers: $(($stopContainers | ForEach-Object { $_.Name }) -join ', ')", "Stop")) {
        Write-Host "Stopping Docker containers: $(($stopContainers | ForEach-Object { $_.Name }) -join ', ')."

        $null = & $DockerExe stop --time $TimeoutSeconds @($stopContainers | ForEach-Object { $_.Id }) 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Cannot stop some Docker containers."
        }

        $stoppedContainers = $stopContainers
    }

    if (($virtualDisks.Count -gt 0) -and $PSCmdlet.ShouldProcess("Docker Desktop and WSL", "Stop")) {
        StopDockerDesktop
        $stoppedDocker = $true
    }

    # Dependent services come after the services they depend on (-Force stops them first).
    foreach ($name in $stopServices) {
        if ($PSCmdlet.ShouldProcess("Service '$name'", "Stop")) {
            Write-Host "Stopping service: $name."

            try {
                Stop-Service -Name $name -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "Cannot stop service '$name': $($_.Exception.Message)"
            }

            $stoppedServices += $name
        }
    }

    $stoppedProcesses = @($stopProcesses | Where-Object {
        $PSCmdlet.ShouldProcess("Process '$($_.Name)' (PID $($_.ProcessId))", "Stop")
    })

    # Parents first, so they can shut down their children gracefully.
    StopProcesses @($stoppedProcesses | Where-Object { !$_.IsChild })
    StopProcesses @($stoppedProcesses | Where-Object { $_.IsChild })

    foreach ($volume in $volumes) {
        $letter = "$($volume.DriveLetter)"

        if (!$PSCmdlet.ShouldProcess("Drive ${letter}:", "chkdsk /F /X")) {
            continue
        }

        $code = CheckVolume $letter

        $status = switch ($code) {
            0       { "no errors found" }
            1       { "errors found and fixed" }
            2       { "disk cleanup performed" }
            3       { "check failed or errors not fixed" }
            default { "unexpected exit code $code" }
        }

        if ($code -notin 0, 1, 2) {
            $exitCode = 1
        }

        $results += "  ${letter}: $status (exit code $code)"
    }
}
catch {
    Write-Error "Disk check failed: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    Pop-Location

    if (!$NoRestart) {
        # Services first, in case the processes need them.
        foreach ($name in $stoppedServices) {
            if ((Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq "Running") {
                continue
            }

            Write-Host "Starting service: $name."

            try {
                Start-Service -Name $name -ErrorAction Stop
            }
            catch {
                Write-Warning "Cannot start service '$name': $($_.Exception.Message)"
            }
        }

        $dockerReady = $true

        if ($stoppedDocker -and $dockerDesktopPath) {
            StartProcess ([pscustomobject]@{
                Name      = "$DOCKER_DESKTOP_PROCESS.exe"
                Path      = $dockerDesktopPath
                Arguments = ""
            })

            if ($stoppedContainers.Count -gt 0) {
                $dockerReady = WaitDocker

                if (!$dockerReady) {
                    Write-Warning "Docker engine did not start; start the Docker containers manually."
                }
            }
        }

        if (($stoppedContainers.Count -gt 0) -and $dockerReady) {
            Write-Host "Starting Docker containers: $(($stoppedContainers | ForEach-Object { $_.Name }) -join ', ')."

            $null = & $DockerExe start @($stoppedContainers | ForEach-Object { $_.Id }) 2>&1

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Cannot start some Docker containers (check 'docker ps -a')."
            }
        }

        foreach ($process in $stoppedProcesses) {
            if ($process.IsChild) {
                continue
            }

            if (!$process.Path) {
                Write-Warning "Cannot start '$($process.Name)': its path is unknown."
            } elseif ($process.Owner -and ($process.Owner -ne $currentUser)) {
                Write-Warning "Not starting '$($process.Name)': it was run by '$($process.Owner)'."
            } else {
                StartProcess $process
            }
        }
    }
}

if ($results.Count -gt 0) {
    Write-Host "Results:"
    $results | ForEach-Object { Write-Host $_ }
}

if ($exitCode) {
    Write-Host "Finished with errors."
} else {
    Write-Host "Done."
}

ExitScript $exitCode
