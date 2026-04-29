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

Write-Host "All tests passed."
