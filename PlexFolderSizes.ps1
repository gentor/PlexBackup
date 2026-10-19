#------------------------------[ HELP INFO ]-------------------------------

<#
.SYNOPSIS
Shows the sizes of the Plex Media Server app data folders on a Windows system.

.DESCRIPTION
By default, lists the folders of the Plex app data folder with the number of files, the total size (including subfolders) and the share of the total size. Folders are sorted by size, largest first. Use the -Depth parameter to also show subfolders (as an indented tree).

When subfolders are shown, files stored directly in a folder (not in its subfolders) are listed as '(files)'.

Use the -GroupBy parameter to group the files by Plex bundle details or file extension instead. Plex stores the data of each library item in a bundle folder, e.g.:

Metadata\TV Shows\a\3f9c...e1.bundle\Contents\_combined\posters\...

where 'Metadata\TV Shows' is the library, '_combined' the agent and 'posters' the type. Files that are not stored in a bundle are listed as '-'.

The script only reads the folders: it does not change anything and does not need to stop Plex Media Server.

.PARAMETER PlexAppDataDir
Path to the Plex app data folder. Default: '$env:LOCALAPPDATA\Plex Media Server'.

.PARAMETER Depth
Number of folder levels to show (only used with '-GroupBy Folder'). Default: 1 (only the top-level folders).

.PARAMETER Top
Maximum number of the largest folders to show at each level, or of the largest groups (0 shows all of them). Default: 0.

.PARAMETER GroupBy
How to group the files, one or more of:

- Folder: folder tree (default); combined with other values, the top-level folder
- Library: folder holding the bundles, e.g. 'Metadata\Movies' (or 'Media\localhost' for video preview thumbnails)
- Agent: bundle subfolder of the metadata agent, e.g. '_combined' or 'tv.plex.agents.movie' (or 'Indexes' for video preview thumbnails)
- Type: bundle subfolder of the content type, e.g. 'posters', 'art' or 'themes'
- Extension: file extension

.EXAMPLE
.\PlexFolderSizes.ps1
Shows the sizes of the top-level folders.

.EXAMPLE
.\PlexFolderSizes.ps1 -Depth 3 -Top 5
Shows three folder levels, with the five largest folders at each level.

.EXAMPLE
.\PlexFolderSizes.ps1 -PlexAppDataDir "$env:LOCALAPPDATA\Plex Media Server\Metadata" -GroupBy Library,Type
Shows the sizes of the posters, artwork, theme music, etc. of each library type.
#>

#------------------------------[ PARAMETERS ]------------------------------

[CmdletBinding()]
param (
    [string]
    $PlexAppDataDir = "$env:LOCALAPPDATA\Plex Media Server",

    [ValidateRange(1,[int]::MaxValue)]
    [int]
    $Depth = 1,

    [ValidateRange(0,[int]::MaxValue)]
    [int]
    $Top = 0,

    [ValidateSet("Folder", "Library", "Agent", "Type", "Extension")]
    [string[]]
    $GroupBy = @("Folder")
)

#-------------------------------[ CONSTANTS ]------------------------------

# Supported -GroupBy values (in their display case).
$GROUP_BY_VALUES = @("Folder", "Library", "Agent", "Type", "Extension")

# Name shown for the files stored directly in a folder.
$FILES_NAME = "(files)"

# Name shown for the files that have no group value (e.g. not in a bundle).
$NONE_NAME = "-"

# Number of spaces used to indent each subfolder level.
$INDENT_SIZE = 2

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
# AddFile
#   Adds the file size to the specified folder (and creates its entry).
function AddFile {
    param (
        [string]
        $key,

        [string]
        $parent,

        [long]
        $length
    )

    $entry = $Script:folders[$key]

    if (!$entry) {
        $entry = [PSCustomObject]@{ Files = [long]0; Size = [long]0 }
        $Script:folders[$key] = $entry

        if (!$Script:children.ContainsKey($parent)) {
            $Script:children[$parent] = New-Object System.Collections.Generic.List[string]
        }

        $Script:children[$parent].Add($key)
    }

    $entry.Files++
    $entry.Size += $length
}

#--------------------------------------------------------------------------
# AddGroup
#   Adds the file size to the group with the specified values (and creates
#   its entry).
function AddGroup {
    param (
        [string[]]
        $values,

        [long]
        $length
    )

    $key   = $values -join "`t"
    $entry = $Script:groups[$key]

    if (!$entry) {
        $entry = [PSCustomObject]@{ Values = $values; Files = [long]0; Size = [long]0 }
        $Script:groups[$key] = $entry
    }

    $entry.Files++
    $entry.Size += $length
}

#--------------------------------------------------------------------------
# GetGroupValues
#   Returns the -GroupBy values of the file with the specified relative
#   folder path parts.
function GetGroupValues {
    param (
        [string[]]
        $parts,

        [System.IO.FileInfo]
        $file
    )

    # Index of the bundle folder ('<hash>.bundle\Contents'), if any.
    $bundle = -1

    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if ($parts[$i].EndsWith(".bundle") -and $parts[$i + 1] -eq "Contents") {
            $bundle = $i
            break
        }
    }

    foreach ($name in $Script:GroupBy) {
        switch ($name) {
            "Folder" {
                if ($parts.Count -gt 0) { $parts[0] } else { $FILES_NAME }
            }
            "Library" {
                # Bundles are stored in '<library>\<first hash character>'.
                if ($bundle -ge 2) { $parts[0..($bundle - 2)] -join '\' } else { $NONE_NAME }
            }
            "Agent" {
                if ($bundle -ge 0 -and $parts.Count -gt $bundle + 2) { $parts[$bundle + 2] } else { $NONE_NAME }
            }
            "Type" {
                if ($bundle -ge 0 -and $parts.Count -gt $bundle + 3) { $parts[$bundle + 3] } else { $NONE_NAME }
            }
            "Extension" {
                if ($file.Extension) { $file.Extension.ToLower() } else { $NONE_NAME }
            }
        }
    }
}

