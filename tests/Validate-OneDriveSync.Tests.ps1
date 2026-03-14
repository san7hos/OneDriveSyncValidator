#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Pester 5 unit tests for Validate-OneDriveSync.ps1
#>

BeforeAll {
    # Dot-sourcing loads only the helper functions; the main execution block is
    # guarded by an InvocationName check and is therefore skipped.
    $scriptPath = Join-Path $PSScriptRoot '../src/Validate-OneDriveSync.ps1'
    . $scriptPath

    # Byte size used when creating placeholder test files.
    # Using a small, non-zero value keeps test I/O fast while still
    # exercising the size-comparison logic.
    $script:TestFileSize = 512
}

# ---------------------------------------------------------------------------
# Describe: Get-MediaFiles
# ---------------------------------------------------------------------------
Describe 'Get-MediaFiles' {

    Context 'when directory contains mixed file types' {
        BeforeAll {
            $dir = Join-Path $TestDrive 'media_mixed'
            $null = New-Item -ItemType Directory -Path $dir -Force
            'photo.jpg', 'video.mov', 'document.pdf', 'audio.mp3' | ForEach-Object {
                [System.IO.File]::WriteAllBytes((Join-Path $dir $_), [byte[]]::new($TestFileSize))
            }
        }

        It 'returns only files whose extensions match the list' {
            $result = Get-MediaFiles -Path $dir -Extensions @('.jpg', '.mov')
            $result.Count | Should -Be 2
            $result.Name | Should -Contain 'photo.jpg'
            $result.Name | Should -Contain 'video.mov'
        }

        It 'returns zero results when no files match' {
            $result = Get-MediaFiles -Path $dir -Extensions @('.heic')
            $result | Should -BeNullOrEmpty
        }

        It 'performs a case-insensitive extension comparison' {
            $upper = Join-Path $TestDrive 'media_upper'
            $null = New-Item -ItemType Directory -Path $upper -Force
            [System.IO.File]::WriteAllBytes((Join-Path $upper 'IMG_001.JPG'), [byte[]]::new($TestFileSize))
            $result = Get-MediaFiles -Path $upper -Extensions @('.jpg')
            $result.Count | Should -Be 1
        }
    }

    Context 'when directory contains subdirectories (DCIM-style layout)' {
        BeforeAll {
            $root = Join-Path $TestDrive 'dcim_root'
            $sub1 = Join-Path $root '100APPLE'
            $sub2 = Join-Path $root '101APPLE'
            $null = New-Item -ItemType Directory -Path $sub1 -Force
            $null = New-Item -ItemType Directory -Path $sub2 -Force
            [System.IO.File]::WriteAllBytes((Join-Path $sub1 'IMG_0001.HEIC'), [byte[]]::new($TestFileSize))
            [System.IO.File]::WriteAllBytes((Join-Path $sub2 'IMG_0002.JPG'),  [byte[]]::new($TestFileSize))
        }

        It 'recursively finds files in sub-directories' {
            $result = Get-MediaFiles -Path $root -Extensions @('.heic', '.jpg')
            $result.Count | Should -Be 2
        }
    }

    Context 'when directory is empty' {
        BeforeAll {
            $empty = Join-Path $TestDrive 'empty_dir'
            $null = New-Item -ItemType Directory -Path $empty -Force
        }

        It 'returns an empty collection' {
            $result = Get-MediaFiles -Path $empty -Extensions @('.jpg', '.mov')
            $result | Should -BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------------------
# Describe: Build-FileIndex
# ---------------------------------------------------------------------------
Describe 'Build-FileIndex' {

    BeforeAll {
        $fileDir = Join-Path $TestDrive 'index_files'
        $null = New-Item -ItemType Directory -Path $fileDir -Force
        [System.IO.File]::WriteAllBytes((Join-Path $fileDir 'IMG_001.jpg'),  [byte[]]::new(1000))
        [System.IO.File]::WriteAllBytes((Join-Path $fileDir 'IMG_002.HEIC'), [byte[]]::new(2000))
        $script:indexFiles = Get-ChildItem -Path $fileDir -File
    }

    It 'keys by lower-cased filename when BySize is false' {
        $index = Build-FileIndex -Files $indexFiles -BySize $false
        $index.ContainsKey('img_001.jpg')  | Should -BeTrue
        $index.ContainsKey('img_002.heic') | Should -BeTrue
        $index.Count | Should -Be 2
    }

    It 'keys by lower-cased filename:size when BySize is true' {
        $index = Build-FileIndex -Files $indexFiles -BySize $true
        $index.ContainsKey('img_001.jpg:1000')  | Should -BeTrue
        $index.ContainsKey('img_002.heic:2000') | Should -BeTrue
    }

    It 'handles duplicate filenames (files with same name in different sub-dirs)' {
        $dupDir = Join-Path $TestDrive 'dup_index'
        $subA   = Join-Path $dupDir 'a'
        $subB   = Join-Path $dupDir 'b'
        $null = New-Item -ItemType Directory -Path $subA -Force
        $null = New-Item -ItemType Directory -Path $subB -Force
        [System.IO.File]::WriteAllBytes((Join-Path $subA 'IMG_001.jpg'), [byte[]]::new($TestFileSize))
        [System.IO.File]::WriteAllBytes((Join-Path $subB 'IMG_001.jpg'), [byte[]]::new($TestFileSize))

        $dupFiles = Get-ChildItem -Path $dupDir -File -Recurse
        $index = Build-FileIndex -Files $dupFiles -BySize $false
        $index['img_001.jpg'].Count | Should -Be 2
    }

    It 'returns an empty hashtable when given an empty collection' {
        $index = Build-FileIndex -Files @() -BySize $false
        $index.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Describe: Compare-MediaFiles
# ---------------------------------------------------------------------------
Describe 'Compare-MediaFiles' {

    BeforeAll {
        $srcDir  = Join-Path $TestDrive 'cmp_src'
        $destDir = Join-Path $TestDrive 'cmp_dest'
        $null = New-Item -ItemType Directory -Path $srcDir  -Force
        $null = New-Item -ItemType Directory -Path $destDir -Force

        # Source: 3 files
        [System.IO.File]::WriteAllBytes((Join-Path $srcDir  'IMG_001.jpg'),  [byte[]]::new(1000))
        [System.IO.File]::WriteAllBytes((Join-Path $srcDir  'IMG_002.heic'), [byte[]]::new(2000))
        [System.IO.File]::WriteAllBytes((Join-Path $srcDir  'VID_001.mov'),  [byte[]]::new(5000))

        # Destination: 2 of the 3 files (IMG_002 is missing)
        [System.IO.File]::WriteAllBytes((Join-Path $destDir 'IMG_001.jpg'), [byte[]]::new(1000))
        [System.IO.File]::WriteAllBytes((Join-Path $destDir 'VID_001.mov'), [byte[]]::new(5000))

        $script:cmpSrcFiles  = Get-ChildItem -Path $srcDir  -File
        $script:cmpDestFiles = Get-ChildItem -Path $destDir -File
    }

    It 'marks files present in destination as Synced' {
        $results = Compare-MediaFiles -SourceFiles $cmpSrcFiles -DestinationFiles $cmpDestFiles
        $synced  = $results | Where-Object { $_.Status -eq 'Synced' }
        $synced.Count | Should -Be 2
        $synced.FileName | Should -Contain 'IMG_001.jpg'
        $synced.FileName | Should -Contain 'VID_001.mov'
    }

    It 'marks files absent from destination as Missing' {
        $results = Compare-MediaFiles -SourceFiles $cmpSrcFiles -DestinationFiles $cmpDestFiles
        $missing = $results | Where-Object { $_.Status -eq 'Missing' }
        $missing.Count | Should -Be 1
        $missing[0].FileName | Should -Be 'IMG_002.heic'
    }

    It 'returns a result row for every source file' {
        $results = Compare-MediaFiles -SourceFiles $cmpSrcFiles -DestinationFiles $cmpDestFiles
        $results.Count | Should -Be 3
    }

    It 'includes expected properties in each result object' {
        $results = Compare-MediaFiles -SourceFiles $cmpSrcFiles -DestinationFiles $cmpDestFiles
        $row = $results[0]
        $row.PSObject.Properties.Name | Should -Contain 'FileName'
        $row.PSObject.Properties.Name | Should -Contain 'SourcePath'
        $row.PSObject.Properties.Name | Should -Contain 'SizeBytes'
        $row.PSObject.Properties.Name | Should -Contain 'SizeMB'
        $row.PSObject.Properties.Name | Should -Contain 'LastWriteTime'
        $row.PSObject.Properties.Name | Should -Contain 'Status'
    }

    It 'returns all Synced when source equals destination' {
        $dir = Join-Path $TestDrive 'same_dir'
        $null = New-Item -ItemType Directory -Path $dir -Force
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'A.jpg'), [byte[]]::new(100))
        $f = Get-ChildItem -Path $dir -File
        $results = Compare-MediaFiles -SourceFiles $f -DestinationFiles $f
        $results | ForEach-Object { $_.Status | Should -Be 'Synced' }
    }

    It 'returns all Missing when destination is empty' {
        $results = Compare-MediaFiles -SourceFiles $cmpSrcFiles -DestinationFiles @()
        $results | ForEach-Object { $_.Status | Should -Be 'Missing' }
    }

    It 'returns an empty result when source is empty' {
        $results = Compare-MediaFiles -SourceFiles @() -DestinationFiles $cmpDestFiles
        $results | Should -BeNullOrEmpty
    }

    Context 'CompareBySize mode' {
        BeforeAll {
            $sizeDir     = Join-Path $TestDrive 'size_src'
            $sizeDestDir = Join-Path $TestDrive 'size_dest'
            $null = New-Item -ItemType Directory -Path $sizeDir     -Force
            $null = New-Item -ItemType Directory -Path $sizeDestDir -Force

            # Same name, different sizes
            [System.IO.File]::WriteAllBytes((Join-Path $sizeDir     'IMG_010.jpg'), [byte[]]::new(1000))
            [System.IO.File]::WriteAllBytes((Join-Path $sizeDestDir 'IMG_010.jpg'), [byte[]]::new(999))

            $script:sizeSrc  = Get-ChildItem -Path $sizeDir     -File
            $script:sizeDest = Get-ChildItem -Path $sizeDestDir -File
        }

        It 'marks file as Missing when sizes differ and CompareBySize is true' {
            $results = Compare-MediaFiles -SourceFiles $sizeSrc -DestinationFiles $sizeDest -CompareBySize $true
            $results[0].Status | Should -Be 'Missing'
        }

        It 'marks file as Synced when sizes differ but CompareBySize is false' {
            $results = Compare-MediaFiles -SourceFiles $sizeSrc -DestinationFiles $sizeDest -CompareBySize $false
            $results[0].Status | Should -Be 'Synced'
        }
    }
}

# ---------------------------------------------------------------------------
# Describe: Format-SyncReport
# ---------------------------------------------------------------------------
Describe 'Format-SyncReport' {

    It 'returns 0 when all files are synced' {
        $results = @(
            [PSCustomObject]@{ FileName = 'A.jpg'; SourcePath = '/src/A.jpg'; SizeBytes = 100; SizeMB = 0; LastWriteTime = (Get-Date); Status = 'Synced' }
            [PSCustomObject]@{ FileName = 'B.mov'; SourcePath = '/src/B.mov'; SizeBytes = 200; SizeMB = 0; LastWriteTime = (Get-Date); Status = 'Synced' }
        )
        $count = Format-SyncReport -Results $results -SourcePath '/iphone/DCIM' -OneDrivePath '/onedrive'
        $count | Should -Be 0
    }

    It 'returns the number of missing files' {
        $results = @(
            [PSCustomObject]@{ FileName = 'A.jpg';  SourcePath = '/src/A.jpg';  SizeBytes = 100; SizeMB = 0; LastWriteTime = (Get-Date); Status = 'Synced'  }
            [PSCustomObject]@{ FileName = 'B.mov';  SourcePath = '/src/B.mov';  SizeBytes = 200; SizeMB = 0; LastWriteTime = (Get-Date); Status = 'Missing' }
            [PSCustomObject]@{ FileName = 'C.heic'; SourcePath = '/src/C.heic'; SizeBytes = 300; SizeMB = 0; LastWriteTime = (Get-Date); Status = 'Missing' }
        )
        $count = Format-SyncReport -Results $results -SourcePath '/iphone/DCIM' -OneDrivePath '/onedrive'
        $count | Should -Be 2
    }

    It 'returns 0 when results list is empty' {
        $count = Format-SyncReport -Results @() -SourcePath '/iphone/DCIM' -OneDrivePath '/onedrive'
        $count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# Describe: Find-OneDrivePath
# ---------------------------------------------------------------------------
Describe 'Find-OneDrivePath' {

    BeforeAll {
        $script:originalHome = $env:HOME
    }

    AfterAll {
        $env:HOME = $script:originalHome
    }

    It 'finds a OneDrive folder under a simulated CloudStorage path' {
        $fakeHome     = Join-Path $TestDrive 'fake_home_cs'
        $cloudStorage = Join-Path $fakeHome 'Library/CloudStorage/OneDrive-Personal'
        $null = New-Item -ItemType Directory -Path $cloudStorage -Force
        $env:HOME = $fakeHome

        $result = Find-OneDrivePath
        $result | Should -Be $cloudStorage
    }

    It 'falls back to a plain OneDrive folder in home' {
        $fakeHome       = Join-Path $TestDrive 'fake_home_od'
        $oneDriveFolder = Join-Path $fakeHome 'OneDrive'
        $null = New-Item -ItemType Directory -Path $oneDriveFolder -Force
        $env:HOME = $fakeHome

        $result = Find-OneDrivePath
        $result | Should -Be $oneDriveFolder
    }

    It 'returns null when no OneDrive folder is found' {
        $emptyHome = Join-Path $TestDrive 'fake_home_empty'
        $null = New-Item -ItemType Directory -Path $emptyHome -Force
        $env:HOME = $emptyHome

        $result = Find-OneDrivePath
        $result | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Describe: Find-IPhonePath
# ---------------------------------------------------------------------------
Describe 'Find-IPhonePath' {

    It 'returns null when /Volumes does not exist' {
        if (Test-Path '/Volumes') {
            Set-ItResult -Skipped -Because '/Volumes exists on this runner'
        }
        $result = Find-IPhonePath
        $result | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Describe: Integration — full pipeline with temp directories
# ---------------------------------------------------------------------------
Describe 'Integration: full comparison pipeline' {

    BeforeAll {
        $extensions = @('.jpg', '.heic', '.mov')

        $srcRoot  = Join-Path $TestDrive 'integ_src'
        $destRoot = Join-Path $TestDrive 'integ_dest'
        $sub1     = Join-Path $srcRoot '100APPLE'
        $sub2     = Join-Path $srcRoot '101APPLE'
        $null = New-Item -ItemType Directory -Path $sub1     -Force
        $null = New-Item -ItemType Directory -Path $sub2     -Force
        $null = New-Item -ItemType Directory -Path $destRoot -Force

        # Source: 5 files across two subdirs
        [System.IO.File]::WriteAllBytes((Join-Path $sub1 'IMG_0001.jpg'),  [byte[]]::new(1000))
        [System.IO.File]::WriteAllBytes((Join-Path $sub1 'IMG_0002.heic'), [byte[]]::new(2000))
        [System.IO.File]::WriteAllBytes((Join-Path $sub1 'VID_0001.mov'),  [byte[]]::new(8000))
        [System.IO.File]::WriteAllBytes((Join-Path $sub2 'IMG_0003.jpg'),  [byte[]]::new(1500))
        [System.IO.File]::WriteAllBytes((Join-Path $sub2 'IMG_0004.heic'), [byte[]]::new(2500))

        # Destination: 3 of the 5 synced (IMG_0002 and VID_0001 are missing)
        [System.IO.File]::WriteAllBytes((Join-Path $destRoot 'IMG_0001.jpg'),  [byte[]]::new(1000))
        [System.IO.File]::WriteAllBytes((Join-Path $destRoot 'IMG_0003.jpg'),  [byte[]]::new(1500))
        [System.IO.File]::WriteAllBytes((Join-Path $destRoot 'IMG_0004.heic'), [byte[]]::new(2500))

        $script:integSrcFiles  = Get-MediaFiles -Path $srcRoot  -Extensions $extensions
        $script:integDestFiles = Get-MediaFiles -Path $destRoot -Extensions $extensions
        $script:integResults   = Compare-MediaFiles -SourceFiles $integSrcFiles -DestinationFiles $integDestFiles
    }

    It 'finds all source files' {
        $integSrcFiles.Count | Should -Be 5
    }

    It 'identifies the correct number of synced files' {
        $synced = @($integResults | Where-Object { $_.Status -eq 'Synced' })
        $synced.Count | Should -Be 3
    }

    It 'identifies the correct number of missing files' {
        $missing = @($integResults | Where-Object { $_.Status -eq 'Missing' })
        $missing.Count | Should -Be 2
    }

    It 'identifies the correct missing filenames' {
        $missingNames = @($integResults | Where-Object { $_.Status -eq 'Missing' } | Select-Object -ExpandProperty FileName)
        $missingNames | Should -Contain 'IMG_0002.heic'
        $missingNames | Should -Contain 'VID_0001.mov'
    }

    It 'Format-SyncReport returns the correct missing count' {
        $count = Format-SyncReport -Results $integResults -SourcePath '/iphone/DCIM' -OneDrivePath '/onedrive'
        $count | Should -Be 2
    }

    It 'exports a valid CSV report' {
        $csvPath = Join-Path $TestDrive 'report.csv'
        $integResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Test-Path $csvPath | Should -BeTrue
        $imported = Import-Csv $csvPath
        $imported.Count | Should -Be 5
        $imported[0].PSObject.Properties.Name | Should -Contain 'Status'
    }
}
