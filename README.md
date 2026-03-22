# 📦 Intune-Winget: Deploy Win32 Apps via Winget to Microsoft Intune

Automate packaging and deployment of **Win32 apps** to **Microsoft Intune** using **winget** for metadata and **Microsoft Graph API** for upload. Two PowerShell scripts work together: `package.ps1` builds the `.intunewin` packages, and `deploy.ps1` uploads them to Intune and creates assignment groups.

---

## 📋 Table of Contents

- [Prerequisites](#-prerequisites)
- [Quick Start](#-quick-start)
- [package.ps1 – Packaging](#-packageps1--packaging)
- [deploy.ps1 – Deployment](#-deployps1--deployment)
- [Icons](#-icons)
- [Folder Structure](#-folder-structure)
- [Configuration Reference](#-configuration-reference)
- [Troubleshooting](#-troubleshooting)

---

## ✅ Prerequisites

| Requirement | Description |
|-------------|-------------|
| 🪟 **Windows** | Scripts run on Windows (winget, IntuneWinAppUtil) |
| 📜 **PowerShell 5.1+** | Windows PowerShell or PowerShell Core |
| 🥧 **winget** | [Windows Package Manager](https://learn.microsoft.com/en-us/windows/package-manager/winget/) installed |
| 📁 **IntuneWinAppUtil.exe** | [Download](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases) from GitHub, extract zip, place exe in project root |
| 🔐 **Microsoft Graph** | `Microsoft.Graph` and `Microsoft.Graph.Beta` modules |
| 🏢 **Intune license** | Active Intune license for your tenant |

### Install Graph modules

```powershell
Install-Module -Name Microsoft.Graph, Microsoft.Graph.Beta -Scope CurrentUser
```

---

## 🚀 Quick Start

### 1. Add apps to `apps.csv`

| Column | Description |
|--------|-------------|
| `ApplicationName` | Display name (used for folder, Intune app name) |
| `WingetAppId` | Winget package identifier (e.g. `7zip.7zip`) |
| `InstallContext` | `system` or `user` – system uses path resolution (WindowsApps), user calls winget directly. Default: `system` |
| `InstallOverride` | Optional string passed to `winget install --override` (e.g. `/silent`). Leave empty for none. |

**How to find `WingetAppId`:**

- Search: `winget search "7-Zip"` → look at the **Id** column

```csv
ApplicationName,WingetAppId,InstallContext,InstallOverride
7-Zip,7zip.7zip,system,
Notepad++,Notepad++.Notepad++,system,
Jabra Direct,Jabra.Direct,user,/silent
```

### 2. Run packaging

```powershell
.\package.ps1
```

This creates `.intunewin` packages in `apps\<AppName>\` and fetches metadata (description, publisher, architectures) from winget.

### 3. Run deployment

```powershell
.\deploy.ps1
```

Connect to Microsoft Graph when prompted. The script deploys **apps listed in `apps.csv`** (that have a matching packaged folder in `apps/`), uploads them to Intune, and optionally creates assignment groups.

**Overwrite existing apps** (re-upload content and refresh all metadata, keep assignments unchanged):

```powershell
.\deploy.ps1 -OverwriteExisting
```

---

## 📦 package.ps1 – Packaging

Builds Win32 app packages from `apps.csv` using templates and winget metadata.

### Features

| Feature | Description |
|---------|-------------|
| 📄 **CSV-driven** | Define apps in `apps.csv` with `ApplicationName` and `WingetAppId` |
| 🌐 **Localization** | Normalizes `winget show` output to English via `jsons/language.json` (works on de-DE, fr-FR, etc.) |
| 🏗️ **Architecture detection** | Probes x86, x64, arm64; only includes supported architectures in `info.json` |
| 📝 **Templates** | Uses `templates/install.ps1`, `uninstall.ps1`, `detection.ps1` with placeholder replacement |
| 📂 **Output** | Creates `apps\<AppName>\` with `.intunewin`, `info.json`, `detection.ps1`, and scripts |

### Configuration (top of script)

| Variable | Default | Description |
|----------|---------|-------------|
| `$keepPlainScripts` | `$true` | Keep install/uninstall in `scripts/` subfolder |
| `$quiet` | `$true` | Quiet mode for IntuneWinAppUtil |
| `$fetchWingetShow` | `$true` | Fetch metadata from winget and save `info.json` |
| `$forceRepack` | `$false` | Rebuild all apps; if `$false`, skips already packed |

### Output per app

- `AppName.intunewin` – Intune-ready package
- `info.json` – Name, Description, Publisher, URLs, Architectures, InstallContext (for deploy runAsAccount)
- `detection.ps1` – Detection script
- `scripts/install.ps1`, `scripts/uninstall.ps1` – Install/uninstall scripts

---

## 🚀 deploy.ps1 – Deployment

Uploads packaged apps from `apps/` to Microsoft Intune via Graph API (beta) and optionally creates Entra groups and assignments.

### Features

| Feature | Description |
|---------|-------------|
| 📄 **CSV-driven deploy** | Deploys apps listed in `apps.csv`; skips rows with no matching packaged folder |
| 📤 **Win32 upload** | Creates app, uploads content (chunked), commits with encryption info |
| 🏛️ **Architecture** | Sets Requirements tab from `info.json` (x86-only → x86,x64) |
| 👤 **Install context** | When `InstallContext=user` in info.json, sets `runAsAccount=user` and uses `powershell.exe` for install/uninstall; system context uses `%WINDIR%\sysnative\...` path |
| 🖼️ **Icons** | Resolves icons from `icons/` (exact + prefix matching) |
| 👥 **Group creation** | Creates RQ (Required) and AV (Available) groups with configurable naming |
| 🔄 **OverwriteExisting** | `-OverwriteExisting` re-uploads content and refreshes all app metadata; group assignments remain unchanged |
| 🚫 **Blacklist** | Skip group creation for specific apps (wildcards supported) |
| 🔐 **Graph auth** | Checks modules, scopes, and tenant; re-auths if scopes missing |
| 📢 **Notifications** | Required assignments use “Hide all toast notifications” |

### Parameters

| Parameter | Description |
|-----------|-------------|
| `-OverwriteExisting` | Re-upload content and refresh all metadata for apps already in Intune; group assignments stay unchanged |

### Configuration (top of script)

| Variable | Default | Description |
|----------|---------|-------------|
| `$enableGroupCreation` | `$true` | Create Entra groups and assign app |
| `$groupNamingAppSuffix` | `$true` | `Win - SW - RQ - %app%` style; `$false` → `Win - SW - %app% - RQ` |
| `$groupCreationBlacklist` | `@('Microsoft Visual C++*')` | Apps to skip for group creation (supports `*`) |
| `$graphScopes` | `DeviceManagementApps.ReadWrite.All`, `Group.ReadWrite.All` | Graph permissions |
| `$logDebug` | `$false` | Enable debug logs and `deploy-request-body.json` dump |

### Group naming templates

**`$groupNamingAppSuffix = $true`** (default):
- Required: `Win - SW - RQ - 7-Zip`
- Available: `Win - SW - AV - 7-Zip`

**`$groupNamingAppSuffix = $false`**:
- Required: `Win - SW - 7-Zip - RQ`
- Available: `Win - SW - 7-Zip - AV`

### App defaults

- **App version**: `WinGet`
- **Install behavior**: System (or User when `InstallContext=user`)
- **Device restart**: Based on return codes (0 = success; 1 = failed)
- **Allow available uninstall**: Yes
- **Max install time**: 60 min
- **Minimum Windows**: 21H1

### Skipping vs overwriting existing apps

- **Default:** Apps already in Intune (by `displayName`) are skipped with a log entry.
- **`-OverwriteExisting`:** Re-uploads content, updates all metadata (display name, description, icon, install/uninstall commands, detection rule, etc.), and skips group creation/assignment. Assignments stay as-is.

---

## 🖼️ Icons

Icons are stored in the `icons/` folder as **PNG** files.

### Matching rules

1. **Exact match**: `7-Zip.png` for app folder `7-Zip`
2. **Prefix match**: `Microsoft Visual C++.png` matches all apps starting with `Microsoft Visual C++`
3. **Longest wins**: `Microsoft Visual C++ 2005.png` overrides `Microsoft Visual C++.png` for 2005 apps

### Examples

| Icon file | Matches |
|-----------|---------|
| `7-Zip.png` | `7-Zip` |
| `Microsoft Visual C++.png` | All Microsoft Visual C++ apps |
| `Microsoft Visual C++ 2005.png` | `Microsoft Visual C++ 2005 Redistributable (x86)`, etc. |
| `Jabra Direct.png` | `Jabra Direct` |

Place icons in `icons/` before running `deploy.ps1`. If no icon is found, the app is deployed without one and a log entry is written.

---

## 📁 Folder Structure

```
Intune-Winget-main/
├── apps/                    # Output from package.ps1
│   ├── 7-Zip/
│   │   ├── 7-Zip.intunewin
│   │   ├── info.json
│   │   ├── detection.ps1
│   │   └── scripts/
│   │       ├── install.ps1
│   │       └── uninstall.ps1
│   ├── temp/                # Packaging temp (ignored by deploy)
│   └── ...
├── icons/                   # PNG icons for deploy.ps1
│   ├── 7-Zip.png
│   ├── Microsoft Visual C++.png
│   └── ...
├── jsons/
│   └── language.json        # Winget localization mappings
├── logs/                    # Script logs
│   ├── package.log
│   └── deploy.log
├── templates/
│   ├── install.ps1
│   ├── uninstall.ps1
│   └── detection.ps1
├── apps.csv                 # App list (ApplicationName, WingetAppId)
├── IntuneWinAppUtil.exe     # Microsoft packaging tool
├── package.ps1
├── deploy.ps1
└── README.md
```

---

## ⚙️ Configuration Reference

### package.ps1

| Variable | Type | Description |
|----------|------|-------------|
| `$keepPlainScripts` | bool | Keep install/uninstall in `scripts/` |
| `$quiet` | bool | IntuneWinAppUtil quiet mode |
| `$fetchWingetShow` | bool | Fetch winget metadata |
| `$forceRepack` | bool | Rebuild all (ignore existing .intunewin) |
| `$logDebug` | bool | Verbose debug logging |

### deploy.ps1

| Parameter/Variable | Type | Description |
|--------------------|------|-------------|
| `-OverwriteExisting` | switch | Re-upload and refresh existing apps; keep assignments |
| `$enableGroupCreation` | bool | Create groups and assign |
| `$groupNamingAppSuffix` | bool | App name at end vs before RQ/AV |
| `$groupCreationBlacklist` | string[] | Wildcard patterns to skip |
| `$graphScopes` | string[] | Graph API scopes |
| `$logDebug` | bool | Debug logs + request body dump |

---

## 🔧 Troubleshooting

| Issue | Solution |
|-------|----------|
| **“winget not found”** | Install [App Installer](https://aka.ms/getwinget) |
| **“IntuneWinAppUtil not found”** | Download from [Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) (Releases → extract zip → place `IntuneWinAppUtil.exe` in project root) |
| **“Graph modules not found”** | `Install-Module Microsoft.Graph, Microsoft.Graph.Beta -Scope CurrentUser` |
| **“Scope missing”** | Script will prompt to re-authenticate with required scopes |
| **“Commit failed: commitFileFailed”** | Check encryption info; ensure `Detection.xml` has correct casing |
| **Localized winget output** | Add locale to `jsons/language.json` if missing |
| **No icon found** | Add PNG to `icons/` matching app name or prefix |

### Debug mode

Set `$logDebug = $true` in `deploy.ps1` to:
- See detailed Graph requests
- Write `logs/deploy-request-body.json` for inspection

---
