<#
.SYNOPSIS
Exports a fully paginated Microsoft Graph inventory for a OneDrive folder.
.PARAMETER StartPath
Drive-relative folder path. Leave empty to inventory the drive root.
.PARAMETER DriveId
Drive identifier for non-interactive use. If omitted, accessible drives are listed.
.PARAMETER DriveName
Case-insensitive drive name to select when it uniquely identifies one drive.
.PARAMETER OutCsv
Destination CSV path.
.PARAMETER ProgressEvery
Number of visited folders between console progress messages.
.PARAMETER MaxAttempts
Maximum attempts for transient Graph failures.
#>
[CmdletBinding()]
param(
    [string]$StartPath = "",
    [string]$DriveId,
    [string]$DriveName,
    [ValidateNotNullOrEmpty()]
    [string]$OutCsv = "onedrive-inventory.csv",
    [ValidateRange(1, 1000)]
    [int]$ProgressEvery = 25,
    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 8
)

$ErrorActionPreference = "Stop"

function ConvertTo-GraphPathSegment {
    param([Parameter(Mandatory)][string]$Value)
    [Uri]::EscapeDataString($Value)
}

function Invoke-GraphGetWithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateRange(1, 20)][int]$MaxAttempts = 8,
        [switch]$AllowNotFound
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
        }
        catch {
            $response = $_.Exception.Response
            $statusCode = 0
            if ($null -ne $response -and $null -ne $response.StatusCode) {
                $statusCode = [int]$response.StatusCode
            }

            if ($statusCode -eq 404 -and $AllowNotFound) {
                return $null
            }

            if ($statusCode -notin 429, 500, 502, 503, 504 -or $attempt -eq $MaxAttempts) {
                throw "Graph GET failed after $attempt attempt(s): $Uri (HTTP $statusCode). $($_.Exception.Message)"
            }

            $delaySeconds = 0
            if ($null -ne $response.Headers -and $null -ne $response.Headers.RetryAfter) {
                if ($null -ne $response.Headers.RetryAfter.Delta) {
                    $delaySeconds = [Math]::Ceiling($response.Headers.RetryAfter.Delta.TotalSeconds)
                }
                elseif ($null -ne $response.Headers.RetryAfter.Date) {
                    $delaySeconds = [Math]::Ceiling(
                        ($response.Headers.RetryAfter.Date.UtcDateTime - [DateTime]::UtcNow).TotalSeconds
                    )
                }
            }
            if ($delaySeconds -lt 1) {
                $delaySeconds = [Math]::Min(
                    60,
                    [Math]::Pow(2, $attempt - 1) + (Get-Random -Minimum 0 -Maximum 3)
                )
            }

            Write-Warning "Graph returned HTTP $statusCode. Retrying in $delaySeconds second(s) (attempt $attempt/$MaxAttempts)."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-AllGraphCollectionItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$AllowNotFound,
        [string]$Description = "Graph collection",
        [scriptblock]$RequestInvoker
    )

    if ($null -eq $RequestInvoker) {
        $RequestInvoker = { param($RequestUri, $NotFound) Invoke-GraphGetWithRetry -Uri $RequestUri -AllowNotFound:$NotFound }
    }

    $pageNumber = 0
    while (-not [string]::IsNullOrWhiteSpace($Uri)) {
        $pageNumber++
        $page = & $RequestInvoker $Uri ([bool]$AllowNotFound)
        if ($null -eq $page) {
            return
        }

        $pageItems = @($page.value)
        Write-Verbose "$Description page $pageNumber returned $($pageItems.Count) item(s)."
        foreach ($item in $pageItems) {
            Write-Output $item
        }
        $Uri = [string]$page.'@odata.nextLink'
    }
}

function Format-DriveSize {
    param($Bytes)
    $value = 0L
    if (-not [long]::TryParse([string]$Bytes, [ref]$value) -or $value -lt 0) {
        return "unknown"
    }
    "{0:N2} GB" -f ($value / 1GB)
}

function Get-DriveOwnerName {
    param([Parameter(Mandatory)]$Drive)
    foreach ($owner in @($Drive.owner.user, $Drive.owner.group, $Drive.owner.organization)) {
        if ($null -ne $owner -and -not [string]::IsNullOrWhiteSpace([string]$owner.displayName)) {
            $label = [string]$owner.displayName
            if (-not [string]::IsNullOrWhiteSpace([string]$owner.email)) {
                $label += " <$($owner.email)>"
            }
            return $label
        }
    }
    "unknown"
}

