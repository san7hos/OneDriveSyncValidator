# OneDriveSyncValidator

Scripts for macOS and Windows to validate that photos and videos from a connected iPhone have been synced correctly to OneDrive — without downloading any files.

## Overview

`Validate-OneDriveSync.ps1` compares the media files on your iPhone against your local OneDrive folder and reports any files that are present on the device but missing from OneDrive.

## Requirements

- **PowerShell 7** (`pwsh`) – [Install on macOS](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-macos)
- iPhone mounted and accessible as a file system path.  
  Options include:
  - **USB connection via Finder** – trust the device and browse it as a volume under `/Volumes/<DeviceName>/`
  - **[ifuse](https://github.com/libimobiledevice/ifuse)** – mounts the iPhone DCIM folder at a chosen path
- OneDrive desktop app installed and syncing locally

## Usage

```bash
# Auto-detect iPhone DCIM folder and OneDrive path
pwsh ./src/Validate-OneDriveSync.ps1

# Specify paths explicitly
pwsh ./src/Validate-OneDriveSync.ps1 \
    -SourcePath /Volumes/iPhone/DCIM \
    -OneDrivePath ~/Library/CloudStorage/OneDrive-Personal/Pictures

# Also compare file sizes (detects partial / corrupted uploads)
pwsh ./src/Validate-OneDriveSync.ps1 -CompareBySize

# Export a full per-file CSV report
pwsh ./src/Validate-OneDriveSync.ps1 \
    -SourcePath /Volumes/iPhone/DCIM \
    -OneDrivePath ~/OneDrive/Pictures \
    -ReportPath ~/Desktop/sync-report.csv
```

### Parameters

| Parameter | Description | Default |
|---|---|---|
| `-SourcePath` | Path to iPhone DCIM folder or import folder | Auto-detected under `/Volumes` |
| `-OneDrivePath` | Path to the OneDrive sync folder | Auto-detected under `~/Library/CloudStorage` or `~/OneDrive` |
| `-Extensions` | File extensions to compare | `.jpg .jpeg .heic .heif .png .gif .tif .tiff .mp4 .mov .m4v .3gp` |
| `-CompareBySize` | Also compare file sizes (switch) | Off |
| `-ReportPath` | Path to export a CSV report | None |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | All files synced |
| `N > 0` | N files are missing from OneDrive |

## Sample output

```
Scanning source files...
Scanning OneDrive index (no downloads triggered)...
Comparing files...

=== OneDrive Sync Validation Report ===
Source (iPhone) : /Volumes/iPhone/DCIM
Destination     : /Users/you/Library/CloudStorage/OneDrive-Personal/Pictures

Missing files (2):
  - IMG_4521.HEIC (2.3 MB, 2024-01-15)
  - VID_0042.MOV (45.6 MB, 2024-01-15)

=== Summary ===
  Total source files : 1243
  Synced             : 1241
  Missing            : 2
  Sync rate          : 99.84%
```

Pass `-Verbose` to see a breakdown of how many files are downloaded locally versus cloud-only:

```
VERBOSE: Found 1243 media file(s) in: /Volumes/iPhone/DCIM
VERBOSE: OneDrive index: 1241 file(s) in: /Users/you/.../OneDrive-Personal/Pictures  (800 downloaded locally, 441 cloud-only / not downloaded)
```

## How file comparison works without downloading

The OneDrive destination folder is scanned by `Get-OneDriveIndexFiles`, which reads **only directory-entry metadata** (name, size, last-write time) from the OneDrive local index.  File content is never opened, so **no file downloads or network transfers are triggered**.

| Platform | How cloud-only files are handled |
|---|---|
| **macOS** (CloudStorage / NSFileProvider) | All files — whether downloaded or cloud-only — appear in the filesystem with correct metadata. `Get-ChildItem` enumerates them without downloading. |
| **Windows** (Files On-Demand) | Cloud-only placeholder files carry `FileAttributes.Offline` (and/or `RecallOnDataAccess` on newer builds). Both flags are detected; the file is included in the comparison and reported as `IsCloudOnly = True` in verbose output. |

This means the script works correctly even when OneDrive is configured with **Files On-Demand** and very few (or no) files have been downloaded to the local disk.

## Running the tests

```bash
pwsh -Command "Invoke-Pester ./tests/Validate-OneDriveSync.Tests.ps1 -Output Detailed"
```
