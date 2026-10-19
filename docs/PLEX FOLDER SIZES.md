# Plex folder sizes

The [PlexFolderSizes.ps1](../PlexFolderSizes.ps1) script shows how much disk space each folder of the Plex Media Server app data folder takes, to find out what makes the Plex data (and the backups) big.

## What it does

The script lists the folders of the Plex app data folder with:

| Column | Description |
|---|---|
| `Folder` | Folder name (subfolders are indented) |
| `Files` | Number of files, including subfolders |
| `Size` | Total size, including subfolders |
| `Percent` | Share of the whole Plex app data folder |

Folders are sorted by size, largest first, and the last line shows the total number of files and size.

By default, only the top-level folders are shown. Use the `Depth` parameter to also show subfolders. When subfolders are shown, files stored directly in a folder (not in its subfolders) are listed as `(files)`.

### Grouping by bundle details

Inside the `Metadata` and `Media` folders, folder names do not tell much: Plex stores the data of each library item in a bundle folder with a hashed name, e.g.:

```
Metadata\TV Shows\a\3f9c...e1.bundle\Contents\_combined\posters\...
         |                               |         |
         library                         agent     type
```

Use the `GroupBy` parameter to group the files by one or more of the following, instead of showing the folder tree:

| Value | Description |
|---|---|
| `Folder` | Folder tree (default); combined with other values, the top-level folder (e.g. `Metadata`) |
| `Library` | Folder holding the bundles, e.g. `Metadata\Movies`, `Metadata\TV Shows`, `Metadata\Artists` (or `Media\localhost` for video preview thumbnails) |
| `Agent` | Metadata agent folder, e.g. `_combined` (the merged data Plex shows), `tv.plex.agents.movie` (new agents) or `com.plexapp.agents.imdb` (legacy agents); for video preview thumbnails `Indexes` |
| `Type` | Content type folder, e.g. `posters`, `art` (backgrounds), `themes` (TV theme music) or `thumbs` |
| `Extension` | File extension |

The table then has one column per value, and its rows are sorted by size. Files that are not stored in a bundle are listed as `-`. With several values, every combination gets its own row, so use `Top` to see only the largest ones.

The script only reads the folders: it does not change anything and does not need to stop Plex Media Server. Scanning a large Plex library (especially the `Metadata` and `Media` folders) may take a few minutes. If some files cannot be read, the script shows a warning and their sizes are not included (use `-Verbose` to list them).

To free up space, see [Plex cleanup](PLEX%20CLEANUP.md).

## Usage

Run the script as the user running Plex Media Server (no need to run it as Administrator).

The easiest way is to double-click [RunPlexFolderSizes.bat](../RunPlexFolderSizes.bat): it runs the script (bypassing the PowerShell execution policy) and keeps the window open at the end. Any arguments are passed to the script, e.g. `RunPlexFolderSizes.bat -Depth 2`.

Show the top-level folders:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexFolderSizes.ps1
```

Show two folder levels:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexFolderSizes.ps1 -Depth 2
```

Show three folder levels, with only the five largest folders at each level:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexFolderSizes.ps1 -Depth 3 -Top 5
```

Show the sizes of the posters, artwork, theme music, etc. of each library type:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexFolderSizes.ps1 -PlexAppDataDir "$env:LOCALAPPDATA\Plex Media Server\Metadata" -GroupBy Library,Type
```

Show the 20 largest agent and type combinations of the whole Plex app data folder:

```PowerShell
powershell -ExecutionPolicy Bypass -File .\PlexFolderSizes.ps1 -GroupBy Agent,Type -Top 20
```

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `PlexAppDataDir` | `$env:LOCALAPPDATA\Plex Media Server` | Plex app data folder |
| `Depth` | `1` | Number of folder levels to show (only with `-GroupBy Folder`) |
| `Top` | `0` | Maximum number of the largest folders to show at each level, or of the largest groups (`0` shows all of them) |
| `GroupBy` | `Folder` | How to group the files: `Folder`, or one or more of `Library`, `Agent`, `Type`, `Extension` (see [Grouping by bundle details](#grouping-by-bundle-details)) |
| `Verbose` | | List the files and folders that cannot be read |
