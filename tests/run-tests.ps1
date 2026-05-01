Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TempRoot = Join-Path $RepoRoot ".test-tmp"

function New-PeFixture {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [ValidateSet("ARM64", "x64")]
        [string] $Architecture
    )

    $machine = switch ($Architecture) {
        "ARM64" { 0xAA64 }
        "x64" { 0x8664 }
    }

    $bytes = [byte[]]::new(512)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    $bytes[0x82] = 0x00
    $bytes[0x83] = 0x00
    [BitConverter]::GetBytes([uint16]$machine).CopyTo($bytes, 0x84)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    try {
        & $Body
        Write-Host "PASS $Name"
    }
    catch {
        Write-Host "FAIL $Name"
        Write-Host $_
        exit 1
    }
}

function Invoke-Script {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = & pwsh -NoProfile @Arguments 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output | Out-String)
    }
}

function Get-ScriptFunctionText {
    param([Parameter(Mandatory)][string] $Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "Unable to parse $Path."
    }

    $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object { $_.Extent.Text }
}

function New-ElectronRuntimeZipFixture {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Version
    )

    $sourceDirectory = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([IO.Path]::GetFileNameWithoutExtension($Path))
    if (Test-Path -LiteralPath $sourceDirectory) {
        Remove-Item -LiteralPath $sourceDirectory -Recurse -Force
    }

    New-Item -ItemType Directory -Force $sourceDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $sourceDirectory "version") -Value $Version
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    Compress-Archive -Path (Join-Path $sourceDirectory "*") -DestinationPath $Path
}

if (Test-Path $TempRoot) {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
}
New-Item -ItemType Directory -Force $TempRoot | Out-Null

$setupScript = Join-Path $RepoRoot "scripts\setup-codex-arm64-backend.ps1"
$convertScript = Join-Path $RepoRoot "scripts\convert-codex-store-app-arm64.ps1"
$arm64Codex = Join-Path $TempRoot "codex-arm64.exe"
$x64Codex = Join-Path $TempRoot "codex-x64.exe"
New-PeFixture -Path $arm64Codex -Architecture ARM64
New-PeFixture -Path $x64Codex -Architecture x64

Invoke-Test "setup accepts ARM64 override" {
    $previousValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", "User")
    try {
        $result = Invoke-Script -Arguments @("-File", $setupScript, "-CodexCliPath", $arm64Codex)
        if ($result.ExitCode -ne 0) { throw $result.Output }
        if ($result.Output -notmatch [regex]::Escape($arm64Codex)) { throw "Expected output to include selected CLI path. Output: $($result.Output)" }
        if ($result.Output -notmatch "ARM64") { throw "Expected output to mention ARM64. Output: $($result.Output)" }

        $actualValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", "User")
        if ($actualValue -ne $arm64Codex) { throw "Expected user CODEX_CLI_PATH to be $arm64Codex but was $actualValue" }
    }
    finally {
        [Environment]::SetEnvironmentVariable("CODEX_CLI_PATH", $previousValue, "User")
    }
}

Invoke-Test "setup rejects non-ARM64 override" {
    $previousValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", "User")
    $result = Invoke-Script -Arguments @("-File", $setupScript, "-CodexCliPath", $x64Codex)
    if ($result.ExitCode -eq 0) { throw "Expected nonzero exit for x64 fixture. Output: $($result.Output)" }
    if ($result.Output -notmatch "ARM64") { throw "Expected rejection to mention ARM64. Output: $($result.Output)" }

    $actualValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", "User")
    if ($actualValue -ne $previousValue) { throw "Expected user CODEX_CLI_PATH to remain unchanged." }
}

