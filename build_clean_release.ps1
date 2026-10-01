# build_clean_release.ps1 - build TurboQuake from a bounded live-source snapshot.
[CmdletBinding()]
param(
    [string]$SourceRoot = $PSScriptRoot,
    [string]$DosRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$KeepScratch,
    [switch]$VerifyReproducible
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::Equals($fullPath, $pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $trimCharacters = [char[]]@(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $fullPath = $fullPath.TrimEnd($trimCharacters)
    }
    return $fullPath
}

function Assert-DirectScratchPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DosRoot
    )

    $fullPath = Get-NormalizedFullPath -Path $Path
    $fullRoot = Get-NormalizedFullPath -Path $DosRoot
    $parent = Get-NormalizedFullPath -Path (Split-Path -Parent $fullPath)
    $leaf = Split-Path -Leaf $fullPath
    if (-not [string]::Equals($parent, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -cnotmatch '^_turboquake-release-[0-9a-f]{32}$') {
        throw "Unsafe TurboQuake scratch path: $fullPath"
    }
    return $fullPath
}

function Assert-SafeScratchDirectoryForRemoval {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$DosRoot
    )

    $validatedPath = Assert-DirectScratchPath -Path $Path -DosRoot $DosRoot
    $item = Get-Item -LiteralPath $validatedPath -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "Refusing to remove a non-directory scratch target: $validatedPath"
    }
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a reparse-point scratch target: $validatedPath"
    }
    return $validatedPath
}

function Resolve-ApplicationPath {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command -or -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        throw "Unable to resolve required application '$Name'."
    }
    return (Resolve-Path -LiteralPath $command.Source).Path
}

function Invoke-CapturedApplication {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Description
    )

    # Windows PowerShell promotes native stderr records to PowerShell errors.
    # With the script-wide Stop preference, a harmless compiler warning could
    # therefore abort this function before the native exit code was examined.
    # Capture both streams under Continue, then restore the caller's policy and
    # make the native exit code the sole success/failure authority.
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($exitCode -ne 0) {
        foreach ($line in $output) {
            Write-Host ('{0}' -f $line)
        }
        throw "$Description failed with exit code $exitCode."
    }
    return $output
}

function Invoke-LoggedApplication {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($exitCode -ne 0) {
        foreach ($line in $output) {
            Write-Host ('{0}' -f $line)
        }
        throw "$Description failed with exit code $exitCode."
    }
}

function Get-FileRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Kind file is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Kind file must not be a reparse point: $Path"
    }
    return [PSCustomObject]@{
        Kind   = $Kind
        Name   = $Name
        Length = [int64]$item.Length
        Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Get-TrackedBuildInputs {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$SourceRoot
    )

    $rawPaths = @(Invoke-CapturedApplication -FilePath $GitPath -ArgumentList @(
        '-C', $SourceRoot,
        '-c', 'core.quotepath=false',
        'ls-files', '--', 'Makefile.dos', 'common.mk', 'src'
    ) -Description 'git ls-files')

    $paths = @()
    foreach ($rawPath in $rawPaths) {
        $relativePath = ([string]$rawPath).Replace('\', '/')
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        if ($relativePath -ne 'Makefile.dos' -and
            $relativePath -ne 'common.mk' -and
            -not $relativePath.StartsWith('src/', [System.StringComparison]::Ordinal)) {
            throw "git ls-files returned an out-of-scope build input: $relativePath"
        }
        $paths += $relativePath
    }

    if ($paths.Count -lt 3 -or $paths -cnotcontains 'Makefile.dos' -or
        $paths -cnotcontains 'common.mk' -or
        @($paths | Where-Object { $_.StartsWith('src/', [System.StringComparison]::Ordinal) }).Count -eq 0) {
        throw 'The tracked TurboQuake build-input set is incomplete.'
    }

    [string[]]$orderedPaths = @($paths)
    [Array]::Sort($orderedPaths, [System.StringComparer]::Ordinal)
    return $orderedPaths
}

function Get-GitHead {
    param(
        [Parameter(Mandatory = $true)][string]$GitPath,
        [Parameter(Mandatory = $true)][string]$SourceRoot
    )

    $output = @(Invoke-CapturedApplication -FilePath $GitPath -ArgumentList @(
        '-C', $SourceRoot, 'rev-parse', 'HEAD'
    ) -Description 'git rev-parse HEAD')
    $lines = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -ne 1 -or $lines[0] -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw 'git rev-parse HEAD did not return one valid object ID.'
    }
    return $lines[0].ToUpperInvariant()
}

