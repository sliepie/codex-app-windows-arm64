# ARM64 Scripts

## 1. Setup Script

Goal: configure the installed Codex Desktop App to use an ARM64 backend without converting the Electron app.

Requirements:

- Accept a user override for the Codex CLI path, for example `-CodexCliPath .\tools\codex.exe`.
- If no override is supplied, resolve `codex.exe` from `PATH`.
- Verify the chosen executable is ARM64 before changing anything.
- Persist `CODEX_CLI_PATH` for the user account to the full executable path.
- Do not stop or relaunch the Codex Desktop App.
- Print the current value, new value, and the manual restart/log-check instructions.

## 2. Conversion Script

Goal: convert a snapshot of the current-user Codex Store Electron package into an ARM64 app package.

Requirements:

- Use a package snapshot staged outside `WindowsApps`; never mutate the live installed Store package in place.
- Install or update the Codex Store package through official `winget`/`msstore` only.
- If a current-user Store package is already installed, check `winget upgrade` first and skip Store install/update when no update is available.
- If the Converted App is already installed as a package at the same version and no Store update is available, skip snapshot/conversion/package installation and only remove the Store Package so duplicate Codex apps are not left installed.
- Use `--scope user` for Store install.
- Run Store install noninteractively so the script does not open popups or steal terminal focus.
- If an existing current-user Codex Store package is detected at startup, print a clear banner that it will be replaced.
- After the Store package is installed and copied to the snapshot directory, build and install the Converted App package before removing the current-user Store package.
- Hardcode the Codex Store product ID `9PLM9XGG6VKS`.
- Do not leave the Store Package and Converted App installed side-by-side.
- Treat Store install, snapshot, and uninstall failures as hard failures with clear error output.
- Read the Electron version from the snapshot app metadata and download the matching ARM64 Electron runtime automatically.
- Reuse the cached ARM64 Electron runtime when its embedded Electron version matches the snapshot app metadata.
- Replace the x64 Electron runtime with that matching ARM64 Electron runtime.
- Replace native Node modules with ARM64/Electron-compatible prebuilds when available.
- Rebuild native Node modules locally for ARM64/Electron when prebuilds are missing or incompatible, including `node-pty` and `better-sqlite3`.
- Sync refreshed native modules into `app.asar.unpacked` so Electron loads the ARM64 native addons.
- Strip Store signature/origin artifacts from the snapshot before packaging the Converted App.
- If rebuild prerequisites are missing, stop and print an exact checklist with matching `winget`/`npm` commands, including the Visual Studio C++ workload override.
- At the missing-prerequisite prompt, let the user choose between having the script install prerequisites or installing them manually and resuming.
- Keep the app's `app.asar` logic unless a targeted patch is needed.
- Preserve the `CODEX_CLI_PATH` behavior and rely on it for the active backend.
- Do not replace bundled backend tools as part of conversion.
- Build and sign an MSIX package from the converted output with `winapp`; do not register the converted output directory directly.
- Preserve the Store Package identity version exactly in the Converted App manifest.
- Create or reuse a `winapp` development signing certificate matching the Converted App publisher.
- Run `winapp cert install` only when `-TrustSigningCertificate` is supplied, and open a visible elevated PowerShell window when machine-level certificate trust needs admin.
- Install the packaged Converted App under a distinct dev identity after the installed Store Package has been removed.
- Install the packaged Converted App for the current user only.
- Keep the visible app name as Codex.
- Share the normal Codex config/history under `~/.codex`.
- Keep package-local Electron data separate through the Converted App's distinct dev identity.
- Keep package snapshots, extracted files, logs, and converted output artifacts after success.
- Keep the generated package under `<OutputRoot>\package`.
- Report success after current-user package installation succeeds.
- Do not launch the Converted App or run runtime checks from the conversion script.
- Do not add a separate verification script.
