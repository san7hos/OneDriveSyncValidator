[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot "scripts/Get-OneDriveInventory.ps1")
. (Join-Path $repoRoot "scripts/New-LocalInventory.ps1")
. (Join-Path $repoRoot "scripts/Compare-OneDriveInventory.ps1")

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ($Expected -ne $Actual) {
        $failures.Add("$Because (expected '$Expected', got '$Actual')")
    }
}

$requestedUris = [System.Collections.Generic.List[string]]::new()
$pages = @{
    "https://graph.microsoft.com/v1.0/test" = [PSCustomObject]@{
        value = @([PSCustomObject]@{ id = "1" })
        '@odata.nextLink' = "https://graph.microsoft.com/v1.0/test?page=2"
    }
    "https://graph.microsoft.com/v1.0/test?page=2" = [PSCustomObject]@{
        value = @([PSCustomObject]@{ id = "2" })
    }
}
$items = @(Get-AllGraphCollectionItems -Uri "https://graph.microsoft.com/v1.0/test" -RequestInvoker {
    param($uri, $allowNotFound)
    $requestedUris.Add($uri)
    $pages[$uri]
})
Assert-Equal 2 $items.Count "Pagination returns every page"
Assert-Equal 2 $requestedUris.Count "Pagination follows nextLink exactly once"

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "onedrive validator path test $([guid]::NewGuid())"
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $tempRoot "folder with spaces") -Force)
    [IO.File]::WriteAllBytes((Join-Path $tempRoot "folder with spaces/empty file.jpg"), [byte[]]@())
    [IO.File]::WriteAllText((Join-Path $tempRoot "folder with spaces/photo.jpg"), "content")
    $local = @(Get-LocalInventory -LocalRoot $tempRoot -ProgressEvery 1)
    Assert-Equal 2 $local.Count "Literal paths with spaces are inventoried"
    $empty = $local | Where-Object filename -eq "empty file.jpg"
    Assert-Equal 0 $empty.size "Zero-byte size remains distinct"
    Assert-Equal "da39a3ee5e6b4b0d3255bfef95601890afd80709" $empty.sha1 "Zero-byte SHA-1 is retained"

    $remoteRows = @(
        [PSCustomObject]@{ filename = "empty file.jpg"; size = 0; sha1 = $empty.sha1; path = "Backup" }
        [PSCustomObject]@{ filename = "photo.jpg"; size = 7; sha1 = ("f" * 40); path = "Backup" }
        [PSCustomObject]@{ filename = "pending.jpg"; size = 10; sha1 = ""; path = "Backup" }
    )
    $comparison = Invoke-InventoryComparison -LocalRows $local -RemoteRows $remoteRows
    Assert-Equal 1 $comparison.Missing.Count "Comparison uses exact SHA-1 coverage"
    Assert-Equal "photo.jpg" $comparison.Missing[0].filename "Zero-byte matching content is not missing"
    Assert-Equal 1 $comparison.SameNameDifferentHash.Count "Same-name different-hash diagnostic is emitted"
    Assert-Equal 1 $comparison.SameSizeDifferentHash.Count "Same-size different-hash diagnostic is emitted"
    Assert-Equal 1 $comparison.RemoteHashlessCount "Hashless remote rows are counted"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Host "All 10 lightweight PowerShell assertions passed." -ForegroundColor Green
