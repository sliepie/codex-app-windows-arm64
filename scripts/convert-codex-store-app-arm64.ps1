[CmdletBinding()]
param(
    [string] $OutputRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) ".scratch\codex-arm64-conversion"),
    [switch] $TrustSigningCertificate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProductId = "9PLM9XGG6VKS"
$PackageName = "OpenAI.Codex"
$DevIdentityName = "OpenAI.Codex.Arm64Dev"

function Invoke-External {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [string] $WorkingDirectory = (Get-Location).Path,

        [switch] $Interactive
    )

    $command = Get-Command $FilePath -ErrorAction Stop
    $resolvedFilePath = $command.Source
    $resolvedArguments = $Arguments

    if ($resolvedFilePath.EndsWith(".ps1", [StringComparison]::OrdinalIgnoreCase)) {
        $cmdAlternative = [IO.Path]::ChangeExtension($resolvedFilePath, ".cmd")
        if (Test-Path -LiteralPath $cmdAlternative -PathType Leaf) {
            $resolvedFilePath = $cmdAlternative
        }
    }

    if ($resolvedFilePath.EndsWith(".cmd", [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedFilePath.EndsWith(".bat", [StringComparison]::OrdinalIgnoreCase)) {
        $resolvedArguments = @("/d", "/c", $resolvedFilePath) + $Arguments
        $resolvedFilePath = "$env:ComSpec"
    }
    elseif ($resolvedFilePath.EndsWith(".ps1", [StringComparison]::OrdinalIgnoreCase)) {
        $resolvedArguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedFilePath) + $Arguments
        $resolvedFilePath = (Get-Command "pwsh" -ErrorAction Stop).Source
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolvedFilePath
    foreach ($argument in $resolvedArguments) {
        $psi.ArgumentList.Add($argument)
    }
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $Interactive.IsPresent
    $psi.RedirectStandardOutput = -not $Interactive.IsPresent
    $psi.RedirectStandardError = -not $Interactive.IsPresent

    $process = [Diagnostics.Process]::Start($psi)
    $stdout = ""
    $stderr = ""
    if (-not $Interactive.IsPresent) {
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
    }
    $process.WaitForExit()

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = ($stdout + $stderr)
    }
}

