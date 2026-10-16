#------------------------------[ HELP INFO ]-------------------------------

<#
.SYNOPSIS
Checks and repairs the file systems of external USB disks using 'chkdsk /F' (exFAT volumes using 'fsck.exfat' in WSL).

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

4. Runs 'chkdsk <drive>: /F /X' for each volume (or 'fsck.exfat -y' in WSL for exFAT volumes), one at a time.

5. Starts the stopped apps again (even if a check fails), including Docker Desktop and the stopped Docker containers.

chkdsk cannot repair some exFAT errors: it saves the same lost clusters in a new FOUND.nnn folder on every run. So exFAT volumes are checked with 'fsck.exfat' (from exfatprogs) in WSL instead: the script attaches the disk to WSL ('wsl --mount --bare', which takes the whole disk offline in Windows), runs 'fsck.exfat -y' on the volume and detaches the disk again. It uses the WSL distribution specified by the WslDistro parameter, or the default one (Docker Desktop's distributions are skipped); if there is none, it installs Debian. Missing tools (exfatprogs, blkid) are installed in the distribution. Use the UseChkdsk switch to check exFAT volumes with chkdsk instead.

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

.PARAMETER WslDistro
Name of the WSL distribution used to check exFAT volumes (installed if missing). Default: the default WSL distribution (other than Docker Desktop's ones and not stored on a checked volume), or Debian if there is none.

.PARAMETER UseChkdsk
Checks exFAT volumes with chkdsk instead of fsck.exfat in WSL.

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

    [string]
    $WslDistro = $null,

    [switch]
    $UseChkdsk,

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

# WSL distribution installed for checking exFAT volumes if there is no usable one.
$WSL_DEFAULT_DISTRO = "Debian"

# Docker Desktop's WSL distributions (not meant for running other tools).
$REGEX_DOCKER_DISTRO = '^docker-desktop'

# Installs the tools for checking exFAT volumes in the WSL distribution if they are missing.
$WSL_INSTALL_TOOLS = @(
    'command -v fsck.exfat >/dev/null 2>&1 && command -v blkid >/dev/null 2>&1 && exit 0',
    'echo Installing exfatprogs.',
    'if command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq exfatprogs util-linux',
    'elif command -v apk >/dev/null 2>&1; then apk add --no-cache exfatprogs blkid',
    'elif command -v dnf >/dev/null 2>&1; then dnf install -y -q exfatprogs util-linux',
    'elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install exfatprogs util-linux',
    'elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm exfatprogs util-linux',
    'else echo No supported package manager found.; exit 1; fi',
    'command -v fsck.exfat >/dev/null 2>&1 && command -v blkid >/dev/null 2>&1'
) -join '; '

# Runs commands as root in WSL with the admin tools (such as fsck.exfat) in PATH.
$WSL_ROOT_EXEC = @("--user", "root", "--exec", "env", "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")

# Maximum time to wait for an exFAT volume to show up in WSL after attaching its disk,
# and to come back in Windows after detaching it.
$WSL_DEVICE_TIMEOUT_SECONDS    = 30
$VOLUME_ONLINE_TIMEOUT_SECONDS = 60

# fsck.exfat exit codes: no errors, errors corrected, operational error (also used
# when the volume cannot be checked in WSL at all).
$FSCK_NO_ERRORS        = 0
$FSCK_CORRECTED        = 1
$FSCK_OPERATION_ERROR  = 8

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
# GetWslDistros
#   Returns the WSL distributions of the current user (the default one first).
function GetWslDistros {
    $default = (Get-ItemProperty -Path $WSL_REG_KEY -Name DefaultDistribution `
        -ErrorAction SilentlyContinue).DefaultDistribution

    $distros = foreach ($key in (Get-ChildItem -Path $WSL_REG_KEY -ErrorAction SilentlyContinue)) {
        $distro = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue

        if ($distro.DistributionName) {
            [pscustomobject]@{
                Name      = $distro.DistributionName
                Path      = "$($distro.BasePath)" -replace '^\\\\\?\\', ''
                Version   = $distro.Version
                IsDefault = ($key.PSChildName -eq $default)
            }
        }
    }

    return @($distros | Sort-Object -Property IsDefault -Descending)
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

    foreach ($distro in (GetWslDistros)) {
        if ($distro.Path) {
            $disks += [pscustomobject]@{
                Name = "WSL distribution '$($distro.Name)'"
                Path = $distro.Path
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
    $null = InvokeWsl @("--shutdown") (New-Object Collections.Generic.List[string])
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

#--------------------------------------------------------------------------
# QuoteArgument
#   Quotes the argument for a Windows command line (if needed).
function QuoteArgument {
    param (
        [string]
        $argument
    )

    if ($argument -and ($argument -notmatch '[\s"]')) {
        return $argument
    }

    # Backslashes are literal unless they precede a quote (or the closing quote).
    $argument = $argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'

    return "`"$argument`""
}

#--------------------------------------------------------------------------
# InvokeWsl
#   Runs wsl.exe with the arguments and returns its exit code. Prints its output,
#   or adds the output lines to the list if one is specified.
function InvokeWsl {
    param (
        [string[]]
        $arguments,

        [Collections.Generic.List[string]]
        $output = $null
    )

    # Run wsl.exe without a console: it changes the console mode, which makes the lines
    # printed while it runs pile up like a staircase.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName               = "wsl.exe"
    $info.Arguments              = ($arguments | ForEach-Object { QuoteArgument $_ }) -join ' '
    $info.UseShellExecute        = $false
    $info.CreateNoWindow         = $true
    $info.RedirectStandardInput  = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError  = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding  = [Text.Encoding]::UTF8

    $process = [Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()

    # Print the output and error lines in the order they arrive.
    $readers = @($process.StandardOutput, $process.StandardError)
    $tasks   = @($readers | ForEach-Object { $_.ReadLineAsync() })

    while ($true) {
        $pending = @($tasks | Where-Object { $_ })

        if ($pending.Count -eq 0) {
            break
        }

        # Wait in short steps, so that Ctrl+C still works.
        $index = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]$pending, 1000)

        if ($index -lt 0) {
            continue
        }

        $i = [array]::IndexOf($tasks, $pending[$index])
        $line = $tasks[$i].Result

        if ($null -eq $line) {
            $tasks[$i] = $null
            continue
        }

        $tasks[$i] = $readers[$i].ReadLineAsync()

        # Older WSL versions print their own messages in UTF-16 (despite WSL_UTF8).
        $line = $line -replace "`0", ""

        if (!$line.Trim()) {
            continue
        }

        if ($null -ne $output) {
            $output.Add($line)
        } else {
            Write-Host "  $line"
        }
    }

    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()

    return $code
}

#--------------------------------------------------------------------------
# InstallWslDistro
#   Installs the WSL distribution and returns it (null if it cannot be installed).
#   The script runs everything in it as root, so no user account is created.
function InstallWslDistro {
    param (
        [string]
        $name
    )

    Write-Host "Installing WSL distribution '$name'."

    $null = InvokeWsl @("--install", "--distribution", $name, "--no-launch")

    $distro = GetWslDistros | Where-Object { $_.Name -eq $name } | Select-Object -First 1

    if (!$distro) {
        # Older (Store) distributions are registered by their launcher on the first run.
        $launcher = Get-Command "$($name.ToLower()).exe" -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($launcher) {
            & $launcher.Source install --root 2>&1 | ForEach-Object { Write-Host "  $_" }

            $distro = GetWslDistros | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        }
    }

    if (!$distro) {
        Write-Warning "Cannot install WSL distribution '$name' (install it with 'wsl --install -d $name')."
    }

    return $distro
}

#--------------------------------------------------------------------------
# GetWslDistro
#   Returns the name of the WSL distribution used to check exFAT volumes, after
#   installing it and the tools it needs if missing (null if it cannot be used).
function GetWslDistro {
    param (
        [string]
        $driveRegex
    )

    $distros = @(GetWslDistros)
    $name = $Script:WslDistro

    if (!$name) {
        # WSL 1 distributions do not see the attached disks.
        $usable = @($distros | Where-Object {
            ($_.Name -notmatch $REGEX_DOCKER_DISTRO) -and ($_.Version -ne 1) -and ($_.Path -notmatch $driveRegex)
        })

        $name = if ($usable.Count -gt 0) { $usable[0].Name } else { $WSL_DEFAULT_DISTRO }
    }

    $distro = $distros | Where-Object { $_.Name -eq $name } | Select-Object -First 1

    if (!$distro) {
        $distro = InstallWslDistro $name

        if (!$distro) {
            return $null
        }
    }

    # The volume holding the distribution goes offline during its check.
    if ($distro.Path -match $driveRegex) {
        Write-Warning ("WSL distribution '$name' is stored on a checked volume ($($distro.Path)); " +
            "use -WslDistro to pick another one.")
        return $null
    }

    Write-Host "Using WSL distribution '$name' to check the exFAT volumes."

    if ((InvokeWsl (@("--distribution", $name) + $WSL_ROOT_EXEC + @("sh", "-c", $WSL_INSTALL_TOOLS))) -ne 0) {
        Write-Warning "Cannot install exfatprogs in WSL distribution '$name'."
        return $null
    }

    return $name
}

#--------------------------------------------------------------------------
# GetExFatDisk
#   Returns the disk number and serial number (used to find the volume in WSL)
#   of the exFAT volume, or null if the volume cannot be checked in WSL.
function GetExFatDisk {
    param (
        [string]
        $letter,

        [string[]]
        $letters
    )

    $partition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    $info = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='${letter}:'" `
        -ErrorAction SilentlyContinue

    if (!$partition -or !$info -or ($null -eq $info.SerialNumber)) {
        Write-Warning "Cannot find the disk or serial number of drive ${letter}:."
        return $null
    }

    # WSL takes the whole disk offline, so the apps using its other volumes must be stopped, too.
    $others = @(Get-Partition -DiskNumber $partition.DiskNumber |
        ForEach-Object { "$($_.DriveLetter)" } |
            Where-Object { ($_ -match '^[A-Z]$') -and ($_ -notin $letters) })

    if ($others.Count -gt 0) {
        Write-Warning ("Disk $($partition.DiskNumber) of drive ${letter}: also holds drive(s) " +
            "$(($others | ForEach-Object { "${_}:" }) -join ', '), which WSL takes offline, too; " +
            "check them as well or use -UseChkdsk.")
        return $null
    }

    return [pscustomobject]@{
        Number = $partition.DiskNumber
        Serial = '{0:X8}' -f [uint32]$info.SerialNumber
    }
}

#--------------------------------------------------------------------------
# FindWslDevice
#   Returns the WSL device (e.g. '/dev/sdf2') of the exFAT volume with the serial
#   number, waiting for it to show up after attaching its disk (null on timeout).
function FindWslDevice {
    param (
        [string]
        $serial
    )

    $deadline = (Get-Date).AddSeconds($WSL_DEVICE_TIMEOUT_SECONDS)

    while ($true) {
        # blkid prints e.g. '/dev/sdf2: LABEL="Media" UUID="6A3B-1C2D" TYPE="exfat"', where
        # the exFAT UUID is the volume serial number.
        $lines = New-Object Collections.Generic.List[string]
        $null = InvokeWsl (@("--distribution", $Script:wslName) + $WSL_ROOT_EXEC + @("blkid")) $lines

        foreach ($line in $lines) {
            if (!("$line" -match '^(/dev/\S+):')) {
                continue
            }

            $device = $Matches[1]
            $tags = @{}

            foreach ($match in [regex]::Matches("$line", '(\w+)="([^"]*)"')) {
                $tags[$match.Groups[1].Value] = $match.Groups[2].Value
            }

            if (($tags["TYPE"] -eq "exfat") -and (($tags["UUID"] -replace '-', '') -eq $serial)) {
                return $device
            }
        }

        if ((Get-Date) -gt $deadline) {
            return $null
        }

        Start-Sleep -Seconds 2
    }
}

#--------------------------------------------------------------------------
# WriteStep
#   Prints a step of a volume check with the current time.
function WriteStep {
    param (
        [string]
        $text
    )

    Write-Host "  [$(Get-Date -Format 'HH:mm:ss')] $text"
}

#--------------------------------------------------------------------------
# WaitVolumeOnline
#   Brings the disk back online (if WSL left it offline) and waits for the volume.
function WaitVolumeOnline {
    param (
        [int]
        $diskNumber,

        [string]
        $letter
    )

    $deadline = (Get-Date).AddSeconds($VOLUME_ONLINE_TIMEOUT_SECONDS)
    $online = $false

    WriteStep "Waiting for drive ${letter}: to come back."

    while ($true) {
        if ((Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue).IsOffline) {
            if (!$online) {
                WriteStep "Bringing disk $diskNumber online."
                $online = $true
            }

            Set-Disk -Number $diskNumber -IsOffline $false -ErrorAction SilentlyContinue
        }

        if (Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue) {
            WriteStep "Drive ${letter}: is back online."
            return
        }

        if ((Get-Date) -gt $deadline) {
            Write-Warning "Drive ${letter}: did not come back; bring disk $diskNumber online in Disk Management."
            return
        }

        Start-Sleep -Seconds 2
    }
}

#--------------------------------------------------------------------------
# CheckExFatVolume
#   Attaches the disk of the exFAT volume to WSL, runs fsck.exfat with the -y
#   switch on the volume, detaches the disk and returns the fsck.exfat exit code.
function CheckExFatVolume {
    param (
        [string]
        $letter,

        [object]
        $disk
    )

    Write-Host "Checking drive ${letter}: (fsck.exfat in WSL distribution '$Script:wslName')"

    $devicePath = "\\.\PHYSICALDRIVE$($disk.Number)"
    $attached = $false

    try {
        # WSL cannot attach a disk with open files, so (like chkdsk /X) force the volume to
        # dismount, closing the files kept open by the processes the script does not stop
        # (e.g. Explorer or Windows Defender), and take the disk offline before it remounts.
        WriteStep "Dismounting drive ${letter}:."
        $null = & fsutil.exe volume dismount "${letter}:" 2>&1

        WriteStep "Taking disk $($disk.Number) offline."

        try {
            Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop
        }
        catch {
            Write-Warning "Cannot take disk $($disk.Number) offline: $($_.Exception.Message)"
            return $FSCK_OPERATION_ERROR
        }

        WriteStep "Attaching disk $($disk.Number) to WSL (wsl --mount $devicePath --bare)."

        if ((InvokeWsl @("--mount", $devicePath, "--bare")) -ne 0) {
            Write-Warning "Cannot attach disk $($disk.Number) to WSL."
            return $FSCK_OPERATION_ERROR
        }

        $attached = $true

        WriteStep "Looking for drive ${letter}: in WSL (exFAT serial number $($disk.Serial))."
        $device = FindWslDevice $disk.Serial

        if (!$device) {
            Write-Warning "Cannot find drive ${letter}: in WSL (exFAT serial number $($disk.Serial))."
            return $FSCK_OPERATION_ERROR
        }

        WriteStep "Drive ${letter}: is $device in WSL."
        WriteStep ("Running fsck.exfat -y $device. It shows no progress and prints its output when it " +
            "finishes, which can take a long time on a large disk; do not interrupt it.")

        # Without the -s switch, lost clusters are freed instead of saved in a folder.
        $start = Get-Date
        $code = InvokeWsl (@("--distribution", $Script:wslName) + $WSL_ROOT_EXEC + @("fsck.exfat", "-y", $device))

        WriteStep ("fsck.exfat finished in $(((Get-Date) - $start).ToString('hh\:mm\:ss')) " +
            "(exit code $code).")

        return $code
    }
    finally {
        if ($attached) {
            WriteStep "Detaching disk $($disk.Number) from WSL (wsl --unmount $devicePath)."
            $null = InvokeWsl @("--unmount", $devicePath)
        }

        WaitVolumeOnline $disk.Number $letter
    }
}

#--------------------------------------------------------------------------
# FinishScript
#   Prints the check results and exits.
function FinishScript {
    if ($Script:results.Count -gt 0) {
        Write-Host "Results:"
        $Script:results | ForEach-Object { Write-Host $_ }
    }

    if ($Script:exitCode) {
        Write-Host "Finished with errors."
    } else {
        Write-Host "Done."
    }

    ExitScript $Script:exitCode
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

$results = @()
$exitCode = 0

# Check exFAT volumes with fsck.exfat in WSL: chkdsk cannot repair some exFAT errors
# and saves the same lost clusters in a new FOUND.nnn folder on every run.
$exFatDisks = @{}
$wslName = $null

$exFatVolumes = @($volumes | Where-Object { $_.FileSystem -eq "exFAT" })

if (!$UseChkdsk -and ($exFatVolumes.Count -gt 0)) {
    $letters = @($volumes | ForEach-Object { "$($_.DriveLetter)" })

    foreach ($volume in $exFatVolumes) {
        $disk = GetExFatDisk "$($volume.DriveLetter)" $letters

        if ($disk) {
            $exFatDisks["$($volume.DriveLetter)"] = $disk
        }
    }

    if (($exFatDisks.Count -gt 0) -and !$WhatIfPreference) {
        # Newer WSL versions print their own messages in UTF-8 with this.
        $env:WSL_UTF8 = "1"

        $wslName = GetWslDistro (GetDriveRegex $letters)

        if (!$wslName) {
            $exFatDisks.Clear()
        }
    }

    # Do not stop the apps for volumes that cannot be checked.
    $skipped = @($exFatVolumes | ForEach-Object { "$($_.DriveLetter)" } |
        Where-Object { !$exFatDisks.ContainsKey($_) })

    if ($skipped.Count -gt 0) {
        foreach ($letter in $skipped) {
            $results += "  ${letter}: not checked (cannot check it with fsck.exfat in WSL, see the warnings above)"
        }

        $exitCode = 1
        $volumes = @($volumes | Where-Object { "$($_.DriveLetter)" -notin $skipped })

        if ($volumes.Count -eq 0) {
            FinishScript
        }
    }
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

        if ($exFatDisks.ContainsKey($letter)) {
            if (!$PSCmdlet.ShouldProcess("Drive ${letter}:", "fsck.exfat -y (WSL)")) {
                continue
            }

            $code = CheckExFatVolume $letter $exFatDisks[$letter]

            $status = switch ($code) {
                $FSCK_NO_ERRORS { "no errors found" }
                $FSCK_CORRECTED { "errors found and fixed" }
                default         { "check failed or errors not fixed" }
            }

            if ($code -notin $FSCK_NO_ERRORS, $FSCK_CORRECTED) {
                $exitCode = 1
            }

            $results += "  ${letter}: $status (fsck.exfat exit code $code)"
            continue
        }

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

        $results += "  ${letter}: $status (chkdsk exit code $code)"
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

FinishScript