#--------------------------------------------------------------------------
# GetRows
#   Returns the table rows for the subfolders of the specified folder
#   (largest first, followed by their own subfolders).
function GetRows {
    param (
        [string]
        $parent,

        [int]
        $level
    )

    $keys = @($Script:children[$parent] |
        Sort-Object -Property { $Script:folders[$_].Size } -Descending)

    # A folder holding only files does not need a separate '(files)' row.
    if ($keys.Count -eq 1 -and $keys[0].EndsWith($FILES_NAME)) {
        return
    }

    if ($Script:Top -gt 0 -and $keys.Count -gt $Script:Top) {
        $keys = $keys[0..($Script:Top - 1)]
    }

    foreach ($key in $keys) {
        $entry = $Script:folders[$key]

        [PSCustomObject]@{
            Folder = (" " * ($level * $INDENT_SIZE)) + $key.Substring($key.LastIndexOf('\') + 1)
            Files  = $entry.Files
            Size   = $entry.Size
        }

        if ($Script:children.ContainsKey($key)) {
            GetRows $key ($level + 1)
        }
    }
}

#---------------------------------[ MAIN ]---------------------------------

if (!(Test-Path -LiteralPath $PlexAppDataDir -PathType Container)) {
    Write-Error "Plex app data folder '$PlexAppDataDir' does not exist."
    exit 1
}

# Use the display case and drop duplicates (keeping the specified order).
$GroupBy = @($GroupBy | ForEach-Object {
    $value = $_
    $GROUP_BY_VALUES | Where-Object { $_ -eq $value }
} | Select-Object -Unique)

# Show the folder tree unless grouping by anything else.
$groupMode = ($GroupBy.Count -gt 1 -or $GroupBy[0] -ne "Folder")

$root = (Resolve-Path -LiteralPath $PlexAppDataDir).ProviderPath.TrimEnd('\')

Write-Host "Plex app data folder: $root"
Write-Host "Scanning files (this may take a while)..."

# Folder statistics by path relative to the Plex app data folder.
$folders  = @{}

# Folder paths by parent folder path ('' is the Plex app data folder).
$children = @{}

# Group statistics by the tab-separated -GroupBy values.
$groups   = @{}

$totalFiles = [long]0
$totalSize  = [long]0
$scanErrors = @()

Get-ChildItem -LiteralPath $root -Recurse -File -Force `
    -ErrorAction SilentlyContinue -ErrorVariable +scanErrors | ForEach-Object {

    $totalFiles++
    $totalSize += $_.Length

    $relDir = $_.DirectoryName.Substring($root.Length).TrimStart('\')
    $parts  = @(if ($relDir) { $relDir.Split('\') })

    if ($groupMode) {
        AddGroup @(GetGroupValues $parts $_) $_.Length
        return
    }

    $parent = ""

    # Add the file to each shown folder level it belongs to.
    for ($i = 0; $i -lt [math]::Min($parts.Count, $Depth); $i++) {
        $key = if ($parent) { "$parent\$($parts[$i])" } else { $parts[$i] }

        AddFile $key $parent $_.Length
        $parent = $key
    }

    # Files stored directly in a folder which subfolders are shown.
    if ($parts.Count -lt $Depth) {
        $key = if ($parent) { "$parent\$FILES_NAME" } else { $FILES_NAME }

        AddFile $key $parent $_.Length
    }
}

if ($groupMode) {
    $rows = @($groups.Values | Sort-Object -Property Size -Descending)

    if ($Top -gt 0 -and $rows.Count -gt $Top) {
        $rows = $rows[0..($Top - 1)]
    }

    $columns = @(for ($i = 0; $i -lt $GroupBy.Count; $i++) {
        @{ Label = $GroupBy[$i]; Expression = [scriptblock]::Create("`$_.Values[$i]") }
    })
} else {
    $rows    = @(if ($children.ContainsKey("")) { GetRows "" 0 })
    $columns = @("Folder")
}

if ($rows.Count -gt 0) {
    $rows | Format-Table -AutoSize -Property ($columns + @(
        @{ Label = "Files";   Expression = { "{0:N0}" -f $_.Files };  Alignment = "Right" },
        @{ Label = "Size";    Expression = { FormatSize $_.Size };    Alignment = "Right" },
        @{ Label = "Percent"; Expression = { "{0:N1} %" -f $(if ($totalSize) { 100 * $_.Size / $totalSize } else { 0 }) };
            Alignment = "Right" }
    )) | Out-Host
}

Write-Host ("Total: {0:N0} file(s), {1}." -f $totalFiles, (FormatSize $totalSize))

if ($scanErrors.Count -gt 0) {
    Write-Warning ("Cannot read $($scanErrors.Count) item(s); sizes do not include them " +
        "(use -Verbose to list them).")

    foreach ($scanError in $scanErrors) {
        Write-Verbose $scanError.Exception.Message
    }
}