function Assert-SafeOutputRoot {
    param([Parameter(Mandatory)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($fullPath -match "^[A-Za-z]:\\$" -or $fullPath -match "\\WindowsApps(\\|$)") {
        throw "Refusing unsafe output root: $fullPath"
    }

    return $fullPath
}

function Expand-ZipLikePackage {
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force $DestinationPath | Out-Null

    $zipPath = Join-Path (Split-Path -Parent $DestinationPath) ("{0}.zip" -f ([IO.Path]::GetFileNameWithoutExtension($PackagePath)))
    Copy-Item -LiteralPath $PackagePath -Destination $zipPath -Force
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $DestinationPath -Force
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-CodexStorePackage {
    Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
}

function Show-ReplacementBanner {
    param([Parameter(Mandatory)] $Package)

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Existing Codex Store Package detected:"
    Write-Host "  $($Package.PackageFullName)"
    Write-Host "It will be replaced by the Converted App in this user account."
    Write-Host "The Store Package will be copied to a snapshot first, then removed."
    Write-Host "============================================================"
    Write-Host ""
}

function Invoke-CodexStoreInstall {
    Write-Host "Installing Codex Store Package with winget/msstore."
    $install = Invoke-External -FilePath "winget" -Arguments @(
        "install",
        "--id", $ProductId,
        "--source", "msstore",
        "--scope", "user",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity",
        "--force"
    )
    if ($install.ExitCode -ne 0) {
        throw "winget/msstore install failed for Codex Store product $ProductId. $($install.Output)"
    }
}

function Test-CodexStoreUpgradeAvailable {
    $upgrade = Invoke-External -FilePath "winget" -Arguments @(
        "upgrade",
        "--id", $ProductId,
        "--source", "msstore",
        "--accept-source-agreements"
    )

    if ($upgrade.Output -match "No available upgrade|No installed package found") {
        return $false
    }

    if ($upgrade.ExitCode -ne 0) {
        throw "Unable to check Codex Store Package upgrade state. $($upgrade.Output)"
    }

    return ($upgrade.Output -match [regex]::Escape($ProductId) -or $upgrade.Output -match "Codex")
}

function Invoke-CodexStoreUpgrade {
    Write-Host "Updating Codex Store Package with winget/msstore."
    $upgrade = Invoke-External -FilePath "winget" -Arguments @(
        "upgrade",
        "--id", $ProductId,
        "--source", "msstore",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--disable-interactivity"
    )
    if ($upgrade.ExitCode -ne 0) {
        throw "winget/msstore upgrade failed for Codex Store product $ProductId. $($upgrade.Output)"
    }
}

function Ensure-CodexStorePackageCurrent {
    param($ExistingPackage)

    if ($null -eq $ExistingPackage) {
        Invoke-CodexStoreInstall
        return [pscustomobject]@{
            Action = "Installed"
        }
    }

    Write-Host "Installed Codex Store Package version: $($ExistingPackage.Version)"
    Write-Host "Checking whether the Codex Store Package needs an update."
    if (Test-CodexStoreUpgradeAvailable) {
        Invoke-CodexStoreUpgrade
        return [pscustomobject]@{
            Action = "Upgraded"
        }
    }

    Write-Host "Installed Codex Store Package is current; skipping Store install/update."
    [pscustomobject]@{
        Action = "Current"
    }
}

function New-StorePackageSnapshot {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)][string] $SnapshotDirectory
    )

    $installLocation = $Package.InstallLocation
    if ([string]::IsNullOrWhiteSpace($installLocation) -or -not (Test-Path -LiteralPath $installLocation -PathType Container)) {
        throw "Codex Store Package does not have a readable InstallLocation."
    }

    if (Test-Path -LiteralPath $SnapshotDirectory) {
        Remove-Item -LiteralPath $SnapshotDirectory -Recurse -Force
    }

    Write-Host "Copying Codex Store Package snapshot from: $installLocation"
    Copy-Item -LiteralPath $installLocation -Destination $SnapshotDirectory -Recurse -Force
    return $SnapshotDirectory
}

function Remove-CodexStorePackage {
    param([Parameter(Mandatory)] $Package)

    Write-Host "Removing current-user Codex Store Package before installing Converted App."
    Remove-AppxPackage -Package $Package.PackageFullName -ErrorAction Stop
}

function Remove-ExistingConvertedPackage {
    $package = Get-ExistingConvertedPackage

    if ($null -ne $package) {
        Write-Host "Removing existing Converted App before replacing it."
        Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
    }
}

function Get-ExistingConvertedPackage {
    Get-AppxPackage -Name $DevIdentityName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Test-ConvertedPackageMatchesStorePackage {
    param(
        [Parameter(Mandatory)] $ConvertedPackage,
        [Parameter(Mandatory)] $StorePackage
    )

    return ([version] $ConvertedPackage.Version) -eq ([version] $StorePackage.Version)
}

function Test-ConvertedPackageIsInstalledPackage {
    param([Parameter(Mandatory)] $ConvertedPackage)

    return (-not [string]::IsNullOrWhiteSpace($ConvertedPackage.InstallLocation)) -and
        ($ConvertedPackage.InstallLocation -match "\\WindowsApps\\")
}

function Get-ElectronVersionFromAsar {
    param(
        [Parameter(Mandatory)][string] $AsarPath,
        [Parameter(Mandatory)][string] $WorkDirectory
    )

    $packageJsonPath = Join-Path $WorkDirectory "asar-package.json"
    $result = Invoke-External -FilePath "npx" -Arguments @("--yes", "asar", "extract-file", $AsarPath, "package.json")
    if ($result.ExitCode -ne 0) {
        throw "Unable to read app.asar package metadata with npx asar. $($result.Output)"
    }

    Set-Content -LiteralPath $packageJsonPath -Value $result.Output
    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    $electronVersion = $packageJson.devDependencies.electron
    if ([string]::IsNullOrWhiteSpace($electronVersion)) {
        throw "Unable to determine Electron version from app.asar package metadata."
    }

    return $electronVersion.TrimStart("^", "~")
}

function Get-ElectronVersion {
    param(
        [Parameter(Mandatory)][string] $PackageDirectory,
        [Parameter(Mandatory)][string] $WorkDirectory
    )

    $versionPath = Join-Path $PackageDirectory "app\version"
    if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        $electronVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($electronVersion)) {
            return $electronVersion
        }
    }

    $asarPath = Join-Path $PackageDirectory "app\resources\app.asar"
    return Get-ElectronVersionFromAsar -AsarPath $asarPath -WorkDirectory $WorkDirectory
}

