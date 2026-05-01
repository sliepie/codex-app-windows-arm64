# Codex App Windows ARM64

ARM64 conversion scripts for the Codex Windows app.

This repository targets the Microsoft Store distributed Codex desktop app, not the Codex CLI. The conversion script snapshots the current-user Store install, replaces the Electron runtime and native modules with ARM64-compatible versions, builds and installs a signed current-user package, and removes the Store package so only one Codex app remains installed.

## Scripts

- `scripts/setup-codex-arm64-backend.ps1`
  Sets the user-level `CODEX_CLI_PATH` override to an ARM64 `codex.exe`.
- `scripts/convert-codex-store-app-arm64.ps1`
  Converts the Store app snapshot into a packaged ARM64 Codex desktop app.

## Prerequisites

- Windows on ARM64
- PowerShell 7+
- `winget` with Microsoft Store source access
- `winapp` Windows App Development CLI
- Node.js/npm available on `PATH`
- Developer Mode or sideloading enabled for local package installation
- Internet access for Store install, Electron download, and npm package fetches

For native module fallback rebuilds, install:

- Python 3.12
- Visual Studio Build Tools 2026 with the C++ workload

## Usage

Run from PowerShell:

```powershell
pwsh -NoProfile -File .\scripts\convert-codex-store-app-arm64.ps1 -TrustSigningCertificate
```

The script:

- installs the Codex Store app for the current user if it is missing
- checks `winget upgrade` before updating an existing Store install
- skips conversion work when the converted app already matches the Store version
- reuses the cached ARM64 Electron runtime when the cached zip matches the Store app's Electron version
- removes the Store app after snapshot/conversion so duplicate Codex apps are not left installed
- builds and signs a local MSIX package with `winapp`, then installs it for the current user
- runs `winapp cert install` for the local signing certificate only when `-TrustSigningCertificate` is supplied, falling back to current-user trust if machine-level trust needs admin
- keeps conversion artifacts under `.scratch\codex-arm64-conversion`
- keeps the generated package under `.scratch\codex-arm64-conversion\package`

## Notes

`winget download --source msstore` can require Microsoft Entra ID authorization for offline Store package download. This project avoids that path by using the current-user Store install as the source snapshot.

The script does not launch Codex after conversion.
