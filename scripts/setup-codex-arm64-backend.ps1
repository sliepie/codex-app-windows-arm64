[CmdletBinding()]
param(
    [string] $CodexCliPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-CodexCliPath {
    param([string] $OverridePath)

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $resolved = Resolve-Path -LiteralPath $OverridePath -ErrorAction Stop
        $item = Get-Item -LiteralPath $resolved.Path -ErrorAction Stop
        if (-not $item.PSIsContainer) {
            return $item.FullName
        }

        throw "Codex CLI path must be a file: $OverridePath"
    }

    $command = Get-Command "codex.exe" -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command "codex" -ErrorAction SilentlyContinue
    }

    if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Source)) {
        throw "Unable to resolve codex.exe from PATH. Pass -CodexCliPath with a full path."
    }

    return (Get-Item -LiteralPath $command.Source -ErrorAction Stop).FullName
}

function Get-PeArchitecture {
    param([Parameter(Mandatory)][string] $Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 0x86) {
            throw "File is too small to be a PE executable: $Path"
        }

        $reader = [IO.BinaryReader]::new($stream)
        try {
            if ($reader.ReadByte() -ne 0x4D -or $reader.ReadByte() -ne 0x5A) {
                throw "File is not a PE executable: $Path"
            }

            $stream.Seek(0x3C, [IO.SeekOrigin]::Begin) | Out-Null
            $peOffset = $reader.ReadInt32()
            if ($peOffset -lt 0 -or $peOffset + 6 -gt $stream.Length) {
                throw "File has an invalid PE header offset: $Path"
            }

            $stream.Seek($peOffset, [IO.SeekOrigin]::Begin) | Out-Null
            $signature = $reader.ReadUInt32()
            if ($signature -ne 0x00004550) {
                throw "File has an invalid PE signature: $Path"
            }

            $machine = $reader.ReadUInt16()
            switch ($machine) {
                0xAA64 { return "ARM64" }
                0x8664 { return "x64" }
                0x014C { return "x86" }
                default { return ("unknown 0x{0:X4}" -f $machine) }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

try {
    $resolvedPath = Resolve-CodexCliPath -OverridePath $CodexCliPath
    $architecture = Get-PeArchitecture -Path $resolvedPath

    if ($architecture -ne "ARM64") {
        throw "Selected Codex CLI is $architecture, not ARM64: $resolvedPath"
    }

    $previousValue = [Environment]::GetEnvironmentVariable("CODEX_CLI_PATH", "User")

    Write-Host "Selected Codex CLI: $resolvedPath"
    Write-Host "Architecture: ARM64"
    Write-Host "Previous user CODEX_CLI_PATH: $($previousValue ?? '<not set>')"
    Write-Host "New user CODEX_CLI_PATH: $resolvedPath"

    [Environment]::SetEnvironmentVariable("CODEX_CLI_PATH", $resolvedPath, "User")

    Write-Host "Codex Desktop App was not stopped or relaunched."
    Write-Host "Restart Codex Desktop App manually for it to inherit CODEX_CLI_PATH."
}
catch {
    Write-Error $_
    exit 1
}
