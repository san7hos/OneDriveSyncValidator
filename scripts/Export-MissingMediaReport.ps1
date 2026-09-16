<#
.SYNOPSIS
Creates an optional heuristic metadata report for missing photos and videos.
.PARAMETER LocalRoot
Root used to create the local inventory.
.PARAMETER MissingCsv
Missing-content report created by Compare-OneDriveInventory.ps1.
.PARAMETER OutCsv
Destination metadata report.
.PARAMETER IncludeMacOSMetadata
Uses mdls when available. Other platforms explicitly report metadata as unavailable.
#>
[CmdletBinding()]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$LocalRoot,
    [ValidateNotNullOrEmpty()][string]$MissingCsv = "reports/missing-on-onedrive.csv",
    [ValidateNotNullOrEmpty()][string]$OutCsv = "reports/missing-media-provenance.csv",
    [switch]$IncludeMacOSMetadata
)

$ErrorActionPreference = "Stop"

function Get-ProvenanceAssessment {
    param($Item, [string]$Make, [string]$Model)
    if ($Make -eq "Apple" -and -not [string]::IsNullOrWhiteSpace($Model)) {
        return [PSCustomObject]@{ Assessment = "likely-apple-camera"; Confidence = "high"; Evidence = "embedded make/model: Apple $Model" }
    }
    if (-not [string]::IsNullOrWhiteSpace($Make) -and $Make -ne "Apple") {
        return [PSCustomObject]@{ Assessment = "likely-other-camera"; Confidence = "high"; Evidence = "embedded make: $Make" }
    }
    if ($Item.filename -match '^IMG_\d+' -and $Item.extension -in ".heic", ".heif", ".mov") {
        return [PSCustomObject]@{ Assessment = "possibly-ios-camera"; Confidence = "low"; Evidence = "filename and extension pattern only" }
    }
    [PSCustomObject]@{ Assessment = "unknown"; Confidence = "none"; Evidence = "insufficient metadata" }
}

function Get-MacOSMetadata {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not $IsMacOS -or -not (Get-Command mdls -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{
            Status = "unavailable"; CapturedAt = $null; CaptureDateSource = $null
            Make = $null; Model = $null
        }
    }
    $values = @{}
    foreach ($property in "kMDItemContentCreationDate", "kMDItemAcquisitionMake", "kMDItemAcquisitionModel") {
        $value = (& mdls -raw -nullMarker "__NO_VALUE__" -name $property -- $LiteralPath) -join ""
        if ($LASTEXITCODE -ne 0) {
            throw "mdls failed while reading '$LiteralPath'."
        }
        $values[$property] = if ($value -in "__NO_VALUE__", "(null)") { $null } else { $value.Trim() }
    }
    [PSCustomObject]@{
        Status = "available"
        CapturedAt = $values.kMDItemContentCreationDate
        CaptureDateSource = if ($values.kMDItemContentCreationDate) { "macOS Spotlight kMDItemContentCreationDate" } else { $null }
        Make = $values.kMDItemAcquisitionMake
        Model = $values.kMDItemAcquisitionModel
    }
}

function Export-MissingMediaReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][string]$MissingCsv,
        [Parameter(Mandatory)][string]$OutCsv,
        [switch]$IncludeMacOSMetadata
    )
    $root = (Resolve-Path -LiteralPath $LocalRoot).Path
    $rows = @(
        foreach ($item in @(Import-Csv -LiteralPath $MissingCsv)) {
            if ($item.mediaKind -notin "photo", "video") {
                continue
            }
            $candidate = Join-Path $root ([string]$item.relativePath)
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Write-Warning "Local file no longer exists: $candidate"
                continue
            }
            $metadata = if ($IncludeMacOSMetadata) {
                Get-MacOSMetadata -LiteralPath $candidate
            }
            else {
                [PSCustomObject]@{ Status = "not-requested"; CapturedAt = $null; CaptureDateSource = $null; Make = $null; Model = $null }
            }
            $assessment = Get-ProvenanceAssessment -Item ([PSCustomObject]@{
                filename = $item.filename
                extension = [IO.Path]::GetExtension([string]$item.filename).ToLowerInvariant()
            }) -Make $metadata.Make -Model $metadata.Model
            [PSCustomObject]@{
                filename = $item.filename; mediaKind = $item.mediaKind; size = [long]$item.size
                sha1 = $item.sha1; localPath = $candidate
                capturedAt = $metadata.CapturedAt; captureDateSource = $metadata.CaptureDateSource
                metadataStatus = $metadata.Status; provenanceAssessment = $assessment.Assessment
                provenanceConfidence = $assessment.Confidence; provenanceEvidence = $assessment.Evidence
            }
        }
    )
    $parent = Split-Path -Parent $OutCsv
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation
    if ($IncludeMacOSMetadata -and -not $IsMacOS) {
        Write-Warning "macOS metadata was requested but is unavailable on this platform; metadataStatus is 'unavailable'."
    }
    Write-Host "Exported $($rows.Count) missing media rows to $OutCsv." -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne ".") {
    if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
        throw "-LocalRoot is required."
    }
    Export-MissingMediaReport -LocalRoot $LocalRoot -MissingCsv $MissingCsv -OutCsv $OutCsv `
        -IncludeMacOSMetadata:$IncludeMacOSMetadata
}
