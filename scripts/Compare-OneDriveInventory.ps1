<#
.SYNOPSIS
Compares local and OneDrive inventories by exact SHA-1 content coverage.
.PARAMETER LocalCsv
CSV created by New-LocalInventory.ps1.
.PARAMETER RemoteCsv
CSV created by Get-OneDriveInventory.ps1.
.PARAMETER ReportDirectory
Directory in which comparison reports are created.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$LocalCsv = "local-inventory.csv",
    [ValidateNotNullOrEmpty()][string]$RemoteCsv = "onedrive-inventory.csv",
    [ValidateNotNullOrEmpty()][string]$ReportDirectory = "."
)

$ErrorActionPreference = "Stop"

function ConvertTo-InventoryRow {
    param([Parameter(ValueFromPipeline)]$Row, [Parameter(Mandatory)][string]$Source)
    process {
        $size = 0L
        if ([string]::IsNullOrWhiteSpace([string]$Row.filename) -or
            -not [long]::TryParse([string]$Row.size, [ref]$size) -or $size -lt 0) {
            Write-Warning "Ignoring malformed $Source row for '$($Row.filename)'."
            return
        }
        [PSCustomObject]@{
            filename = ([string]$Row.filename).Trim()
            filenameKey = ([string]$Row.filename).Trim().ToLowerInvariant()
            size = $size
            sha1 = ([string]$Row.sha1).Trim().ToLowerInvariant()
            path = [string]$Row.path
            relativePath = [string]$Row.relativePath
            mediaKind = [string]$Row.mediaKind
        }
    }
}

function New-StringSet {
    ,([System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase))
}

function Invoke-InventoryComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$LocalRows,
        [Parameter(Mandatory)][object[]]$RemoteRows
    )
    $localAll = @($LocalRows | ConvertTo-InventoryRow -Source "local")
    $remoteAll = @($RemoteRows | ConvertTo-InventoryRow -Source "remote")
    $local = @($localAll | Where-Object { -not [string]::IsNullOrWhiteSpace($_.sha1) })
    $remote = @($remoteAll | Where-Object { -not [string]::IsNullOrWhiteSpace($_.sha1) })
    $localHashes = New-StringSet
    $remoteHashes = New-StringSet
    $local | ForEach-Object { [void]$localHashes.Add($_.sha1) }
    $remote | ForEach-Object { [void]$remoteHashes.Add($_.sha1) }

    $missing = @($local | Where-Object { -not $remoteHashes.Contains($_.sha1) })
    $remoteOnly = @($remote | Where-Object { -not $localHashes.Contains($_.sha1) })
    $remoteByName = $remote | Group-Object filenameKey -AsHashTable -AsString
    $remoteBySize = $remote | Group-Object { [string]$_.size } -AsHashTable -AsString
    $sameName = @(
        foreach ($item in $missing) {
            if ($remoteByName.ContainsKey($item.filenameKey)) {
                $matches = @($remoteByName[$item.filenameKey])
                [PSCustomObject]@{
                    localFilename = $item.filename; localPath = $item.relativePath
                    localSize = $item.size; localSha1 = $item.sha1
                    remoteMatchCount = $matches.Count; remoteSizes = $matches.size -join " | "
                    remoteSha1 = $matches.sha1 -join " | "; remotePaths = $matches.path -join " | "
                }
            }
        }
    )
    $sameSize = @(
        foreach ($item in $missing) {
            $key = [string]$item.size
            if ($remoteBySize.ContainsKey($key)) {
                $matches = @($remoteBySize[$key])
                [PSCustomObject]@{
                    localFilename = $item.filename; localPath = $item.relativePath
                    size = $item.size; localSha1 = $item.sha1
                    remoteMatchCount = $matches.Count; remoteFilenames = $matches.filename -join " | "
                    remoteSha1 = $matches.sha1 -join " | "; remotePaths = $matches.path -join " | "
                }
            }
        }
    )
    [PSCustomObject]@{
        LocalRows = $localAll
        RemoteRows = $remoteAll
        Missing = $missing
        RemoteOnly = $remoteOnly
        SameNameDifferentHash = $sameName
        SameSizeDifferentHash = $sameSize
        LocalHashCount = $localHashes.Count
        RemoteHashCount = $remoteHashes.Count
        LocalHashlessCount = $localAll.Count - $local.Count
        RemoteHashlessCount = $remoteAll.Count - $remote.Count
    }
}

function Export-InventoryComparison {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Comparison,
        [Parameter(Mandatory)][string]$ReportDirectory
    )
    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        [void](New-Item -ItemType Directory -Path $ReportDirectory -Force)
    }
    $directory = (Resolve-Path -LiteralPath $ReportDirectory).Path
    $Comparison.Missing | Select-Object filename, size, sha1, mediaKind, relativePath |
        Export-Csv -LiteralPath (Join-Path $directory "missing-on-onedrive.csv") -NoTypeInformation
    $Comparison.RemoteOnly | Select-Object filename, size, sha1, path |
        Export-Csv -LiteralPath (Join-Path $directory "remote-only.csv") -NoTypeInformation
    $Comparison.SameNameDifferentHash |
        Export-Csv -LiteralPath (Join-Path $directory "same-name-different-hash.csv") -NoTypeInformation
    $Comparison.SameSizeDifferentHash |
        Export-Csv -LiteralPath (Join-Path $directory "same-size-different-hash.csv") -NoTypeInformation
}

function Invoke-InventoryComparisonExport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalCsv,
        [Parameter(Mandatory)][string]$RemoteCsv,
        [Parameter(Mandatory)][string]$ReportDirectory
    )
    $comparison = Invoke-InventoryComparison -LocalRows @(Import-Csv -LiteralPath $LocalCsv) `
        -RemoteRows @(Import-Csv -LiteralPath $RemoteCsv)
    Export-InventoryComparison -Comparison $comparison -ReportDirectory $ReportDirectory

    Write-Host "Local rows / unique SHA-1:  $($comparison.LocalRows.Count) / $($comparison.LocalHashCount)"
    Write-Host "Remote rows / unique SHA-1: $($comparison.RemoteRows.Count) / $($comparison.RemoteHashCount)"
    Write-Host "Rows without SHA-1 (local / remote): $($comparison.LocalHashlessCount) / $($comparison.RemoteHashlessCount)"
    Write-Host "Missing local rows: $($comparison.Missing.Count)"
    Write-Host "Remote-only rows: $($comparison.RemoteOnly.Count)"
    Write-Host "Same name, different hash: $($comparison.SameNameDifferentHash.Count)"
    Write-Host "Same size, different hash: $($comparison.SameSizeDifferentHash.Count)"
    Write-Host "Reports written to $ReportDirectory." -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-InventoryComparisonExport -LocalCsv $LocalCsv -RemoteCsv $RemoteCsv `
        -ReportDirectory $ReportDirectory
}
