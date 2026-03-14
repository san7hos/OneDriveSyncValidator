# OneDriveSyncValidator

Scripts for macOS to validate that photos and videos from a connected iPhone have been synced correctly to OneDrive.

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
Scanning OneDrive files...
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

## Running the tests

```bash
pwsh -Command "Invoke-Pester ./tests/Validate-OneDriveSync.Tests.ps1 -Output Detailed"
```