function Test-ElectronRuntimeCache {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $ZipPath
    )

    if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
        return $false
    }

    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try {
            $versionEntry = $archive.GetEntry("version")
            if ($null -eq $versionEntry) {
                return $false
            }

            $reader = [IO.StreamReader]::new($versionEntry.Open())
            try {
                $cachedVersion = $reader.ReadToEnd().Trim()
            }
            finally {
                $reader.Dispose()
            }

            return $cachedVersion -eq $Version
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Download-ElectronRuntime {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    New-Item -ItemType Directory -Force (Split-Path -Parent $DestinationPath) | Out-Null
    $url = "https://github.com/electron/electron/releases/download/v$Version/electron-v$Version-win32-arm64.zip"
    Write-Host "Downloading Matching Electron Runtime: $url"
    Invoke-WebRequest -Uri $url -OutFile $DestinationPath
}

function Ensure-ElectronRuntime {
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    if (Test-ElectronRuntimeCache -Version $Version -ZipPath $DestinationPath) {
        Write-Host "Using cached Matching Electron Runtime: $DestinationPath"
        return
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        Write-Host "Cached Matching Electron Runtime does not match version $Version; downloading again."
    }

    Download-ElectronRuntime -Version $Version -DestinationPath $DestinationPath
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [string[]] $ExcludeNames = @()
    )

    New-Item -ItemType Directory -Force $Destination | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($ExcludeNames -contains $item.Name) {
            continue
        }

        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
    }
}

function Get-NodePackageVersion {
    param(
        [Parameter(Mandatory)][string] $AsarWorkDirectory,
        [Parameter(Mandatory)][string] $PackageName
    )

    $packageJsonPath = Join-Path $AsarWorkDirectory "node_modules\$PackageName\package.json"
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        throw "Unable to find package.json for $PackageName."
    }

    $packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
    return $packageJson.version
}

function Expand-TarPackage {
    param(
        [Parameter(Mandatory)][string] $TarballPath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force $DestinationPath | Out-Null

    $extract = Invoke-External -FilePath "tar" -Arguments @("-xzf", $TarballPath, "-C", $DestinationPath)
    if ($extract.ExitCode -ne 0) {
        throw "Unable to extract npm package tarball $TarballPath. $($extract.Output)"
    }
}

function Hydrate-NodePackageFromNpm {
    param(
        [Parameter(Mandatory)][string] $AsarWorkDirectory,
        [Parameter(Mandatory)][string] $WorkDirectory,
        [Parameter(Mandatory)][string] $PackageName
    )

    $version = Get-NodePackageVersion -AsarWorkDirectory $AsarWorkDirectory -PackageName $PackageName
    $packDirectory = Join-Path $WorkDirectory "npm-pack\$PackageName"
    New-Item -ItemType Directory -Force $packDirectory | Out-Null

    $pack = Invoke-External -FilePath "npm" -Arguments @(
        "pack",
        "$PackageName@$version",
        "--pack-destination",
        $packDirectory,
        "--silent"
    )
    if ($pack.ExitCode -ne 0) {
        throw "Unable to fetch npm package $PackageName@$version for Native Module Refresh. $($pack.Output)"
    }

    $tarball = Get-ChildItem -LiteralPath $packDirectory -Filter "*.tgz" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $tarball) {
        throw "npm pack did not produce a tarball for $PackageName@$version."
    }

    $extractDirectory = Join-Path $packDirectory "extracted"
    Expand-TarPackage -TarballPath $tarball.FullName -DestinationPath $extractDirectory

    $sourceDirectory = Join-Path $extractDirectory "package"
    $targetDirectory = Join-Path $AsarWorkDirectory "node_modules\$PackageName"
    if (Test-Path -LiteralPath $targetDirectory) {
        Remove-Item -LiteralPath $targetDirectory -Recurse -Force
    }
    Copy-DirectoryContents -Source $sourceDirectory -Destination $targetDirectory
}