function Convert-ToWslPath {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$WindowsPath
    )

    # wsl.exe flattens its Linux command line and unquoted backslashes can be
    # consumed before wslpath sees them. Forward-slash Windows form is both
    # unambiguous to wsl.exe and accepted by wslpath (for example C:/work).
    $portableWindowsPath = $WindowsPath.Replace('\', '/')
    $output = @(Invoke-CapturedApplication -FilePath $WslPath -ArgumentList @(
        '-d', 'Ubuntu', '--', '/usr/bin/wslpath', '-a', '-u', $portableWindowsPath
    ) -Description 'WSL path conversion')
    $lines = @($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -ne 1 -or -not $lines[0].StartsWith('/', [System.StringComparison]::Ordinal)) {
        throw "WSL path conversion returned an invalid path for $WindowsPath."
    }
    return $lines[0]
}

function Get-WslToolRecord {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$LinuxPath
    )

    $hashOutput = @(Invoke-CapturedApplication -FilePath $WslPath -ArgumentList @(
        '-d', 'Ubuntu', '--', '/usr/bin/sha256sum', '--', $LinuxPath
    ) -Description "WSL SHA256 for $Name")
    $hashLines = @($hashOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 })
    if ($hashLines.Count -ne 1 -or $hashLines[0] -notmatch '^([0-9a-fA-F]{64})\s') {
        throw "Unable to parse WSL SHA256 for $Name."
    }
    $sha256 = $matches[1].ToUpperInvariant()

    $lengthOutput = @(Invoke-CapturedApplication -FilePath $WslPath -ArgumentList @(
        '-d', 'Ubuntu', '--', '/usr/bin/stat', '--format=%s', '--', $LinuxPath
    ) -Description "WSL length for $Name")
    $lengthLines = @($lengthOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_.Length -gt 0 })
    $length = [int64]0
    if ($lengthLines.Count -ne 1 -or
        -not [int64]::TryParse($lengthLines[0], [ref]$length) -or
        $length -le 0) {
        throw "Unable to parse WSL length for $Name."
    }

    return [PSCustomObject]@{
        Kind      = 'TOOL'
        Name      = $Name
        LinuxPath = $LinuxPath
        Length    = $length
        Sha256    = $sha256
    }
}

function Invoke-TurboQuakeBuild {
    param(
        [Parameter(Mandatory = $true)][string]$WslPath,
        [Parameter(Mandatory = $true)][string]$WslSourceRoot,
        [Parameter(Mandatory = $true)][string]$WslBuildRoot,
        [Parameter(Mandatory = $true)][ValidateSet('486', '586')][string]$Cpu,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Write-Host "Building TurboQuake $Cpu ($Label) in clean scratch."
    Invoke-LoggedApplication -FilePath $WslPath -ArgumentList @(
        '-d', 'Ubuntu', '--',
        '/usr/bin/env', '-i',
        'PATH=/opt/djgpp/bin:/usr/bin:/bin',
        'SOURCE_DATE_EPOCH=946684800',
        'LC_ALL=C',
        'TZ=UTC',
        '/usr/bin/make',
        '-C', $WslSourceRoot,
        '-f', 'Makefile.dos',
        '-j8',
        "BUILDDIR=$WslBuildRoot",
        "OCPU=$Cpu",
        'OLEVEL=O3',
        'OLTO=yes',
        'OASM=yes',
        'OSTRIP=-s',
        'RENDERER=std',
        'SHELL=/usr/bin/bash',
        'build_release'
    ) -Description "TurboQuake $Cpu $Label build"
}

$sourceRoot = Get-NormalizedFullPath -Path $SourceRoot
$dosRoot = Get-NormalizedFullPath -Path $DosRoot
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "TurboQuake source root is missing: $sourceRoot"
}
if (-not (Test-Path -LiteralPath $dosRoot -PathType Container)) {
    throw "DOS root is missing: $dosRoot"
}

$scratchLeaf = '_turboquake-release-' + [Guid]::NewGuid().ToString('N')
$scratchRoot = Assert-DirectScratchPath -Path (Join-Path $dosRoot $scratchLeaf) -DosRoot $dosRoot
$projectRoot = Join-Path $scratchRoot 'project'
$releaseRoot = Join-Path $scratchRoot 'release'
$build486Primary = Join-Path $scratchRoot 'build-486-a'
$build586Primary = Join-Path $scratchRoot 'build-586-a'
$build486Second = Join-Path $scratchRoot 'build-486-b'
$build586Second = Join-Path $scratchRoot 'build-586-b'

$scratchCreated = $false
$completed = $false
$failureRecord = $null
$result = $null

