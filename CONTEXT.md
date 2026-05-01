# Codex Desktop ARM64 Setup

This context captures the local Windows ARM64 setup work for running Codex desktop with ARM64 components, either through a backend override or through a converted Electron app package.

## Language

**Codex Desktop App**:
The installed Electron-based Windows app distributed through Microsoft Store.
_Avoid_: CLI, backend

**Store Package**:
The signed Microsoft Store installation of the Codex Desktop App under `WindowsApps`.
_Avoid_: patched app

**Temporary Store Install Snapshot**:
A copy of the current-user Codex Store Package staged outside `WindowsApps` before conversion.
_Avoid_: downloaded package, live WindowsApps package, patched package

**Bundled Backend**:
The Codex executable shipped inside the Store Package resources and spawned by the Codex Desktop App.
_Avoid_: installed CLI, PATH CLI

**PATH Backend**:
The ARM64 Codex executable resolved from the user's `PATH`.
_Avoid_: bundled backend, copied backend

**Backend Override**:
The user-overridable configuration that makes the Codex Desktop App launch the PATH Backend instead of the Bundled Backend.
_Avoid_: binary conversion, WindowsApps patch

**Setup Script**:
The lightweight script that configures the Backend Override.
_Avoid_: conversion script, rebuild script

**Conversion Script**:
The heavier script that snapshots a current-user Store Package and converts the snapshot into an ARM64 Electron app package.
_Avoid_: setup script, env override

**Converted App**:
The packaged Codex Desktop App whose Electron runtime and native components are ARM64.
_Avoid_: Store Package, Backend Override

**Dev Identity**:
The non-visible package identity used by the Converted App after the Store Package has been removed.
_Avoid_: original Store identity

**Shared Codex Home**:
The normal `~/.codex` configuration and history used by both the Store Package and the Converted App.
_Avoid_: copied profile, isolated test profile

**Matching Electron Runtime**:
The ARM64 Electron runtime downloaded at the same Electron version used by the Downloaded Store Package.
_Avoid_: arbitrary Electron version, locally prepared runtime

**Native Module Refresh**:
The replacement or rebuild of Electron native Node modules for ARM64, including the unpacked native-addon copies loaded by Electron.
_Avoid_: leaving x64 native modules in place

**Store Origin Artifacts**:
Signature and metadata files copied from the Store Package that must be removed before packaging the Converted App.
_Avoid_: Store-signed dev package

**Prerequisite Prompt**:
The conversion stop point that lists missing build tools and lets the user install them through the script or resume after manual installation.
_Avoid_: silent prerequisite installation, best-effort continuation

**Converted App Package**:
The signed MSIX package built from the converted output and installed for the current user.
_Avoid_: unpacked app registration, scratch-launched app

**Store Package Version**:
The exact four-part package identity version copied from the Store Package manifest into the Converted App Package.
_Avoid_: generated dev version, semantic app version

**Signing Certificate Trust**:
The explicit `-TrustSigningCertificate` choice that runs `winapp cert install` for the local package-signing certificate, using a visible elevated PowerShell window when machine-level trust requires admin.
_Avoid_: implicit trust, hidden certificate install

**Conversion Artifacts**:
The package snapshot, extracted files, generated package, logs, and converted output retained after conversion.
_Avoid_: throwaway scratch, hidden temp output

**Replacement Banner**:
The start-of-script message that warns when an existing Codex Store Package will be replaced by the Converted App.
_Avoid_: hidden uninstall, silent replacement

**Registration Success**:
The point where the Converted App Package has been installed for the current user.
_Avoid_: launch success, runtime smoke test

**Out-of-Scope Verification**:
Runtime launch or smoke-test automation that the scripts deliberately do not perform.
_Avoid_: conversion success criteria, setup success criteria

**Manual Restart**:
The user-controlled restart of the Codex Desktop App after a Backend Override is changed.
_Avoid_: forced restart, automatic relaunch

## Relationships

- The **Codex Desktop App** belongs to exactly one **Store Package**.
- The **Store Package** contains one **Bundled Backend**.
- The **Setup Script** sets the **Backend Override** and lets the user choose the **PATH Backend**.
- The **Backend Override** points the **Codex Desktop App** at the **PATH Backend**.
- A **Manual Restart** is required before the **Codex Desktop App** inherits a changed **Backend Override**.
- The **PATH Backend** depends on sibling ARM64 backend tools being available in the same directory or on `PATH`.
- The **Conversion Script** installs a missing current-user **Store Package**, checks `winget upgrade` before updating an existing **Store Package**, creates a **Temporary Store Install Snapshot**, produces and installs a **Converted App Package** with a **Dev Identity**, then removes the current-user **Store Package**.
- If an existing packaged **Converted App** already matches a current **Store Package**, the **Conversion Script** skips snapshot and conversion work and only removes the duplicate **Store Package**.
- The **Converted App** uses the **Shared Codex Home**.
- The **Converted App** uses a **Matching Electron Runtime**.
- The **Converted App** requires a **Native Module Refresh**.
- The **Converted App** still relies on the **Backend Override** for the active backend.
- The **Converted App Package** keeps the runtime out of the conversion artifact directory.
- The **Converted App Package** preserves the **Store Package Version**.
- **Signing Certificate Trust** is required before Windows can install the locally signed **Converted App Package**.
- A **Native Module Refresh** may require a **Prerequisite Prompt**.
- The **Conversion Script** keeps **Conversion Artifacts**.
- The **Conversion Script** prints a **Replacement Banner** before changing anything when it detects an existing current-user **Store Package**.
- The **Conversion Script** stops at **Registration Success**.
- **Out-of-Scope Verification** is not part of either script.

## Example Dialogue

> **Dev:** "Is the first script enough?"
> **Domain expert:** "No. The **Setup Script** only sets the **Backend Override**. The **Conversion Script** is separate and must produce a **Converted App** from a **Temporary Store Install Snapshot**."

## Flagged Ambiguities

- "Convert the app to ARM64" means producing a **Converted App**, not only setting a **Backend Override**.
- "Patch the app" does not mean editing the live **Store Package** under `WindowsApps`; conversion works only from a copied **Temporary Store Install Snapshot**.
