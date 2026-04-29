# Split ARM64 setup into override and conversion scripts

The installed Codex Microsoft Store package is x64 on this ARM64 Windows machine, and `winget` reports no applicable ARM64 installer for Store product `9PLM9XGG6VKS`. We split the work into two scripts because backend selection and Electron package conversion have different risk, permissions, and rollback boundaries.

## Considered Options

- Request an ARM64 Store package through `winget`: rejected because both `winget download --architecture arm64` and forced `winget install --architecture arm64` reported no applicable installer.
- Use only `CODEX_CLI_PATH`: rejected because it does not convert the Electron shell or native app modules to ARM64.
- Patch or replace binaries inside live `WindowsApps`: rejected because the Store package is signed/protected and in-place edits are fragile across updates.
- Combine setup and conversion into one script: rejected because backend override and Electron package conversion have different risk, permissions, and verification paths.

## Consequences

- `setup-codex-arm64-backend.ps1` owns the `CODEX_CLI_PATH` backend override.
- `convert-codex-store-app-arm64.ps1` owns temporary Store install snapshot conversion to an unpacked ARM64 app.
- Detailed script behavior lives in `docs/arm64-scripts.md`; this ADR records why the split exists.

## Update: Store install snapshot

`winget download --source msstore` requires Microsoft Entra ID authentication for Store package download authorization. A personal Microsoft account can install the Store app, but cannot satisfy that download authorization path.

The conversion script therefore installs the Codex Store Package when it is missing. If the Store Package already exists, the script checks `winget upgrade` first and updates only when Store reports an available upgrade. It then copies the installed package to a snapshot outside `WindowsApps`, removes the current-user Store Package, and converts the snapshot. If a Store Package already exists at startup, the script prints a replacement banner before making changes so the user knows the Store app will be replaced by the Converted App.

Before developer-mode registration, the script removes Store signature/origin artifacts from the snapshot. Windows rejects an unpacked dev registration when copied Store origin metadata is left in place.

When the existing Converted App already matches the current Store Package version and Store reports no upgrade, the script skips snapshot, native module refresh, and registration. It only removes the current-user Store Package so the user is not left with two Codex apps.