try {
    $gitPath = Resolve-ApplicationPath -Name 'git.exe'
    $wslPath = Resolve-ApplicationPath -Name 'wsl.exe'
    $gitHead = Get-GitHead -GitPath $gitPath -SourceRoot $sourceRoot
    $trackedInputs = @(Get-TrackedBuildInputs -GitPath $gitPath -SourceRoot $sourceRoot)

    $toolSpecifications = @(
        [PSCustomObject]@{ Name = 'WSL_GCC';  Path = '/opt/djgpp/bin/i586-pc-msdosdjgpp-gcc' },
        [PSCustomObject]@{ Name = 'WSL_AS';   Path = '/opt/djgpp/bin/i586-pc-msdosdjgpp-as' },
        [PSCustomObject]@{ Name = 'WSL_LD';   Path = '/opt/djgpp/bin/i586-pc-msdosdjgpp-ld' },
        [PSCustomObject]@{ Name = 'WSL_MAKE'; Path = '/usr/bin/make' },
        [PSCustomObject]@{ Name = 'WSL_BASH'; Path = '/usr/bin/bash' }
    )
    $toolRecords = @()
    foreach ($tool in $toolSpecifications) {
        $toolRecords += Get-WslToolRecord -WslPath $wslPath -Name $tool.Name -LinuxPath $tool.Path
    }

    if (Test-Path -LiteralPath $scratchRoot) {
        throw "Refusing to reuse an existing TurboQuake scratch path: $scratchRoot"
    }
    New-Item -ItemType Directory -Path $scratchRoot | Out-Null
    $scratchCreated = $true
    New-Item -ItemType Directory -Path $projectRoot | Out-Null
    New-Item -ItemType Directory -Path $releaseRoot | Out-Null

    Write-Host "Snapshotting $($trackedInputs.Count) tracked TurboQuake build input(s)."
    $sourceRecords = @()
    $sourcePrefix = $sourceRoot + [System.IO.Path]::DirectorySeparatorChar
    foreach ($relativePath in $trackedInputs) {
        $windowsRelativePath = $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $sourcePath = Get-NormalizedFullPath -Path (Join-Path $sourceRoot $windowsRelativePath)
        if (-not $sourcePath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Tracked input escapes SourceRoot: $relativePath"
        }
        $destinationPath = Join-Path $projectRoot $windowsRelativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

        $sourceBefore = Get-FileRecord -Kind 'SOURCE' -Name $relativePath -Path $sourcePath
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
        $destination = Get-FileRecord -Kind 'SOURCE' -Name $relativePath -Path $destinationPath
        $sourceAfter = Get-FileRecord -Kind 'SOURCE' -Name $relativePath -Path $sourcePath
        if ($sourceBefore.Length -ne $destination.Length -or
            $sourceBefore.Sha256 -ne $destination.Sha256 -or
            $sourceBefore.Length -ne $sourceAfter.Length -or
            $sourceBefore.Sha256 -ne $sourceAfter.Sha256) {
            throw "Source input changed or failed byte verification while snapshotting: $relativePath"
        }
        $sourceRecords += $destination
    }

    foreach ($forbiddenName in '.git', 'build', 'bin', 'dist', 'verify') {
        $forbiddenPath = Join-Path $projectRoot $forbiddenName
        if (Test-Path -LiteralPath $forbiddenPath) {
            throw "Clean snapshot unexpectedly contains forbidden path: $forbiddenName"
        }
    }

    $buildRoots = @($build486Primary, $build586Primary)
    if ($VerifyReproducible) {
        $buildRoots += @($build486Second, $build586Second)
    }
    $expectedBuildPathLength = $buildRoots[0].Length
    foreach ($buildRoot in $buildRoots) {
        if ($buildRoot.Length -ne $expectedBuildPathLength -or
            -not [string]::Equals((Split-Path -Parent $buildRoot), $scratchRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'TurboQuake BUILDDIR paths must be equal-length siblings within the scratch root.'
        }
        # Makefile.dos creates BUILDDIR/486quake, but its renderer object rules
        # also require this deeper directory and do not declare a mkdir rule.
        New-Item -ItemType Directory -Path (Join-Path $buildRoot '486quake\r_std') -Force | Out-Null
    }

    $wslProjectRoot = Convert-ToWslPath -WslPath $wslPath -WindowsPath $projectRoot
    $wslBuild486Primary = Convert-ToWslPath -WslPath $wslPath -WindowsPath $build486Primary
    $wslBuild586Primary = Convert-ToWslPath -WslPath $wslPath -WindowsPath $build586Primary
    if ($wslBuild486Primary.Length -ne $wslBuild586Primary.Length) {
        throw 'WSL primary BUILDDIR paths are not equal length.'
    }

    Invoke-TurboQuakeBuild -WslPath $wslPath -WslSourceRoot $wslProjectRoot `
        -WslBuildRoot $wslBuild486Primary -Cpu '486' -Label 'primary'
    Invoke-TurboQuakeBuild -WslPath $wslPath -WslSourceRoot $wslProjectRoot `
        -WslBuildRoot $wslBuild586Primary -Cpu '586' -Label 'primary'

    $primary486Path = Join-Path $build486Primary '486qO3l.exe'
    $primary586Path = Join-Path $build586Primary '586qO3l.exe'
    $primary486 = Get-FileRecord -Kind 'BUILD' -Name '486qO3l.exe' -Path $primary486Path
    $primary586 = Get-FileRecord -Kind 'BUILD' -Name '586qO3l.exe' -Path $primary586Path
    if ($primary486.Length -le 0 -or $primary586.Length -le 0) {
        throw 'A primary TurboQuake executable is empty.'
    }

    $reproducibleFlag = '0'
    if ($VerifyReproducible) {
        $wslBuild486Second = Convert-ToWslPath -WslPath $wslPath -WindowsPath $build486Second
        $wslBuild586Second = Convert-ToWslPath -WslPath $wslPath -WindowsPath $build586Second
        if ($wslBuild486Second.Length -ne $wslBuild486Primary.Length -or
            $wslBuild586Second.Length -ne $wslBuild586Primary.Length) {
            throw 'WSL reproducibility BUILDDIR paths are not equal length.'
        }

        Invoke-TurboQuakeBuild -WslPath $wslPath -WslSourceRoot $wslProjectRoot `
            -WslBuildRoot $wslBuild486Second -Cpu '486' -Label 'reproducibility'
        Invoke-TurboQuakeBuild -WslPath $wslPath -WslSourceRoot $wslProjectRoot `
            -WslBuildRoot $wslBuild586Second -Cpu '586' -Label 'reproducibility'

        $second486 = Get-FileRecord -Kind 'REPRODUCIBILITY' -Name '486qO3l.exe' `
            -Path (Join-Path $build486Second '486qO3l.exe')
        $second586 = Get-FileRecord -Kind 'REPRODUCIBILITY' -Name '586qO3l.exe' `
            -Path (Join-Path $build586Second '586qO3l.exe')
        if ($second486.Length -ne $primary486.Length -or $second486.Sha256 -ne $primary486.Sha256 -or
            $second586.Length -ne $primary586.Length -or $second586.Sha256 -ne $primary586.Sha256) {
            throw 'TurboQuake clean builds are not byte-reproducible across equal-length sibling BUILDDIRs.'
        }
        $reproducibleFlag = '1'
    }

    $release486Path = Join-Path $releaseRoot '486qO3l.exe'
    $release586Path = Join-Path $releaseRoot '586qO3l.exe'
    $releaseAliasPath = Join-Path $releaseRoot 'QUAKE.EXE'
    Copy-Item -LiteralPath $primary486Path -Destination $release486Path
    Copy-Item -LiteralPath $primary486Path -Destination $releaseAliasPath
    Copy-Item -LiteralPath $primary586Path -Destination $release586Path

    $outputRecords = @(
        (Get-FileRecord -Kind 'OUTPUT' -Name '486qO3l.exe' -Path $release486Path),
        (Get-FileRecord -Kind 'OUTPUT' -Name '586qO3l.exe' -Path $release586Path),
        (Get-FileRecord -Kind 'OUTPUT' -Name 'QUAKE.EXE' -Path $releaseAliasPath)
    )
    foreach ($outputRecord in $outputRecords) {
        if ($outputRecord.Length -le 0) {
            throw "TurboQuake release output is empty: $($outputRecord.Name)"
        }
    }
    $release486 = @($outputRecords | Where-Object { $_.Name -ceq '486qO3l.exe' })[0]
    $release586 = @($outputRecords | Where-Object { $_.Name -ceq '586qO3l.exe' })[0]
    $releaseAlias = @($outputRecords | Where-Object { $_.Name -ceq 'QUAKE.EXE' })[0]
    if ($release486.Length -ne $primary486.Length -or $release486.Sha256 -ne $primary486.Sha256 -or
        $release586.Length -ne $primary586.Length -or $release586.Sha256 -ne $primary586.Sha256 -or
        $releaseAlias.Length -ne $release486.Length -or $releaseAlias.Sha256 -ne $release486.Sha256) {
        throw 'TurboQuake release outputs failed byte verification or QUAKE.EXE alias validation.'
    }

    foreach ($sourceRecord in $sourceRecords) {
        $snapshotPath = Join-Path $projectRoot $sourceRecord.Name.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $afterBuild = Get-FileRecord -Kind 'SOURCE' -Name $sourceRecord.Name -Path $snapshotPath
        if ($afterBuild.Length -ne $sourceRecord.Length -or $afterBuild.Sha256 -ne $sourceRecord.Sha256) {
            throw "TurboQuake build mutated snapshotted source input: $($sourceRecord.Name)"
        }
    }

    foreach ($toolRecord in $toolRecords) {
        $afterBuildTool = Get-WslToolRecord -WslPath $wslPath -Name $toolRecord.Name `
            -LinuxPath $toolRecord.LinuxPath
        if ($afterBuildTool.Length -ne $toolRecord.Length -or $afterBuildTool.Sha256 -ne $toolRecord.Sha256) {
            throw "WSL build tool changed during the TurboQuake build: $($toolRecord.Name)"
        }
    }

    $orchestratorRecord = Get-FileRecord -Kind 'ORCHESTRATOR' -Name 'BUILD_CLEAN_RELEASE_PS1' -Path $PSCommandPath
    $provenancePath = Join-Path $releaseRoot 'TQBLD.TXT'
    $provenanceLines = @(
        'TURBOQUAKE_CLEAN_RELEASE_PROVENANCE=1',
        ('GIT_HEAD={0}' -f $gitHead),
        'WSL_DISTRO=Ubuntu',
        'BUILD_CONFIG=OCPU=486,586 OLEVEL=O3 OLTO=yes OASM=yes OSTRIP=-s RENDERER=std SOURCE_DATE_EPOCH=946684800 LC_ALL=C TZ=UTC',
        ('REPRODUCIBLE={0}' -f $reproducibleFlag),
        ('SNAPSHOT_INPUTS={0}' -f $sourceRecords.Count),
        ('{0} {1} {2} {3}' -f $orchestratorRecord.Kind, $orchestratorRecord.Name, $orchestratorRecord.Length, $orchestratorRecord.Sha256)
    )
    foreach ($sourceRecord in $sourceRecords) {
        $provenanceLines += ('{0} {1} {2} {3}' -f $sourceRecord.Kind, $sourceRecord.Name, $sourceRecord.Length, $sourceRecord.Sha256)
    }
    foreach ($toolRecord in $toolRecords) {
        $provenanceLines += ('{0} {1} {2} {3}' -f $toolRecord.Kind, $toolRecord.Name, $toolRecord.Length, $toolRecord.Sha256)
    }
    foreach ($outputRecord in $outputRecords) {
        $provenanceLines += ('{0} {1} {2} {3}' -f $outputRecord.Kind, $outputRecord.Name, $outputRecord.Length, $outputRecord.Sha256)
    }
    [System.IO.File]::WriteAllLines($provenancePath, [string[]]$provenanceLines, [System.Text.Encoding]::ASCII)
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf) -or
        (Get-Item -LiteralPath $provenancePath).Length -le 0) {
        throw 'TurboQuake provenance file was not created.'
    }

    $result = [PSCustomObject]@{
        ScratchRoot   = $scratchRoot
        BinPath       = $releaseRoot
        ProvenancePath = $provenancePath
        Retained      = [bool]$KeepScratch
    }
    $completed = $true
} catch {
    $failureRecord = $_
}

if (-not $completed) {
    $failureResult = [PSCustomObject]@{
        Status      = 'FAILED'
        ScratchRoot = $scratchRoot
        Retained    = [bool]($scratchCreated -and (Test-Path -LiteralPath $scratchRoot))
        Error       = if ($failureRecord) { $failureRecord.Exception.Message } else { 'Unknown failure' }
    }
    Write-Host ('TURBOQUAKE_CLEAN_RELEASE_FAILURE=' + ($failureResult | ConvertTo-Json -Compress))
    if ($failureResult.Retained) {
        Write-Host "TurboQuake failure evidence retained at $scratchRoot"
    }
    throw $failureRecord
}

if (-not $KeepScratch -and $scratchCreated -and (Test-Path -LiteralPath $scratchRoot)) {
    $validatedScratch = Assert-SafeScratchDirectoryForRemoval -Path $scratchRoot -DosRoot $dosRoot
    Remove-Item -LiteralPath $validatedScratch -Recurse -Force
    if (Test-Path -LiteralPath $validatedScratch) {
        throw "TurboQuake scratch cleanup did not remove: $validatedScratch"
    }
}

Write-Host ('TURBOQUAKE_CLEAN_RELEASE_RESULT=' + ($result | ConvertTo-Json -Compress))
Write-Output $result