Invoke-Test "conversion uses official Store install and fails hard when winget fails" {
    $fakeBin = Join-Path $TempRoot "fake-bin"
    New-Item -ItemType Directory -Force $fakeBin | Out-Null
    $fakeWinget = Join-Path $fakeBin "winget.cmd"
    $fakeWingetArgs = Join-Path $TempRoot "fake-winget-args.txt"
    Set-Content -LiteralPath $fakeWinget -Value "@echo off`r`necho fake winget received %* > `"$fakeWingetArgs`"`r`nexit /b 23`r`n"

    $previousPath = $env:PATH
    try {
        $env:PATH = "$fakeBin;$previousPath"
        $result = Invoke-Script -Arguments @("-File", $convertScript, "-OutputRoot", (Join-Path $TempRoot "conversion"))
    }
    finally {
        $env:PATH = $previousPath
    }

    if ($result.ExitCode -eq 0) { throw "Expected nonzero exit when winget fails. Output: $($result.Output)" }
    $wingetArgs = Get-Content -LiteralPath $fakeWingetArgs -Raw
    if ($result.Output -notmatch "9PLM9XGG6VKS") { throw "Expected Codex Store product ID. Output: $($result.Output)" }
    if ($result.Output -notmatch "winget") { throw "Expected official winget/msstore install in plan. Output: $($result.Output)" }
    if ($wingetArgs -notmatch "install") { throw "Expected winget install. Args: $wingetArgs" }
    if ($wingetArgs -notmatch "source msstore") { throw "Expected msstore source. Args: $wingetArgs" }
    if ($wingetArgs -notmatch "scope user") { throw "Expected current-user install scope. Args: $wingetArgs" }
    if ($wingetArgs -notmatch "silent") { throw "Expected silent Store install. Args: $wingetArgs" }
    if ($wingetArgs -notmatch "disable-interactivity") { throw "Expected noninteractive Store install. Args: $wingetArgs" }
}

Invoke-Test "conversion validates cached Electron runtime by version" {
    foreach ($functionText in Get-ScriptFunctionText -Path $convertScript) {
        . ([scriptblock]::Create($functionText))
    }

    $electronZip = Join-Path $TempRoot "electron-cache\electron-arm64.zip"
    New-Item -ItemType Directory -Force (Split-Path -Parent $electronZip) | Out-Null
    New-ElectronRuntimeZipFixture -Path $electronZip -Version "31.2.0"

    if (-not (Test-ElectronRuntimeCache -Version "31.2.0" -ZipPath $electronZip)) {
        throw "Expected matching Electron runtime cache to be accepted."
    }

    if (Test-ElectronRuntimeCache -Version "31.2.1" -ZipPath $electronZip) {
        throw "Expected mismatched Electron runtime cache to be rejected."
    }
}

Invoke-Test "conversion installs packaged app instead of scratch registration" {
    foreach ($functionText in Get-ScriptFunctionText -Path $convertScript) {
        . ([scriptblock]::Create($functionText))
    }

    $scriptText = Get-Content -LiteralPath $convertScript -Raw
    if ($scriptText -match "Add-AppxPackage\s+-Register") {
        throw "Expected conversion to avoid registering the scratch output directory."
    }

    if ($scriptText -notmatch "winapp[\s\S]*package") {
        throw "Expected conversion to package the converted output with winapp."
    }

    if ($scriptText -notmatch "winapp[\s\S]*cert[\s\S]*generate") {
        throw "Expected conversion to generate the signing certificate with winapp."
    }

    if ($scriptText -notmatch "winapp[\s\S]*cert[\s\S]*install") {
        throw "Expected conversion to trust the package signing certificate with winapp."
    }

    if ($scriptText -notmatch [regex]::Escape("Cert:\CurrentUser\Root")) {
        throw "Expected conversion to keep a current-user certificate trust fallback when elevated trust is unavailable."
    }

    if ($scriptText -notmatch "Start-Process[\s\S]*-Verb RunAs") {
        throw "Expected conversion to launch a visible elevated PowerShell window when certificate trust needs admin."
    }

    if ($scriptText -notmatch [regex]::Escape("-TrustSigningCertificate")) {
        throw "Expected conversion to require an explicit switch before trusting the package signing root."
    }

    $packageIndex = $scriptText.IndexOf("New-PackagedConvertedApp", [StringComparison]::Ordinal)
    $removeStoreIndex = $scriptText.IndexOf("Remove-CodexStorePackage -Package `$installedPackage", [StringComparison]::Ordinal)
    if ($packageIndex -lt 0 -or $removeStoreIndex -lt 0 -or $packageIndex -gt $removeStoreIndex) {
        throw "Expected conversion to build the package before removing the Store app."
    }

    $winappPackageIndex = $scriptText.IndexOf('"package"', [StringComparison]::Ordinal)
    $certInstallIndex = $scriptText.IndexOf('"install"', $scriptText.IndexOf('"cert"', [StringComparison]::Ordinal), [StringComparison]::Ordinal)
    if ($winappPackageIndex -lt 0 -or $certInstallIndex -lt 0 -or $winappPackageIndex -gt $certInstallIndex) {
        throw "Expected conversion to create the signed package before installing the signing certificate."
    }

    $scratchPackage = [pscustomobject]@{ InstallLocation = "C:\dev\source\codex-app\.scratch\codex-arm64-conversion\converted\Codex" }
    if (Test-ConvertedPackageIsInstalledPackage -ConvertedPackage $scratchPackage) {
        throw "Expected scratch registered package to be treated as not packaged."
    }

    $installedPackage = [pscustomobject]@{ InstallLocation = "C:\Program Files\WindowsApps\OpenAI.Codex.Arm64Dev_26.429.2026.0_arm64__abc" }
    if (-not (Test-ConvertedPackageIsInstalledPackage -ConvertedPackage $installedPackage)) {
        throw "Expected WindowsApps package to be treated as packaged."
    }
}

Invoke-Test "conversion preserves Store package version in converted manifest" {
    foreach ($functionText in Get-ScriptFunctionText -Path $convertScript) {
        . ([scriptblock]::Create($functionText))
    }

    $DevIdentityName = "OpenAI.Codex.Arm64Dev"
    $manifestDirectory = Join-Path $TempRoot "manifest-version"
    New-Item -ItemType Directory -Force $manifestDirectory | Out-Null
    $manifestPath = Join-Path $manifestDirectory "AppxManifest.xml"
    Set-Content -LiteralPath $manifestPath -Value @"
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10">
  <Identity Name="OpenAI.Codex" ProcessorArchitecture="x64" Version="26.429.2026.0" Publisher="CN=50BDFD77-8903-4850-9FFE-6E8522F64D5B" />
</Package>
"@

    Update-AppManifest -PackageDirectory $manifestDirectory | Out-Null
    [xml] $manifest = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifest.Package.Identity.Version -ne "26.429.2026.0") {
        throw "Expected converted manifest to preserve Store package version. Actual: $($manifest.Package.Identity.Version)"
    }
}

Write-Host "All tests passed."
