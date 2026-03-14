#Requires -Version 7.0

<#
.SYNOPSIS
    Validates that photos and videos from a connected iPhone have been synced to OneDrive.

.DESCRIPTION
    Compares media files (photos and videos) between an iPhone source path and a
    OneDrive destination folder to identify any files that have not been synced.
    Supports auto-detection of iPhone mount points and OneDrive paths on macOS.

    Exit code equals the number of missing files (0 = fully synced).

.PARAMETER SourcePath
    Path to the iPhone DCIM folder or a local import folder containing iPhone media.
    If not specified, the script attempts to auto-detect a connected iPhone under /Volumes.

.PARAMETER OneDrivePath
    Path to the OneDrive folder where photos/videos should be synced.
    If not specified, the script attempts to auto-detect the OneDrive folder under
    ~/Library/CloudStorage or ~/OneDrive.

.PARAMETER Extensions
    Array of file extensions to include in the comparison.
    Defaults to common iPhone photo and video formats:
    .jpg .jpeg .heic .heif .png .gif .tif .tiff .mp4 .mov .m4v .3gp

.PARAMETER CompareBySize
    When specified, a file is considered synced only when both the name AND the size
    match a file in the destination.  Without this flag only the filename is compared.

.PARAMETER ReportPath
    Optional path for a CSV file that will contain the full per-file results.

.EXAMPLE
    pwsh ./src/Validate-OneDriveSync.ps1

    Auto-detects the iPhone DCIM folder and OneDrive path, then runs the validation.

.EXAMPLE
    pwsh ./src/Validate-OneDriveSync.ps1 `
        -SourcePath /Volumes/iPhone/DCIM `
        -OneDrivePath ~/OneDrive/Pictures

    Runs validation with explicit paths.

.EXAMPLE
    pwsh ./src/Validate-OneDriveSync.ps1 -CompareBySize -ReportPath ./sync-report.csv

    Also validates file sizes and exports a full CSV report.

.NOTES
    Requires PowerShell 7.0 or later (pwsh).
    Designed for macOS with an iPhone connected via USB or mounted with ifuse.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$SourcePath,

    [Parameter()]
    [string]$OneDrivePath,

    [Parameter()]
    [string[]]$Extensions = @(
        '.jpg', '.jpeg', '.heic', '.heif', '.png', '.gif', '.tif', '.tiff',
        '.mp4', '.mov', '.m4v', '.3gp'
    ),

    [Parameter()]
    [switch]$CompareBySize,

    [Parameter()]
    [string]$ReportPath
)

#region Helper Functions

function Find-IPhonePath {
    <#
    .SYNOPSIS
        Attempts to auto-detect an iPhone DCIM folder under /Volumes on macOS.
    .OUTPUTS
        [string] Full path to the DCIM folder, or $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-Path '/Volumes')) {
        return $null
    }

    $dcimPath = Get-ChildItem -Path '/Volumes' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'DCIM' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1

    if ($dcimPath) {
        Write-Verbose "Auto-detected iPhone DCIM at: $dcimPath"
    }

    return $dcimPath
}

function Find-OneDrivePath {
    <#
    .SYNOPSIS
        Attempts to auto-detect the local OneDrive sync folder on macOS.
    .OUTPUTS
        [string] Full path to the OneDrive folder, or $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $homePath = if (-not [string]::IsNullOrEmpty($env:HOME)) { $env:HOME } else { $env:USERPROFILE }

    # Newer macOS stores cloud storage under ~/Library/CloudStorage
    $cloudStorage = Join-Path $homePath 'Library/CloudStorage'
    if (Test-Path $cloudStorage) {
        $found = Get-ChildItem -Path $cloudStorage -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'OneDrive*' } |
            Select-Object -First 1 -ExpandProperty FullName
        if ($found) {
            Write-Verbose "Auto-detected OneDrive at: $found"
            return $found
        }
    }

    # Older / Windows-style direct folder names
    foreach ($candidate in @('OneDrive', 'OneDrive - Personal')) {
        $full = Join-Path $homePath $candidate
        if (Test-Path $full) {
            Write-Verbose "Auto-detected OneDrive at: $full"
            return $full
        }
    }

    return $null
}

function Get-MediaFiles {
    <#
    .SYNOPSIS
        Returns all media files in a directory tree whose extensions match the list.
    .PARAMETER Path
        Root directory to scan recursively.
    .PARAMETER Extensions
        Array of lower-case file extensions to include (e.g. '.jpg', '.heic').
    .OUTPUTS
        [System.IO.FileInfo[]]
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Extensions
    )

    $normalised = $Extensions | ForEach-Object { $_.ToLowerInvariant() }

    $files = Get-ChildItem -Path $Path -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $normalised -contains $_.Extension.ToLowerInvariant() }

    Write-Verbose "Found $($files.Count) media file(s) in: $Path"
    return $files
}

function Build-FileIndex {
    <#
    .SYNOPSIS
        Builds a hashtable lookup from an array of FileInfo objects.
    .PARAMETER Files
        FileInfo objects to index.
    .PARAMETER BySize
        When $true the key is '<lowercased-name>:<length-in-bytes>';
        otherwise the key is just the lowercased file name.
    .OUTPUTS
        [hashtable]  key -> list of matching FileInfo objects
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.IO.FileInfo[]]$Files,

        [Parameter()]
        [bool]$BySize = $false
    )

    $index = @{}
    foreach ($file in $Files) {
        $key = if ($BySize) {
            "$($file.Name.ToLowerInvariant()):$($file.Length)"
        } else {
            $file.Name.ToLowerInvariant()
        }

        if (-not $index.ContainsKey($key)) {
            $index[$key] = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        }
        $index[$key].Add($file)
    }

    return $index
}