function Replace-ElectronRuntime {
    param(
        [Parameter(Mandatory)][string] $PackageDirectory,
        [Parameter(Mandatory)][string] $ElectronZipPath,
        [Parameter(Mandatory)][string] $WorkDirectory
    )

    $appDir = Join-Path $PackageDirectory "app"
    $electronDir = Join-Path $WorkDirectory "electron-arm64"
    Expand-ZipLikePackage -PackagePath $ElectronZipPath -DestinationPath $electronDir

    Get-ChildItem -LiteralPath $appDir -Force |
        Where-Object { $_.Name -ne "resources" } |
        Remove-Item -Recurse -Force

    Copy-DirectoryContents -Source $electronDir -Destination $appDir -ExcludeNames @("resources")

    $electronExe = Join-Path $appDir "electron.exe"
    $codexExe = Join-Path $appDir "Codex.exe"
    if (Test-Path -LiteralPath $electronExe) {
        Move-Item -LiteralPath $electronExe -Destination $codexExe -Force
    }
    elseif (-not (Test-Path -LiteralPath $codexExe)) {
        throw "ARM64 Electron runtime did not contain electron.exe."
    }
}

function Invoke-NativeModuleRebuild {
    param(
        [Parameter(Mandatory)][string] $AsarWorkDirectory,
        [Parameter(Mandatory)][string] $ElectronVersion,
        [Parameter(Mandatory)][string] $NodeGypPath,
        [Parameter(Mandatory)][string] $PythonPath
    )

    $nativeModuleDirs = @(
        Join-Path $AsarWorkDirectory "node_modules\better-sqlite3"
    )

    $rebuildOutput = [Text.StringBuilder]::new()
    $rebuildExitCode = 0
    foreach ($moduleDir in $nativeModuleDirs) {
        if (-not (Test-Path -LiteralPath $moduleDir -PathType Container)) {
            continue
        }

        $nodeGypArgs = @(
            $NodeGypPath,
            "rebuild",
            "--arch=arm64",
            "--target=$ElectronVersion",
            "--dist-url=https://electronjs.org/headers",
            "--python=$PythonPath"
        )
        if ((Split-Path $moduleDir -Leaf) -eq "better-sqlite3") {
            $nodeGypArgs += "--release"
        }

        $moduleRebuild = Invoke-External -FilePath "node" -Arguments $nodeGypArgs -WorkingDirectory $moduleDir
        [void] $rebuildOutput.AppendLine("[$(Split-Path $moduleDir -Leaf)]")
        [void] $rebuildOutput.AppendLine($moduleRebuild.Output)
        if ($moduleRebuild.ExitCode -ne 0) {
            $rebuildExitCode = $moduleRebuild.ExitCode
            break
        }
    }

    [pscustomobject]@{
        ExitCode = $rebuildExitCode
        Output = $rebuildOutput.ToString()
    }
}

function Install-BetterSqlitePrebuild {
    param(
        [Parameter(Mandatory)][string] $AsarWorkDirectory,
        [Parameter(Mandatory)][string] $ElectronVersion
    )

    $moduleDir = Join-Path $AsarWorkDirectory "node_modules\better-sqlite3"
    if (-not (Test-Path -LiteralPath $moduleDir -PathType Container)) {
        return [pscustomobject]@{
            ExitCode = 0
            Output = "better-sqlite3 module was not present."
        }
    }

    Invoke-External -FilePath "npx" -Arguments @(
        "--yes",
        "prebuild-install",
        "-r", "electron",
        "-t", $ElectronVersion,
        "--arch", "arm64",
        "--platform", "win32"
    ) -WorkingDirectory $moduleDir
}