function Show-GraphDriveChoices {
    param([Parameter(Mandatory)][object[]]$Drives)
    Write-Host "`nAccessible drives:" -ForegroundColor Yellow
    for ($index = 0; $index -lt $Drives.Count; $index++) {
        $drive = $Drives[$index]
        $name = if ([string]::IsNullOrWhiteSpace([string]$drive.name)) { "(unnamed)" } else { $drive.name }
        $storage = if ($null -eq $drive.quota) {
            "unknown"
        }
        else {
            "$(Format-DriveSize $drive.quota.used) used of $(Format-DriveSize $drive.quota.total) [$($drive.quota.state)]"
        }
        Write-Host "`n[$($index + 1)] $name" -ForegroundColor Cyan
        Write-Host "    Type:     $($drive.driveType)"
        Write-Host "    Owner:    $(Get-DriveOwnerName $drive)"
        Write-Host "    Storage:  $storage"
        Write-Host "    Web URL:  $($drive.webUrl)"
        Write-Host "    Drive ID: $($drive.id)"
    }
}

function Select-GraphDrive {
    param(
        [Parameter(Mandatory)][object[]]$Drives,
        [string]$DriveName
    )
    if ($Drives.Count -eq 0) {
        throw "No accessible drives were returned by Microsoft Graph."
    }
    if (-not [string]::IsNullOrWhiteSpace($DriveName)) {
        $matches = @($Drives | Where-Object {
            ([string]$_.name).Equals($DriveName, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
        Show-GraphDriveChoices -Drives $Drives
        throw "Drive name '$DriveName' matched $($matches.Count) drives. Use -DriveId or select interactively."
    }
    if ($Drives.Count -eq 1) {
        return $Drives[0]
    }

    Show-GraphDriveChoices -Drives $Drives
    while ($true) {
        $answer = Read-Host "Select a drive by number (1-$($Drives.Count))"
        $selectedIndex = 0
        if ([int]::TryParse($answer, [ref]$selectedIndex) -and $selectedIndex -in 1..$Drives.Count) {
            return $Drives[$selectedIndex - 1]
        }
        Write-Warning "Enter a number from 1 through $($Drives.Count)."
    }
}

function Get-AllDriveItemChildren {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$ItemId,
        [ValidateRange(1, 20)][int]$MaxAttempts = 8,
        [scriptblock]$RequestInvoker
    )
    $uri = 'https://graph.microsoft.com/v1.0/drives/{0}/items/{1}/children?$select=id,name,size,file,folder&$top=200' -f `
        (ConvertTo-GraphPathSegment $DriveId), (ConvertTo-GraphPathSegment $ItemId)
    if ($null -eq $RequestInvoker) {
        $RequestInvoker = {
            param($RequestUri, $NotFound)
            Invoke-GraphGetWithRetry -Uri $RequestUri -MaxAttempts $MaxAttempts -AllowNotFound:$NotFound
        }.GetNewClosure()
    }
    Get-AllGraphCollectionItems -Uri $uri -Description "Folder item $ItemId" -RequestInvoker $RequestInvoker
}

function Get-OneDriveInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$RootItemId,
        [string]$RootPath = "",
        [ValidateRange(1, 1000)][int]$ProgressEvery = 25,
        [ValidateRange(1, 20)][int]$MaxAttempts = 8,
        [scriptblock]$ChildrenProvider
    )
    if ($null -eq $ChildrenProvider) {
        $ChildrenProvider = {
            param($CurrentDriveId, $CurrentItemId)
            Get-AllDriveItemChildren -DriveId $CurrentDriveId -ItemId $CurrentItemId -MaxAttempts $MaxAttempts
        }.GetNewClosure()
    }

    $folders = [System.Collections.Generic.Queue[object]]::new()
    $folders.Enqueue([PSCustomObject]@{ Id = $RootItemId; Path = $RootPath.Trim("/") })
    $results = [System.Collections.Generic.List[object]]::new()
    $foldersVisited = 0
    $filesWithoutSha1 = 0

    while ($folders.Count -gt 0) {
        $folder = $folders.Dequeue()
        $foldersVisited++
        foreach ($child in @(& $ChildrenProvider $DriveId $folder.Id)) {
            $childPath = (@($folder.Path, [string]$child.name) | Where-Object { $_ }) -join "/"
            if ($null -ne $child.folder) {
                $folders.Enqueue([PSCustomObject]@{ Id = [string]$child.id; Path = $childPath })
            }
            elseif ($null -ne $child.file) {
                $sha1 = [string]$child.file.hashes.sha1Hash
                if ([string]::IsNullOrWhiteSpace($sha1)) {
                    $filesWithoutSha1++
                }
                $results.Add([PSCustomObject]@{
                    filename = [string]$child.name
                    size = [long]$child.size
                    sha1 = $sha1.Trim().ToLowerInvariant()
                    path = [string]$folder.Path
                    itemId = [string]$child.id
                    mimeType = [string]$child.file.mimeType
                })
            }
        }

        if (($foldersVisited % $ProgressEvery) -eq 0 -or $folders.Count -eq 0) {
            Write-Host ("Visited {0:N0} folders; found {1:N0} files; {2:N0} folders queued." -f `
                $foldersVisited, $results.Count, $folders.Count)
        }
        Write-Progress -Activity "Enumerating OneDrive" `
            -Status "$foldersVisited folders visited; $($results.Count) files found" -PercentComplete -1
    }

    Write-Progress -Activity "Enumerating OneDrive" -Completed
    Write-Host "Files without a Graph SHA-1 value: $filesWithoutSha1"
    $results
}

function Invoke-OneDriveInventoryExport {
    [CmdletBinding()]
    param(
        [string]$StartPath = "",
        [string]$DriveId,
        [string]$DriveName,
        [Parameter(Mandatory)][string]$OutCsv,
        [int]$ProgressEvery = 25,
        [int]$MaxAttempts = 8
    )
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Connect-MgGraph -Scopes "Files.Read.All" -NoWelcome

    if ([string]::IsNullOrWhiteSpace($DriveId)) {
        $driveUri = 'https://graph.microsoft.com/v1.0/me/drives?$select=id,name,description,driveType,owner,quota,webUrl&$top=100'
        $requestInvoker = {
            param($RequestUri, $NotFound)
            Invoke-GraphGetWithRetry -Uri $RequestUri -MaxAttempts $MaxAttempts -AllowNotFound:$NotFound
        }.GetNewClosure()
        $drives = @(Get-AllGraphCollectionItems -Uri $driveUri -Description "Accessible drives" `
            -RequestInvoker $requestInvoker)
        $DriveId = [string](Select-GraphDrive -Drives $drives -DriveName $DriveName).id
    }
    if ([string]::IsNullOrWhiteSpace($DriveId)) {
        throw "Could not resolve a OneDrive drive ID."
    }

    $encodedDriveId = ConvertTo-GraphPathSegment $DriveId
    if ([string]::IsNullOrWhiteSpace($StartPath)) {
        $startItemUri = 'https://graph.microsoft.com/v1.0/drives/{0}/root?$select=id,name,folder' -f $encodedDriveId
    }
    else {
        $encodedPath = ($StartPath.Trim("/") -split "/" | ForEach-Object { ConvertTo-GraphPathSegment $_ }) -join "/"
        $startItemUri = 'https://graph.microsoft.com/v1.0/drives/{0}/root:/{1}?$select=id,name,folder' -f `
            $encodedDriveId, $encodedPath
    }
    $startItem = Invoke-GraphGetWithRetry -Uri $startItemUri -MaxAttempts $MaxAttempts
    if ($null -eq $startItem.folder) {
        throw "The start path '$StartPath' is not a folder."
    }

    $items = @(Get-OneDriveInventory -DriveId $DriveId -RootItemId ([string]$startItem.id) `
        -RootPath $StartPath -ProgressEvery $ProgressEvery -MaxAttempts $MaxAttempts)
    $parent = Split-Path -Parent $OutCsv
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $items | Export-Csv -LiteralPath $OutCsv -NoTypeInformation
    Write-Host "Exported $($items.Count) files to $OutCsv." -ForegroundColor Green
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-OneDriveInventoryExport -StartPath $StartPath -DriveId $DriveId -DriveName $DriveName `
        -OutCsv $OutCsv -ProgressEvery $ProgressEvery -MaxAttempts $MaxAttempts
}