function Compare-MediaFiles {
    <#
    .SYNOPSIS
        Compares source media files against the destination to find unsynced files.
    .PARAMETER SourceFiles
        FileInfo objects from the source (iPhone).
    .PARAMETER DestinationFiles
        FileInfo objects from the destination (OneDrive).
    .PARAMETER CompareBySize
        When $true a match requires both filename and file-size to agree.
    .OUTPUTS
        [PSCustomObject[]] with properties:
          FileName, SourcePath, SizeBytes, SizeMB, LastWriteTime, Status
          Status is either 'Synced' or 'Missing'.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.IO.FileInfo[]]$SourceFiles,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.IO.FileInfo[]]$DestinationFiles,

        [Parameter()]
        [bool]$CompareBySize = $false
    )

    $destIndex = Build-FileIndex -Files $DestinationFiles -BySize $CompareBySize

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($file in $SourceFiles) {
        $key = if ($CompareBySize) {
            "$($file.Name.ToLowerInvariant()):$($file.Length)"
        } else {
            $file.Name.ToLowerInvariant()
        }

        $status = if ($destIndex.ContainsKey($key)) { 'Synced' } else { 'Missing' }

        $results.Add([PSCustomObject]@{
            FileName      = $file.Name
            SourcePath    = $file.FullName
            SizeBytes     = $file.Length
            SizeMB        = [math]::Round($file.Length / 1MB, 2)
            LastWriteTime = $file.LastWriteTime
            Status        = $status
        })
    }

    return $results.ToArray()
}

function Format-SyncReport {
    <#
    .SYNOPSIS
        Writes a human-readable sync report to the host and returns the missing-file count.
    .PARAMETER Results
        Output from Compare-MediaFiles.
    .PARAMETER SourcePath
        Source path used for the scan (shown in the header).
    .PARAMETER OneDrivePath
        OneDrive path used for the scan (shown in the header).
    .OUTPUTS
        [int] Number of missing files.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$Results,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$OneDrivePath
    )

    $missing = @($Results | Where-Object { $_.Status -eq 'Missing' })
    $synced  = @($Results | Where-Object { $_.Status -eq 'Synced' })
    $total   = $Results.Count
    $syncRateDisplay = if ($total -gt 0) {
        "$([math]::Round(($synced.Count / $total) * 100, 2))%"
    } else {
        'N/A (no source files found)'
    }

    Write-Host ''
    Write-Host '=== OneDrive Sync Validation Report ===' -ForegroundColor Cyan
    Write-Host "Source (iPhone) : $SourcePath"
    Write-Host "Destination     : $OneDrivePath"
    Write-Host ''

    if ($missing.Count -gt 0) {
        Write-Host "Missing files ($($missing.Count)):" -ForegroundColor Yellow
        foreach ($file in $missing) {
            $date = $file.LastWriteTime.ToString('yyyy-MM-dd')
            Write-Host "  - $($file.FileName) ($($file.SizeMB) MB, $date)" -ForegroundColor Red
        }
        Write-Host ''
    }

    Write-Host '=== Summary ===' -ForegroundColor Cyan
    Write-Host "  Total source files : $total"
    Write-Host "  Synced             : $($synced.Count)" -ForegroundColor Green
    $missingColour = if ($missing.Count -gt 0) { 'Red' } else { 'Green' }
    Write-Host "  Missing            : $($missing.Count)" -ForegroundColor $missingColour
    $rateColour = if ($total -eq 0 -or $missing.Count -gt 0) { 'Yellow' } else { 'Green' }
    Write-Host "  Sync rate          : $syncRateDisplay" -ForegroundColor $rateColour
    Write-Host ''

    return $missing.Count
}

#endregion

#region Main Execution

# Guard: when the script is dot-sourced (e.g. in tests), only the function
# definitions above are loaded; the executable body below is skipped.
if ($MyInvocation.InvocationName -ne '.') {

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve source path
if (-not $SourcePath) {
    $SourcePath = Find-IPhonePath
    if (-not $SourcePath) {
        Write-Error 'Could not auto-detect an iPhone mount point. Please specify -SourcePath.'
        exit 1
    }
}

if (-not (Test-Path $SourcePath)) {
    Write-Error "Source path does not exist: $SourcePath"
    exit 1
}

# Resolve OneDrive path
if (-not $OneDrivePath) {
    $OneDrivePath = Find-OneDrivePath
    if (-not $OneDrivePath) {
        Write-Error 'Could not auto-detect a OneDrive folder. Please specify -OneDrivePath.'
        exit 1
    }
}

if (-not (Test-Path $OneDrivePath)) {
    Write-Error "OneDrive path does not exist: $OneDrivePath"
    exit 1
}

Write-Host 'Scanning source files...' -ForegroundColor Cyan
$sourceFiles = Get-MediaFiles -Path $SourcePath -Extensions $Extensions

Write-Host 'Scanning OneDrive files...' -ForegroundColor Cyan
$destFiles = Get-MediaFiles -Path $OneDrivePath -Extensions $Extensions

Write-Host 'Comparing files...'
$results = Compare-MediaFiles `
    -SourceFiles $sourceFiles `
    -DestinationFiles $destFiles `
    -CompareBySize $CompareBySize.IsPresent

$missingCount = Format-SyncReport -Results $results -SourcePath $SourcePath -OneDrivePath $OneDrivePath

if ($ReportPath) {
    $results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Report exported to: $ReportPath" -ForegroundColor Cyan
}

# Non-zero exit code signals missing files (useful for CI/automation)
exit $missingCount

} # end if ($MyInvocation.InvocationName -ne '.')

#endregion
