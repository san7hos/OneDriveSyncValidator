# OneDrive Sync Validator

PowerShell tools for checking whether local files are present in OneDrive by exact SHA-1 content hash. The workflow inventories Microsoft Graph and a local directory independently, then compares them without treating filenames, timestamps, or sizes as proof of content coverage.

## Prerequisites

- PowerShell 7.2 or later on macOS, Windows, or Linux.
- The `Microsoft.Graph.Authentication` module:

  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```

- A Microsoft account that can grant delegated `Files.Read.All` permission. The Graph script signs in interactively and only reads metadata.

## End-to-end usage

Run commands from the repository root. Quote paths containing spaces.

```powershell
# 1. Inventory a OneDrive folder. Omit -DriveId to choose an accessible drive.
./scripts/Get-OneDriveInventory.ps1 `
  -StartPath "Pictures/Camera Roll" `
  -OutCsv "./onedrive-inventory.csv"

# To inventory the selected drive's entire root:
./scripts/Get-OneDriveInventory.ps1 -OutCsv "./onedrive-inventory.csv"

# 2. Hash all files below a local folder.
./scripts/New-LocalInventory.ps1 `
  -LocalRoot "/path/to/local/photos" `
  -OutCsv "./local-inventory.csv"

# 3. Compare exact content coverage and write reports.
./scripts/Compare-OneDriveInventory.ps1 `
  -LocalCsv "./local-inventory.csv" `
  -RemoteCsv "./onedrive-inventory.csv" `
  -ReportDirectory "./reports"
```

Use `Get-Help ./scripts/Get-OneDriveInventory.ps1 -Full` (and the equivalent command for the other scripts) to inspect parameters. Automation can avoid interactive drive selection with `-DriveId`; `-DriveName` is accepted only when it identifies exactly one drive.

The comparison creates:

- `missing-on-onedrive.csv`: local file rows whose SHA-1 is absent remotely.
- `remote-only.csv`: remote file rows whose SHA-1 is absent locally.
- `same-name-different-hash.csv`: missing local content with a remote filename match.
- `same-size-different-hash.csv`: missing local content with a remote size match.

Filename and size reports are diagnostics only. `mediaKind` distinguishes photos, videos, common sidecars, and other files; every kind still participates in exact coverage. Zero-byte files are not ignored: they retain size `0` and the standard empty-content SHA-1.

## Optional capture-date and provenance report

After comparison, create a media-only report:

```powershell
./scripts/Export-MissingMediaReport.ps1 `
  -LocalRoot "/path/to/local/photos" `
  -MissingCsv "./reports/missing-on-onedrive.csv" `
  -OutCsv "./reports/missing-media-provenance.csv" `
  -IncludeMacOSMetadata
```

This report is **heuristic** and does not change the hash comparison. On macOS, `-IncludeMacOSMetadata` reads Spotlight metadata with `mdls`. On other platforms it explicitly records metadata as unavailable. Filesystem creation time is deliberately not labeled as capture time. Apple make/model metadata is high-confidence evidence; filename/extension patterns alone are low confidence.

## Graph paging and retries

Every request uses a fully qualified `https://graph.microsoft.com/v1.0/...` URL. Collection requests follow the complete opaque `@odata.nextLink` chain, which is required even when a `$top` value is supplied. Folder traversal uses an iterative queue rather than recursion, so deep trees do not consume the PowerShell call stack. The script reports folder/file progress and counts files for which Graph returned no SHA-1.

HTTP 429, 500, 502, 503, and 504 responses are retried up to eight times by default. `Retry-After` is honored when present; otherwise capped exponential backoff with jitter is used. Other failures stop the inventory rather than producing a success-shaped partial export.

## Limitations and safety

- Graph does not always expose `sha1Hash`, particularly while an upload is processing or for some item types. Hashless remote rows are reported and cannot prove coverage.
- Results cover only the selected drive and `-StartPath`; an incomplete scope can create apparent misses.
- A local inventory is a point-in-time snapshot. Re-run it if files move or change.
- OneDrive File Provider placeholders and uploads may not be hydrated or fully processed yet. Wait for sync/upload completion before drawing conclusions.
- Same-name or same-size matches are not content matches. Only equal SHA-1 values count.
- The optional capture/provenance fields depend on available metadata and should not be used as definitive device attribution.
- CSVs can expose filenames, folder structure, item IDs, MIME types, and hashes. They are gitignored by default; review them before sharing and do not publish access tokens or Graph responses.

## Tests

The dependency-free test runner uses fixtures and injected Graph responses:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

It validates complete paging, exact comparison behavior, zero-byte hashing, hashless reporting, diagnostics, and literal paths containing spaces.