function Sync-NativeModulesToUnpackedResources {
    param(
        [Parameter(Mandatory)][string] $AsarWorkDirectory,
        [Parameter(Mandatory)][string] $PackageDirectory
    )

    $unpackedNodeModules = Join-Path $PackageDirectory "app\resources\app.asar.unpacked\node_modules"
    New-Item -ItemType Directory -Force $unpackedNodeModules | Out-Null

    foreach ($packageName in @("node-pty", "better-sqlite3")) {
        $sourceDirectory = Join-Path $AsarWorkDirectory "node_modules\$packageName"
        if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
            continue
        }

        $targetDirectory = Join-Path $unpackedNodeModules $packageName
        if (Test-Path -LiteralPath $targetDirectory) {
            Remove-Item -LiteralPath $targetDirectory -Recurse -Force
        }
        Copy-Item -LiteralPath $sourceDirectory -Destination $targetDirectory -Recurse -Force
    }
}

function Get-PythonForNodeGyp {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312-arm64\python.exe"),
        (Join-Path $env:ProgramFiles "Python312\python.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw "Python 3.12 was not found. Install it with: winget install --id Python.Python.3.12 --source winget --scope user"
}

function Refresh-NativeModules {
    param(
        [Parameter(Mandatory)][string] $PackageDirectory,
        [Parameter(Mandatory)][string] $ElectronVersion,
        [Parameter(Mandatory)][string] $WorkDirectory
    )

    $asarPath = Join-Path $PackageDirectory "app\resources\app.asar"
    $asarWorkDir = Join-Path $WorkDirectory "app-asar"

    if (Test-Path -LiteralPath $asarWorkDir) {
        Remove-Item -LiteralPath $asarWorkDir -Recurse -Force
    }

    $extract = Invoke-External -FilePath "npx" -Arguments @("--yes", "asar", "extract", $asarPath, $asarWorkDir)
    if ($extract.ExitCode -ne 0) {
        throw "Unable to extract app.asar for Native Module Refresh. $($extract.Output)"
    }

    Hydrate-NodePackageFromNpm -AsarWorkDirectory $asarWorkDir -WorkDirectory $WorkDirectory -PackageName "node-pty"
    Hydrate-NodePackageFromNpm -AsarWorkDirectory $asarWorkDir -WorkDirectory $WorkDirectory -PackageName "better-sqlite3"

    $nodePtyArm64Prebuild = Join-Path $asarWorkDir "node_modules\node-pty\prebuilds\win32-arm64\pty.node"
    if (-not (Test-Path -LiteralPath $nodePtyArm64Prebuild -PathType Leaf)) {
        throw "node-pty npm package did not contain a win32-arm64 prebuild."
    }

    $betterSqlitePrebuild = Install-BetterSqlitePrebuild -AsarWorkDirectory $asarWorkDir -ElectronVersion $ElectronVersion
    $betterSqliteArm64Prebuild = Join-Path $asarWorkDir "node_modules\better-sqlite3\build\Release\better_sqlite3.node"
    $rebuild = [pscustomobject]@{
        ExitCode = 0
        Output = $betterSqlitePrebuild.Output
    }

    if (($betterSqlitePrebuild.ExitCode -ne 0) -or (-not (Test-Path -LiteralPath $betterSqliteArm64Prebuild -PathType Leaf))) {
        $nodeGypPath = Join-Path (Split-Path (Get-Command "npm" -ErrorAction Stop).Source -Parent) "node_modules\npm\node_modules\node-gyp\bin\node-gyp.js"
        if (-not (Test-Path -LiteralPath $nodeGypPath -PathType Leaf)) {
            throw "Unable to find npm-bundled node-gyp at $nodeGypPath"
        }

        $pythonPath = Get-PythonForNodeGyp
        $rebuild = Invoke-NativeModuleRebuild -AsarWorkDirectory $asarWorkDir -ElectronVersion $ElectronVersion -NodeGypPath $nodeGypPath -PythonPath $pythonPath
    }

    while ($rebuild.ExitCode -ne 0) {
        Write-Host "Native Module Refresh prerequisites are missing or incompatible."
        Write-Host "Suggested commands:"
        Write-Host "  winget install --id Microsoft.VisualStudio.BuildTools --source winget --override `"--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`""
        Write-Host "  winget install --id Python.Python.3.12 --source winget"
        Write-Host "  npm config set msvs_version 2026"
        Write-Host "npm rebuild output:"
        Write-Host $rebuild.Output
        $choice = Read-Host "Type I to install prerequisites, R after manual install to retry, or Q to quit"
        if ([string]::IsNullOrWhiteSpace($choice)) {
            throw "Native Module Refresh prerequisites were not installed."
        }

        switch ($choice.ToUpperInvariant()) {
            "I" {
                Invoke-External -FilePath "winget" -Arguments @(
                    "install",
                    "--id", "Microsoft.VisualStudio.BuildTools",
                    "--source", "winget",
                    "--override", "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
                ) | Out-Null
                Invoke-External -FilePath "winget" -Arguments @("install", "--id", "Python.Python.3.12", "--source", "winget") | Out-Null
                Invoke-External -FilePath "npm" -Arguments @("config", "set", "msvs_version", "2026") | Out-Null
            }
            "R" { }
            default { throw "Native Module Refresh prerequisites were not installed." }
        }

        if (-not $nodeGypPath) {
            $nodeGypPath = Join-Path (Split-Path (Get-Command "npm" -ErrorAction Stop).Source -Parent) "node_modules\npm\node_modules\node-gyp\bin\node-gyp.js"
        }
        if (-not $pythonPath) {
            $pythonPath = Get-PythonForNodeGyp
        }
        $rebuild = Invoke-NativeModuleRebuild -AsarWorkDirectory $asarWorkDir -ElectronVersion $ElectronVersion -NodeGypPath $nodeGypPath -PythonPath $pythonPath
    }

    $pack = Invoke-External -FilePath "npx" -Arguments @("--yes", "asar", "pack", $asarWorkDir, $asarPath)
    if ($pack.ExitCode -ne 0) {
        throw "Unable to repack app.asar after Native Module Refresh. $($pack.Output)"
    }

    Sync-NativeModulesToUnpackedResources -AsarWorkDirectory $asarWorkDir -PackageDirectory $PackageDirectory
}

function Update-AppManifest {
    param([Parameter(Mandatory)][string] $PackageDirectory)

    $manifestPath = Join-Path $PackageDirectory "AppxManifest.xml"
    [xml] $manifest = Get-Content -LiteralPath $manifestPath -Raw
    $identity = $manifest.Package.Identity
    if ($null -eq $identity) {
        throw "AppxManifest.xml does not contain a Package Identity."
    }

    $identity.Name = $DevIdentityName
    if ($identity.HasAttribute("ProcessorArchitecture")) {
        $identity.ProcessorArchitecture = "arm64"
    }

    $manifest.Save($manifestPath)
    return $manifestPath
}

function Remove-StoreOriginArtifacts {
    param([Parameter(Mandatory)][string] $PackageDirectory)

    foreach ($fileName in @("AppxBlockMap.xml", "AppxSignature.p7x", "CodeIntegrity.cat")) {
        $path = Join-Path $PackageDirectory $fileName
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    foreach ($directoryName in @("AppxMetadata", "microsoft.system.package.metadata")) {
        $path = Join-Path $PackageDirectory $directoryName
        if (Test-Path -LiteralPath $path -PathType Container) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Install-ConvertedApp {
    param([Parameter(Mandatory)][string] $PackagePath)

    Add-AppxPackage -Path $PackagePath
}

function Invoke-ElevatedPackageSigningCertificateInstall {
    param(
        [Parameter(Mandatory)][string] $CertificatePath,
        [Parameter(Mandatory)][string] $CertificatePassword
    )

    $powerShellCommand = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $powerShellCommand) {
        $powerShellCommand = Get-Command "powershell.exe" -ErrorAction Stop
    }

    $escapedCertificatePath = $CertificatePath.Replace("'", "''")
    $escapedCertificatePassword = $CertificatePassword.Replace("'", "''")
    $command = @"
`$ErrorActionPreference = 'Stop'
Write-Host 'Installing Codex ARM64 package signing certificate with winapp.'
& winapp cert install '$escapedCertificatePath' --password '$escapedCertificatePassword'
if (`$LASTEXITCODE -ne 0) {
    exit `$LASTEXITCODE
}
Write-Host 'Certificate install complete. Closing this elevated window shortly.'
Start-Sleep -Seconds 3
"@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process `
        -FilePath $powerShellCommand.Source `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand) `
        -Verb RunAs `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Elevated winapp cert install failed with exit code $($process.ExitCode)."
    }
}

function Install-PackageSigningCertificateForCurrentUser {
    param([Parameter(Mandatory)][string] $CertificatePath)

    $publicCertificatePath = [IO.Path]::ChangeExtension($CertificatePath, ".cer")
    if (-not (Test-Path -LiteralPath $publicCertificatePath -PathType Leaf)) {
        throw "Current-user certificate trust failed because $publicCertificatePath was not found."
    }

    foreach ($storeLocation in @("Cert:\CurrentUser\TrustedPeople", "Cert:\CurrentUser\Root")) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($publicCertificatePath)
        $existingCertificate = Get-ChildItem -LiteralPath $storeLocation |
            Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } |
            Select-Object -First 1

        if ($null -eq $existingCertificate) {
            Import-Certificate -FilePath $publicCertificatePath -CertStoreLocation $storeLocation | Out-Null
        }
    }
}

function Install-PackageSigningCertificate {
    param(
        [Parameter(Mandatory)][string] $CertificatePath,
        [Parameter(Mandatory)][string] $CertificatePassword,
        [switch] $TrustRoot
    )

    if (-not $TrustRoot.IsPresent) {
        throw "The Converted App package signing certificate must be trusted before install. Re-run with -TrustSigningCertificate to run winapp cert install for this self-signed certificate."
    }

    Write-Host "Installing package signing certificate with winapp."
    $install = Invoke-External -FilePath "winapp" -Arguments @(
        "cert",
        "install",
        $CertificatePath,
        "--password", $CertificatePassword,
        "--quiet"
    )
    if ($install.ExitCode -eq 0) {
        return
    }

    if ($install.Output -notmatch "Access is denied") {
        throw "winapp cert install failed while trusting the package signing certificate. $($install.Output)"
    }

    Write-Host "winapp cert install requires administrator access; opening a visible elevated PowerShell window."
    try {
        Invoke-ElevatedPackageSigningCertificateInstall -CertificatePath $CertificatePath -CertificatePassword $CertificatePassword
    }
    catch {
        Write-Host "Elevated certificate install did not complete; trusting certificate for current user instead."
        Install-PackageSigningCertificateForCurrentUser -CertificatePath $CertificatePath
    }
}

function New-PackageSigningCertificate {
    param(
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $CertificatePath,
        [Parameter(Mandatory)][string] $CertificatePassword
    )

    New-Item -ItemType Directory -Force (Split-Path -Parent $CertificatePath) | Out-Null

    Write-Host "Creating or reusing winapp package signing certificate: $CertificatePath"
    $cert = Invoke-External -FilePath "winapp" -Arguments @(
        "cert",
        "generate",
        "--manifest", $ManifestPath,
        "--output", $CertificatePath,
        "--password", $CertificatePassword,
        "--valid-days", "1825",
        "--if-exists", "skip",
        "--export-cer",
        "--quiet"
    )
    if ($cert.ExitCode -ne 0) {
        throw "winapp cert generate failed while preparing package signing certificate. $($cert.Output)"
    }

    $cerPath = [IO.Path]::ChangeExtension($CertificatePath, ".cer")
    if (-not (Test-Path -LiteralPath $cerPath -PathType Leaf)) {
        throw "winapp cert generate did not produce the expected public certificate at $cerPath."
    }

    return $cerPath
}

function New-PackagedConvertedApp {
    param(
        [Parameter(Mandatory)][string] $PackageDirectory,
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $WorkDirectory,
        [switch] $TrustSigningCertificate
    )

    New-Item -ItemType Directory -Force (Split-Path -Parent $PackagePath), $WorkDirectory | Out-Null
    if (Test-Path -LiteralPath $PackagePath -PathType Leaf) {
        Remove-Item -LiteralPath $PackagePath -Force
    }

    $manifestPath = Join-Path $PackageDirectory "AppxManifest.xml"
    $certificatePath = Join-Path $WorkDirectory "codex-arm64-dev-signing.pfx"
    $certificatePassword = "password"
    New-PackageSigningCertificate -ManifestPath $manifestPath -CertificatePath $certificatePath -CertificatePassword $certificatePassword | Out-Null

    Write-Host "Packaging and signing Converted App with winapp: $PackagePath"
    $pack = Invoke-External -FilePath "winapp" -Arguments @(
        "package",
        $PackageDirectory,
        "--manifest", $manifestPath,
        "--output", $PackagePath,
        "--cert", $certificatePath,
        "--cert-password", $certificatePassword,
        "--quiet"
    )
    if ($pack.ExitCode -ne 0) {
        throw "winapp package failed while packaging Converted App. $($pack.Output)"
    }

    Install-PackageSigningCertificate -CertificatePath $certificatePath -CertificatePassword $certificatePassword -TrustRoot:$TrustSigningCertificate.IsPresent

    return $PackagePath
}

try {
    $root = Assert-SafeOutputRoot -Path $OutputRoot
    $snapshot = Join-Path $root "snapshot"
    $work = Join-Path $root "work"
    $converted = Join-Path $root "converted"
    $packageOutput = Join-Path $root "package"
    $electronZip = Join-Path $root "electron\electron-arm64.zip"
    $msixPackage = Join-Path $packageOutput "Codex-Arm64Dev.msix"

    New-Item -ItemType Directory -Force $snapshot, $work, $converted, $packageOutput | Out-Null

    Write-Host "Converting Codex Store product $ProductId to a packaged ARM64 Converted App."
    $existingPackage = Get-CodexStorePackage
    $storePackageState = Ensure-CodexStorePackageCurrent -ExistingPackage $existingPackage

    $installedPackage = Get-CodexStorePackage
    if ($null -eq $installedPackage) {
        throw "Codex Store Package was not found after winget/msstore install."
    }

    $existingConvertedPackage = Get-ExistingConvertedPackage
    if (($storePackageState.Action -eq "Current") -and
        ($null -ne $existingConvertedPackage) -and
        (Test-ConvertedPackageMatchesStorePackage -ConvertedPackage $existingConvertedPackage -StorePackage $installedPackage) -and
        (Test-ConvertedPackageIsInstalledPackage -ConvertedPackage $existingConvertedPackage)) {
        Write-Host "Converted App is already current at version $($existingConvertedPackage.Version); nothing to do."
        Write-Host "Removing current-user Codex Store Package so only the Converted App remains installed."
        Remove-CodexStorePackage -Package $installedPackage
        return
    }

    if ($null -ne $existingPackage) {
        Show-ReplacementBanner -Package $installedPackage
    }

    $convertedPackageDir = Join-Path $converted "Codex"
    $packageDir = New-StorePackageSnapshot -Package $installedPackage -SnapshotDirectory (Join-Path $snapshot "Codex")
    if (Test-Path -LiteralPath $convertedPackageDir) {
        Remove-Item -LiteralPath $convertedPackageDir -Recurse -Force
    }
    Copy-Item -LiteralPath $packageDir -Destination $convertedPackageDir -Recurse -Force

    $electronVersion = Get-ElectronVersion -PackageDirectory $convertedPackageDir -WorkDirectory $work
    Write-Host "Electron version: $electronVersion"

    Ensure-ElectronRuntime -Version $electronVersion -DestinationPath $electronZip
    Replace-ElectronRuntime -PackageDirectory $convertedPackageDir -ElectronZipPath $electronZip -WorkDirectory $work
    Refresh-NativeModules -PackageDirectory $convertedPackageDir -ElectronVersion $electronVersion -WorkDirectory $work

    Remove-StoreOriginArtifacts -PackageDirectory $convertedPackageDir
    Update-AppManifest -PackageDirectory $convertedPackageDir | Out-Null
    New-PackagedConvertedApp -PackageDirectory $convertedPackageDir -PackagePath $msixPackage -WorkDirectory $work -TrustSigningCertificate:$TrustSigningCertificate.IsPresent | Out-Null

    Remove-ExistingConvertedPackage
    Write-Host "Installing packaged Converted App for current-user with dev identity $DevIdentityName."
    Install-ConvertedApp -PackagePath $msixPackage
    Remove-CodexStorePackage -Package $installedPackage

    Write-Host "Package install success."
    Write-Host "Converted App was not launched. Runtime verification is out of scope."
    Write-Host "Converted App package: $msixPackage"
    Write-Host "Conversion Artifacts kept at: $root"
}
catch {
    Write-Error $_
    exit 1
}
