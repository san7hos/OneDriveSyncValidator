<#
.SYNOPSIS
Creates a recursive local file inventory with exact SHA-1 hashes.
.PARAMETER LocalRoot
Existing directory to inventory. Literal path handling supports spaces and wildcard characters.
.PARAMETER OutCsv
Destination CSV path.
.PARAMETER ProgressEvery
Number of hashed files between progress updates.
#>
[CmdletBinding()]
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$LocalRoot,
    [ValidateNotNullOrEmpty()]
    [string]$OutCsv = "local-inventory.csv",
    [ValidateRange(1, 10000)]
    [int]$ProgressEvery = 250
)

$ErrorActionPreference = "Stop"

function Get-MediaKind {
    param([Parameter(Mandatory)][string]$Filename)
    $extension = [IO.Path]::GetExtension($Filename).ToLowerInvariant()
    if ($extension -in ".heic", ".heif", ".jpg", ".jpeg", ".png", ".dng", ".gif", ".tif", ".tiff", ".webp", ".raw", ".cr2", ".cr3", ".nef", ".arw") {
        return "photo"
    }
    if ($extension -in ".mov", ".mp4", ".m4v", ".avi", ".mts", ".m2ts", ".3gp", ".hevc", ".mkv", ".webm") {
        return "video"
    }
    if ($extension -in ".aae", ".xmp", ".thm", ".lrv", ".dop", ".pp3", ".json", ".xml") {
        return "sidecar"
    }
    "other"
}

function Get-LocalInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalRoot,
        [ValidateRange(1, 10000)][int]$ProgressEvery = 250
    )
    $root = (Resolve-Path -LiteralPath $LocalRoot).Path
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction Stop)
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        $sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1 -ErrorAction Stop).Hash.ToLowerInvariant()
        $relativePath = [IO.Path]::GetRelativePath($root, $file.FullName)
        [PSCustomObject]@{
            filename = $file.Name
            size = [long]$file.Length
            sha1 = $sha1
            path = [IO.Path]::GetDirectoryName($relativePath)
            relativePath = $relativePath
            mediaKind = Get-MediaKind -Filename $file.Name
        }
        if ((($index + 1) % $ProgressEvery) -eq 0 -or $index -eq $files.Count - 1) {
            Write-Progress -Activity "Hashing local files" -Status "$($index + 1) of $($files.Count)" `
                -PercentComplete ((($index + 1) / [Math]::Max(1, $files.Count)) * 100)
        }
    }
    Write-Progress -Activity "Hashing local files" -Completed
}

function Invoke-LocalInventoryExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][string]$OutCsv,
        [int]$ProgressEvery = 250
    )
    $rows = @(Get-LocalInventory -LocalRoot $LocalRoot -ProgressEvery $ProgressEvery)
    $parent = Split-Path -Parent $OutCsv
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $rows | Export-Csv -LiteralPath $OutCsv -NoTypeInformation
    Write-Host "Exported $($rows.Count) local files to $OutCsv." -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne ".") {
    if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
        throw "-LocalRoot is required."
    }
    Invoke-LocalInventoryExport -LocalRoot $LocalRoot -OutCsv $OutCsv -ProgressEvery $ProgressEvery
}
