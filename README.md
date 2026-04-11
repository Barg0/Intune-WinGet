# 📦 Intune-WinGet

> Automatically deploy Win32 apps to Microsoft Intune using WinGet -- define your apps in a CSV, run two scripts, done.

---

## 💡 What This Project Does

Microsoft Intune doesn't integrate with WinGet out of the box. This project connects them. You list your apps in a simple CSV, and two PowerShell scripts take care of the entire pipeline:

1. 📦 **`package.ps1`** — reads your app list, fetches metadata from WinGet, generates install/uninstall/detection scripts, and packages everything into `.intunewin` files.
2. 🚀 **`deploy.ps1`** — uploads each package to Intune via the Microsoft Graph API, sets detection rules, creates Entra ID groups, and assigns the app — all automatically.

You define your apps once in `apps.csv`. The scripts handle the rest.

---

## 📋 Table of Contents

- [🔄 How It Works](#-how-it-works)
- [🏁 What You End Up With in Intune](#-what-you-end-up-with-in-intune)
- [✅ Prerequisites](#-prerequisites)
- [🚀 Quick Start](#-quick-start)
- [🎯 Walkthrough: Deploy Your First App](#-walkthrough-deploy-your-first-app)
- [✏️ Configuring apps.csv](#-configuring-appscsv)
- [📦 Running package.ps1](#-running-packageps1)
- [🖼️ Adding Icons](#-adding-icons)
- [🚀 Running deploy.ps1](#-running-deployps1)
- [💻 What Happens on the Device](#-what-happens-on-the-device)
- [📁 Folder Structure](#-folder-structure)
- [🔧 Troubleshooting](#-troubleshooting)
- [📚 References](#-references)

---

## 🔄 How It Works

```
 apps.csv                package.ps1               apps/<AppName>/
 (WingetAppId rows) ─>  (builds packages)   ───>   .intunewin + scripts + info.json
                                                           │
                                                           ▼
                                                     deploy.ps1
                                                   (uploads via Graph API)
                                                           │
                                                           ▼
                                                    Microsoft Intune
                                                  Win32 App + Entra Groups
```

**package.ps1** reads each row from `apps.csv` (WinGet package id and install options), runs `winget show` to fetch metadata (display **name**, description, publisher, URLs, architectures, and **package dependencies**), generates three PowerShell scripts from templates (`install.ps1`, `uninstall.ps1`, `detection.ps1`), and wraps them into `.intunewin` packages using Microsoft's `IntuneWinAppUtil.exe`. WinGet **package** dependencies are packaged automatically under each app's `dependencies/` folder (one level only).

**deploy.ps1** reads `apps.csv`, locates each packaged app folder by matching `WingetAppId` in `info.json`, connects to Microsoft Graph (beta), uploads dependency apps first (when present), sets **Intune app dependencies** on the main Win32 app via Graph **`updateRelationships`** (with existing supersedence rules preserved when Graph returns them), then creates or overwrites the main Win32 app, uploads content in 6 MB chunks (with **retries** for transient DNS issues and for **412** responses while Intune finishes a prior revision), sets detection, optionally uploads an icon, and creates two Entra ID security groups (Required and Available) for the **main** app only.

---

## 🏁 What You End Up With in Intune

After running both scripts, each app appears in the [Intune Admin Center](https://intune.microsoft.com) under **Apps > Windows** as a Win32 app:

- 📋 **Name, description, publisher, URLs** — pulled from WinGet metadata automatically.
- ⚙️ **Install/uninstall commands** — PowerShell scripts that invoke `winget install` / `winget uninstall` with retry logic, scope fallbacks, and detailed logging.
- 🔍 **Detection rule** — custom PowerShell script that runs `winget list` to check if the app is installed.
- 🖼️ **Icon** — shows in Company Portal and the Intune Admin Center (if you placed a PNG in `icons/`).
- 👥 **Two Entra ID groups** — created per app:
  - `Win - SW - RQ - <AppName>` -- Required assignment (silent install, notifications hidden)
  - `Win - SW - AV - <AppName>` -- Available assignment (appears in Company Portal for self-service)

To deploy an app to devices, add users or devices to the Required group. To make it available for self-service, add them to the Available group.

---

## ✅ Prerequisites

### 💻 Software

| Requirement | Why | How to get it |
|-------------|-----|---------------|
| **Windows 10 or 11** | WinGet and IntuneWinAppUtil.exe only run on Windows | -- |
| **WinGet** (Windows Package Manager) | Used to fetch metadata and install apps on devices | Pre-installed on Win 11. Win 10: [Install App Installer](https://aka.ms/getwinget) |
| **IntuneWinAppUtil.exe** | Microsoft's Win32 Content Prep Tool -- packages scripts into `.intunewin` | **Optional manual step:** [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) -- if the `.exe` is missing from the repo root, **`package.ps1` downloads it automatically** from the `master` branch on GitHub (same binary as the repo). |
| **Microsoft Graph PowerShell modules** | Used by `deploy.ps1` to talk to the Intune API | **Optional manual step:** if the modules are missing, **`deploy.ps1` runs `Install-Module`** for `Microsoft.Graph` and `Microsoft.Graph.Beta` (`Scope CurrentUser`, PSGallery) on first connect. You can still pre-install manually (below). |

### 📦 Install the Graph modules (optional manual install)

If you prefer not to let the script install modules, or PSGallery is blocked by policy, install once:

```powershell
Install-Module -Name Microsoft.Graph, Microsoft.Graph.Beta -Scope CurrentUser
```

If you get a permission error, run PowerShell as Administrator (or fix execution policy / repository trust for your environment).

### 🏢 Intune and Entra requirements

| Requirement | Details |
|-------------|---------|
| **Microsoft Intune license** | Your tenant needs an active Intune license. Check in [Microsoft 365 admin center](https://admin.microsoft.com) |
| **Admin role** | You need at least **Intune Administrator** to create apps and **Groups Administrator** to create Entra groups. Global Administrator works too. |
| **Graph API permissions** | When `deploy.ps1` runs, it requests two scopes: `DeviceManagementApps.ReadWrite.All` and `Group.ReadWrite.All`. You will be prompted to consent on first run. If your tenant requires admin consent for Graph apps, a Global Administrator must approve it first. |

### ⚠️ Make WinGet work in SYSTEM context (recommended)

When Intune runs Win32 apps as SYSTEM, WinGet can fail because the required UWP dependencies (`Microsoft.VCLibs`, `Microsoft.UI.Xaml`) are not available to the SYSTEM account. **It is recommended to deploy this script via Intune before deploying WinGet-based apps:**

[**Winget-SystemContext**](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) -- Deploy this as an Intune Platform Script. It registers the UWP dependency paths so WinGet can run correctly as SYSTEM. Without it, install scripts may fail on devices where these dependencies have never been made available to the SYSTEM account.

---

## 🚀 Quick Start

```powershell
# 1️⃣ (Optional) Place IntuneWinAppUtil.exe in the project root — otherwise package.ps1 downloads it from GitHub when missing

# 2️⃣ (Optional) Install Graph modules — otherwise deploy.ps1 installs them from PSGallery when missing

# 3️⃣ Edit apps.csv — add your apps (one per row)
# WingetAppId,InstallContext,InstallOverride
# 7zip.7zip,system,
# Notepad++.Notepad++,system,

# 4️⃣ Build packages
.\package.ps1

# 5️⃣ (Optional) Place PNG icons in icons/ folder, named to match app names

# 6️⃣ Deploy to Intune — sign in when the browser opens
.\deploy.ps1
```

✅ After `deploy.ps1` finishes, check [Intune Admin Center](https://intune.microsoft.com) > **Apps** > **Windows**. Your apps are there with detection rules, groups, and assignments.

---

## 🎯 Walkthrough: Deploy Your First App

This walkthrough deploys **7-Zip** from start to finish. Follow these exact steps on a Windows machine.

### 1️⃣ Step 1: Set up the project folder

Download or clone this repository. Your folder should look like this:

```
Intune-WinGet/
├── apps.csv
├── package.ps1
├── deploy.ps1
├── IntuneWinAppUtil.exe    <-- optional: package.ps1 downloads from GitHub if missing
├── icons/
├── templates/
│   ├── install.ps1
│   ├── uninstall.ps1
│   └── detection.ps1
└── jsons/
    └── language.json
```

If you prefer a fixed version, 📥 [download IntuneWinAppUtil.exe](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) and place it in the root folder; otherwise the first `package.ps1` run will fetch it from the repository’s `master` branch.

### 2️⃣ Step 2: Add 7-Zip to apps.csv

Open `apps.csv` in a text editor. Make sure it contains at least:

```csv
WingetAppId,InstallContext,InstallOverride
7zip.7zip,system,
```

How did we know the WinGet App ID? Open PowerShell and run:

```powershell
winget search "7-Zip"
```

Output:

```
Name              Id                  Version  Match              Source
------------------------------------------------------------------------
7-Zip             7zip.7zip           24.09    ProductCode: 7-zip winget
```

The **Id** column (`7zip.7zip`) is the `WingetAppId` in `apps.csv`. The display name for folders and Intune comes from `winget show` (and is stored in `info.json` as `Name`).

### 3️⃣ Step 3: Run package.ps1

```powershell
.\package.ps1
```

You will see terse, tag-based output (examples below). If `IntuneWinAppUtil.exe` was missing, you will see a **`[ Run ] IntuneWinAppUtil: download`** line and **`[ Success ] IntuneWinAppUtil: saved`** before packaging.

```
2026-04-11 14:30:01 [  Start   ] ==================== Start ====================
2026-04-11 14:30:01 [  Info    ] Apps: 1
2026-04-11 14:30:01 [  Info    ] 7-Zip (7zip.7zip)
2026-04-11 14:30:02 [  Get     ] winget show: 7zip.7zip
2026-04-11 14:30:04 [  Run     ] IntuneWinAppUtil: 7-Zip
2026-04-11 14:30:06 [  Success ] Packaged: 7-Zip
2026-04-11 14:30:06 [  Info    ] Runtime 00:00:05.12
2026-04-11 14:30:06 [  Info    ] Exit 0
2026-04-11 14:30:06 [  End     ] ==================== End ====================
```

Check the `apps/7-Zip/` folder. You should see: 👀

```
apps/7-Zip/
├── 7-Zip.intunewin       # The package Intune needs
├── info.json              # Metadata from WinGet (name, publisher, description, URLs)
├── detection.ps1          # Detection script (also used by deploy.ps1)
└── scripts/
    ├── install.ps1        # Install script (baked into .intunewin)
    └── uninstall.ps1      # Uninstall script (baked into .intunewin)
```

### 4️⃣ Step 4: (Optional) Add an icon

If you have a `7-Zip.png` icon, place it in the `icons/` folder. It will show up in Company Portal and the Intune Admin Center.

### 5️⃣ Step 5: Run deploy.ps1

```powershell
.\deploy.ps1
```

**What happens next:**

1. 🌐 A browser window opens for Microsoft Graph sign-in. Sign in with an account that has Intune Administrator permissions.
2. ✅ If this is the first time, you will see a **permissions consent** screen asking you to approve `DeviceManagementApps.ReadWrite.All` and `Group.ReadWrite.All`. Click **Accept**.
3. 📦 The script creates the Win32 app, uploads the package, sets the detection rule, creates groups, and assigns them.

**Expected output (shape):** 📊 On first run you may see **`[ Run ] Graph: Install-Module`** if Graph modules were missing, then **`[ Success ] Graph: modules ok`**. Logs use short `Label: value` lines.

```
2026-04-11 14:35:01 [  Start   ] ==================== Start ====================
2026-04-11 14:35:01 [  Run     ] Graph: connecting
2026-04-11 14:35:05 [  Success ] Graph: admin@contoso.com
2026-04-11 14:35:05 [  Info    ] 7-Zip
2026-04-11 14:35:06 [  Get     ] Icon: 7-Zip.png
2026-04-11 14:35:06 [  Run     ] Creating: 7-Zip
2026-04-11 14:35:07 [  Info    ] App id: 1a2b3c4d-...
2026-04-11 14:35:07 [  Get     ] Storage URI: waiting
2026-04-11 14:35:12 [  Run     ] Uploading: 7-Zip
2026-04-11 14:35:18 [  Get     ] Commit: waiting
2026-04-11 14:35:50 [  Run     ] Group: Win - SW - RQ - 7-Zip
2026-04-11 14:35:51 [  Run     ] Group: Win - SW - AV - 7-Zip
2026-04-11 14:35:52 [  Success ] Groups assigned
2026-04-11 14:35:52 [  Success ] Deployed: 7-Zip
2026-04-11 14:35:52 [  Info    ] Summary: 1 ok | 0 skipped | 0 failed
2026-04-11 14:35:52 [  Info    ] Runtime 00:00:51.00
2026-04-11 14:35:52 [  Info    ] Exit 0
2026-04-11 14:35:52 [  End     ] ==================== End ====================
```

### 6️⃣ Step 6: Verify in Intune

Open [Intune Admin Center](https://intune.microsoft.com) > **Apps** > **Windows**. You should see "7-Zip" as a Win32 app. Click on it to see:

- 📋 **Properties** — name, description, publisher filled from WinGet
- ⚙️ **Program** — install/uninstall commands pointing to the PowerShell scripts
- 🔍 **Detection rules** — custom script using `detection.ps1`
- 👥 **Assignments** — Required group `Win - SW - RQ - 7-Zip` and Available group `Win - SW - AV - 7-Zip`

To install 7-Zip on devices, add them (or their users) to the `Win - SW - RQ - 7-Zip` group in Entra ID.

---

## ✏️ Configuring apps.csv

Each row in `apps.csv` is one app. The file uses comma-separated values.

### 📋 Columns

| Column | Required | Description | Example |
|--------|----------|-------------|---------|
| **WingetAppId** | Yes | The exact WinGet package identifier. Must match what `winget search` returns in the **Id** column. The app's display name for Intune, folders, and groups is resolved from `winget show` and saved in `info.json`. | `7zip.7zip` |
| **InstallContext** | No | `system` (default) or `user`. Controls how the script runs on the device. | `system` |
| **InstallOverride** | No | Extra arguments passed to the installer via `winget install --override`. Leave empty for default silent install. | `/silent` |

### 🔎 Finding a WinGet App ID

```powershell
winget search "Google Chrome"
```

```
Name           Id             Version  Source
----------------------------------------------
Google Chrome  Google.Chrome  133.0... winget
```

Use the **Id** column value (`Google.Chrome`) as `WingetAppId`. The catalog **Name** is only a hint; the scripts use the name from `winget show` for Intune and disk folders.

💡 **Tips:**
- 🔎 Use `winget search` with part of the app name. If too many results, be more specific.
- ✅ Use `winget show <id>` to verify the correct package before adding it to the CSV.
- 📝 The ID is case-sensitive. Copy it exactly as shown.

### ⚖️ System vs. user context

| Context | When to use | What happens on the device |
|---------|-------------|---------------------------|
| **system** | Most apps. Machine-wide installs that all users on the device can use. | Intune runs the script as SYSTEM. WinGet path is resolved from `%ProgramW6432%\WindowsApps`. Install command uses `%WINDIR%\sysnative\...powershell.exe`. WinGet is called with `--scope machine`. |
| **user** | Per-user apps that install into the user profile and do not support machine-wide install. | Intune runs the script as the logged-in user. WinGet is called from PATH with `--scope user`. |

**If you are unsure, use `system`.** Most apps work in system context. The install script will automatically retry without `--scope` if the first attempt fails due to scope, so even apps that don't support `--scope machine` will still install.

### 🔧 InstallOverride

Use the `InstallOverride` column to pass custom arguments to the installer. WinGet forwards them via `--override`. Example for Citrix Workspace:

```csv
Citrix.Workspace.LTSR,system,/silent STORE0="AppStore;https://server.net/Citrix/Store/discovery;on;My Store"
```

### 📋 Example apps.csv

Here is a representative example showing common app types:

```csv
WingetAppId,InstallContext,InstallOverride
7zip.7zip,system,
Google.Chrome,system,
Notepad++.Notepad++,system,
Microsoft.VCRedist.2015+.x64,system,
Microsoft.DotNet.DesktopRuntime.8,system,
Jabra.Direct,system,
DominikReichl.KeePass,system,
Microsoft.VisualStudio.2022.Professional,system,
Proton.ProtonAuthenticator,user,
Citrix.Workspace.LTSR,system,/silent STORE0="AppStore;https://testserver.net/Citrix/MyStore/discovery;on;HR App Store"
```

💡 **Notice:** Most apps use `system` with no override. The Proton Authenticator uses `user` because it installs per-user. The Citrix Workspace uses an override to configure the store connection during install.

---

## 📦 Running package.ps1

```powershell
.\package.ps1
```

### 📝 What it does, step by step

1. ✔️ Ensures `IntuneWinAppUtil.exe` exists (downloads from [Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) `master` if missing), then validates `apps.csv` and the template scripts exist.
2. 📖 Reads each row from `apps.csv`.
3. 📦 For each app:
   - 🔍 Runs `winget show --id <WingetAppId>` to resolve the display name and metadata (description, publisher, architectures, URLs, dependencies).
   - 📁 Creates `apps/<Name from WinGet>/` (safe folder name derived from that display name).
   - 💾 Saves the metadata to `apps/<...>/info.json` (used by `deploy.ps1` for the Intune app properties). WinGet package dependencies are listed under `Dependencies` in `info.json` when present.
   - 📜 Generates `install.ps1`, `uninstall.ps1`, and `detection.ps1` from the templates in `templates/`, replacing placeholders with the WinGet id and install options from the CSV.
   - 📦 Packages `install.ps1` + `uninstall.ps1` into a `.intunewin` file using `IntuneWinAppUtil.exe`.
   - 📎 If `info.json` lists WinGet package dependencies, builds matching packages under `apps/<Main>/dependencies/<Dependency>/` (same layout as a top-level app; optional `InstallContext` / `InstallOverride` are taken from `apps.csv` when the same `WingetAppId` appears there).
4. ⏭️ Skips apps that already have a `.intunewin` file (unless `$forceRepack = $true`). The same skip logic applies to each dependency folder.

### 📂 What gets created per app

```
apps/7-Zip/
├── 7-Zip.intunewin       # Encrypted package for Intune upload
├── info.json              # WinGet metadata (deploy.ps1 reads this)
├── detection.ps1          # Detection script (deploy.ps1 uploads this separately)
├── scripts/
│   ├── install.ps1        # Human-readable copy of the install script
│   └── uninstall.ps1      # Human-readable copy of the uninstall script
└── dependencies/          # Present only when WinGet reports package dependencies
    └── <Dependency name>/
        ├── <Dependency name>.intunewin
        ├── info.json
        ├── detection.ps1
        └── scripts/
            ├── install.ps1
            └── uninstall.ps1
```

The `scripts/` subfolder contains plain-text copies of the scripts so you can read and test them. The actual scripts used by Intune are inside the `.intunewin` file.

### ⚙️ Configuration variables (top of package.ps1)

| Variable | Default | Description |
|----------|---------|-------------|
| `$keepPlainScripts` | `$true` | Keep readable copies of install/uninstall in `scripts/` subfolder. Set to `$false` to remove them after packaging. |
| `$quiet` | `$true` | Run `IntuneWinAppUtil.exe` in quiet mode (no interactive prompts). |
| `$fetchWingetShow` | `$true` | Fetch metadata from WinGet and save `info.json`. Set to `$false` to skip (uses existing `info.json` if present). |
| `$forceRepack` | `$false` | If `$true`, clears each app folder and rebuilds from scratch. If `$false`, skips apps that already have a `.intunewin` file. |
| `$logDebug` | `$false` | Enable verbose debug logging. |
| `$intuneWinAppUtilDownloadUrl` | (in `package.ps1`) | Default points at GitHub `raw` for [Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) `master/IntuneWinAppUtil.exe`; change there if you need another source. |

### 🔄 Re-packaging apps

If you changed a template or updated an app's override in `apps.csv` and need to rebuild:

```powershell
# Option 1: Force rebuild of all apps
# Edit package.ps1 and set $forceRepack = $true, then run:
.\package.ps1

# Option 2: Delete a single app's folder to rebuild just that one
Remove-Item -Recurse -Force apps\7-Zip
.\package.ps1
```

---

## 🖼️ Adding Icons

Place **PNG** files in the `icons/` folder before running `deploy.ps1`. Icons appear in Company Portal and the Intune Admin Center.

### 📐 Naming rules

| Rule | File name | Which apps it matches |
|------|-----------|-----------------------|
| **Exact match** | `7-Zip.png` | Only the app named "7-Zip" |
| **Prefix match** | `Microsoft Visual C++.png` | All apps whose name starts with "Microsoft Visual C++" |
| **Longest prefix wins** | `Microsoft Visual C++ 2005.png` | Overrides the shorter prefix for the 2005-specific apps |

If no icon is found for an app, the app deploys without one (Intune uses a generic icon).

---

## 🚀 Running deploy.ps1

```powershell
.\deploy.ps1
```

### 📝 What it does, step by step

1. ✔️ **Checks prerequisites** — verifies `apps/` folder and `apps.csv` exist; **installs `Microsoft.Graph` and `Microsoft.Graph.Beta` from PSGallery** (`CurrentUser`) if they are not already available, then connects.
2. 🌐 **Connects to Microsoft Graph** — opens a browser for interactive sign-in. If already connected with the right scopes, it reuses the session.
3. 📦 **For each row in apps.csv** (by `WingetAppId`):
   - 📁 Finds the packaged folder whose `info.json` contains that `WingetAppId`.
   - 📎 If `$deployDependencies` is `$true` and a `dependencies/` subfolder exists, uploads each dependency Win32 app first (no Entra groups for dependencies). Skips a dependency if Intune already has an app with the same display name.
   - 📋 Reads `info.json` for metadata.
   - 🔍 Checks if the main app already exists in Intune (by display name). Skips upload if it does (unless overwrite mode).
   - ➕ Creates the Win32 app via Graph API.
   - ☁️ Uploads the `.intunewin` content to Azure Storage in 6 MB chunks (SAS URI renewal every 7 minutes for large packages). **Blob PUTs are retried** on transient errors (e.g. DNS / “unknown host”).
   - ✔️ Commits the upload with encryption info extracted from the `.intunewin` metadata. **Creating a new content version is retried** when Intune returns **412 / ConditionNotMet** (common right after metadata changes or overwrite while a prior revision is still publishing).
   - 🔍 Sets the custom detection script (`detection.ps1`).
   - 🖼️ Uploads the icon if one exists in `icons/`.
   - 🔗 When dependencies were deployed, calls Graph **`POST .../mobileApps/{id}/updateRelationships`** with a `relationships` array of **`mobileAppDependency`** entries (`autoInstall`). Existing **`mobileAppSupersedence`** rows returned by Graph for that app are merged into the same payload so portal-configured supersedence is not cleared when possible.
   - 👥 Creates two Entra ID security groups and assigns them to the **main** app (dependencies never get their own assignment groups).
4. 📊 **Prints a summary** line such as `Summary: N ok | S skipped | F failed` (counts from the CSV run).

### 🌐 Graph sign-in

A browser opens for Microsoft Graph sign-in — sign in and accept the requested permissions if prompted.

### ⚙️ Configuration variables (top of deploy.ps1)

| Variable | Default | Description |
|----------|---------|-------------|
| `$enableGroupCreation` | `$true` | Create Entra ID groups and assign them to the app. Set to `$false` if you manage groups manually. |
| `$deployDependencies` | `$true` | When `$true`, deploys packaged WinGet dependencies under each app's `dependencies/` folder before the main app, sets Intune **Dependencies** on the main Win32 app, then creates groups for the main app only. Set to `$false` to ignore `dependencies/` entirely. |
| `$groupNamingAppSuffix` | `$true` | Group naming style. `$true` = `Win - SW - RQ - 7-Zip`. `$false` = `Win - SW - 7-Zip - RQ`. |
| `$groupCreationBlacklist` | see script | Wildcard patterns for apps to skip group creation (e.g. `'Microsoft Visual C++*'`). Dependency packages never receive groups regardless of this list. |
| `$graphScopes` | see script | Graph API permissions requested during sign-in. |
| `$logDebug` | `$false` | Enable verbose logging. Dumps the full Graph API request body to `logs/deploy-request-body.json`. |
| `$contentVersionPostAttempts` / `$contentVersionPostDelaySec` | `10` / `15` | Retries for `POST .../contentVersions` when Intune returns **412** / **ConditionNotMet**. |
| `$blobHttpRetryMax` / `$blobHttpRetryDelaySec` | `6` / `5` | Retries per Azure blob block (and block list) **PUT** on upload failures (e.g. DNS). |
| `$sleepAfterCommitSec` | `30` | Pause after committing content before follow-up Graph calls. |

### 🏷️ Group naming

| `$groupNamingAppSuffix` | Required group | Available group |
|-------------------------|----------------|-----------------|
| `$true` (default) | `Win - SW - RQ - 7-Zip` | `Win - SW - AV - 7-Zip` |
| `$false` | `Win - SW - 7-Zip - RQ` | `Win - SW - 7-Zip - AV` |

### 🚫 Group creation blacklist

Some apps (like Visual C++ redistributables or .NET runtimes) are typically deployed as dependencies, not as standalone apps. You probably don't want individual groups for each of them. The `$groupCreationBlacklist` variable skips group creation for matching app names:

```powershell
$groupCreationBlacklist = @(
    'Microsoft Visual C++*',
    'Microsoft ODBC Driver*',
    'Microsoft .NET Runtime*',
    'Microsoft .NET Windows Desktop Runtime*',
    'Microsoft ASP.NET Core Hosting Bundle',
    'Microsoft ASP.NET Core Runtime',
    '7-Zip'
)
```

Uses wildcard matching with `*`.

### 📝 Overwriting existing apps

By default, apps that already exist in Intune (matched by display name) are skipped. To update them:

```powershell
.\deploy.ps1 -OverwriteExisting
```

**What gets updated:**

| Component | Updated? |
|-----------|----------|
| App content (new `.intunewin`) | Yes |
| Display name, description, publisher | Yes |
| Install/uninstall commands | Yes |
| Install context (system/user) | Yes |
| Detection rule | Yes |
| Architectures | Yes |
| Icon (only if a local icon file exists) | Yes |
| **Group assignments** | **No -- preserved** |
| **Group creation** | **Skipped** |

If no local icon exists in `icons/`, the existing icon in Intune is preserved.

### 📋 App settings applied by deploy.ps1

These are the settings configured for each Win32 app in Intune:

| Setting | Value |
|---------|-------|
| Display version | `WinGet` |
| Install command (system) | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\install.ps1` |
| Install command (user) | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden .\install.ps1` |
| Uninstall command (system) | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1` |
| Uninstall command (user) | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden .\uninstall.ps1` |
| Install behavior | System or User (matches `InstallContext` from CSV) |
| Restart behavior | Based on return codes |
| Return codes | `0` = Success, `1` = Failed |
| Max install time | 60 minutes |
| Minimum Windows version | 21H1 |
| Allow available uninstall | Yes |
| Required assignment notifications | Hidden (silent install) |
| Detection | Custom PowerShell script (`detection.ps1`) |

> **User context:** Uses `-NoProfile -NonInteractive -WindowStyle Hidden` to reduce visible console window.

---

## 💻 What Happens on the Device

When Intune deploys the app to a device, here is the sequence of events. 📱

### Install flow

1. 📥 Intune downloads the `.intunewin` package to the device.
2. 📦 Intune extracts it and runs the install command (e.g. `powershell.exe ... .\install.ps1`).
3. 🔧 The install script resolves the WinGet executable path (in system context, from `%ProgramW6432%\WindowsApps`).
4. ✔️ It checks `winget --version` to make sure WinGet is working. If it's not, the script exits 0 so Intune can retry after a reboot.
5. 📥 It runs `winget install -e --id <AppId> --silent --scope machine` (or `user`).
6. 🔄 If that fails due to scope, it retries without `--scope`.
7. ⏳ If another installation is in progress, it waits 2 minutes and retries (up to 15 times).
8. ⚠️ If the failure is transient (disk full, reboot needed), it exits 0 so Intune retries later.
9. ✅ On success, it exits 0.

### Detection flow

1. 🔍 Intune runs `detection.ps1` to check if the app is installed.
2. The script runs `winget list -e --id <AppId>`.
3. Exit 0 = app is installed. Exit 1 = app is not installed.

### Uninstall flow

1. 🗑️ Intune runs the uninstall command.
2. The script runs `winget uninstall -e --id <AppId> --silent --scope machine`.
3. If "no packages found" (package was installed without scope), retries without `--scope`.
4. Exit 0 on success.

### 📄 Where to find logs on devices

> [!TIP]
> The **log files** for install, uninstall, and detection scripts are saved at:
> `C:\ProgramData\IntuneLogs\Applications\<ApplicationName>\`
>
> ```
> C:
> ├─📁 ProgramData
> │  └─📁 IntuneLogs
> │     └─📁 Applications
> │        └─📁 7-Zip
> │           ├─📄 install.log
> │           ├─📄 uninstall.log
> │           └─📄 detection.log
> ```
> To enable log collection from this custom directory using the **Collect diagnostics** feature in Intune, deploy the following platform script:
>
> [Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory)

### 🧪 How to test scripts locally

You can test the scripts on a VM or test machine before deploying through Intune.

**Testing in SYSTEM context (simulates Intune):** 🖥️

Download [PsExec](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec) from Sysinternals, then:

```cmd
psexec -i -s powershell.exe
```

This opens a PowerShell window running as SYSTEM. Navigate to the app's `scripts/` folder and run:

```powershell
cd "C:\Intune-WinGet\apps\7-Zip\scripts"
.\install.ps1       # Test install
.\detection.ps1     # Verify detection
.\uninstall.ps1     # Test uninstall
```

**Testing in user context:** 👤

Simply open a normal PowerShell window and run the scripts directly. No `psexec` needed.

After testing, check the logs at `%ProgramData%\IntuneLogs\Applications\<AppName>\` to verify everything worked.

For detailed information about the script internals, retry logic, exit code handling, and override escaping, see [`templates/README.md`](templates/README.md).

---

## 📁 Folder Structure

```
Intune-WinGet/
│
├── apps.csv                     # Your app list -- edit this
├── package.ps1                  # Step 1: Build .intunewin packages
├── deploy.ps1                   # Step 2: Upload to Intune via Graph API
├── IntuneWinAppUtil.exe         # Auto-downloaded by package.ps1 if missing (or place manually)
├── README.md                    # This file
│
├── apps/                        # Output from package.ps1
│   ├── 7-Zip/
│   │   ├── 7-Zip.intunewin     # Encrypted package for Intune
│   │   ├── info.json            # WinGet metadata (includes WingetId, optional Dependencies)
│   │   ├── detection.ps1        # Detection script
│   │   ├── scripts/
│   │   │   ├── install.ps1      # Readable install script copy
│   │   │   └── uninstall.ps1  # Readable uninstall script copy
│   │   └── dependencies/        # Optional: WinGet package dependencies
│   │       └── …/
│   ├── Notepad++/
│   │   └── ...
│   └── temp/                    # Temporary packaging files (auto-cleaned)
│
├── icons/                       # Optional PNG icons for Company Portal
│   ├── 7-Zip.png
│   ├── Microsoft Visual C++.png
│   └── ...
│
├── jsons/
│   └── language.json            # WinGet output localization mappings
│
├── logs/                        # Script logs
│   ├── package.log
│   └── deploy.log
│
└── templates/                   # Script templates (see templates/README.md)
    ├── install.ps1
    ├── uninstall.ps1
    ├── detection.ps1
    └── README.md
```

---

## 🔧 Troubleshooting

### 🔌 Setup issues

| Issue | Solution |
|-------|----------|
| `winget` not recognized | Install [App Installer](https://aka.ms/getwinget) from the Microsoft Store. |
| `IntuneWinAppUtil.exe` not found / download failed | Check internet access and TLS; confirm `$intuneWinAppUtilDownloadUrl` in `package.ps1`. Or [download manually](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) and place the `.exe` in the project root. |
| Graph modules not installed / `Install-Module` failed | Run manually: `Install-Module -Name Microsoft.Graph, Microsoft.Graph.Beta -Scope CurrentUser`. If PSGallery is blocked, use an internal repository or pre-provision modules on the packaging machine. |
| Graph sign-in fails / scope missing | The script will disconnect and re-prompt. If your tenant requires admin consent, a Global Administrator must approve the permissions in Entra ID first. |
| `Execution policy` error | Run: `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process` in your PowerShell session, or run scripts with `-ExecutionPolicy Bypass`. |

### 🚀 Deploy issues

| Issue | Solution |
|-------|----------|
| App skipped (already in Intune) | Use `.\deploy.ps1 -OverwriteExisting` to update it. |
| App "not packaged" | Run `.\package.ps1` first. The app is in the CSV but has no folder under `apps/`. |
| No icon found | Place a PNG in `icons/` matching the app name (exact or prefix). |
| Commit failed | Check `logs/deploy.log`. Enable `$logDebug = $true` for full request/response details. Common cause: malformed `Detection.xml` in the `.intunewin` (try force-repackaging). |
| Upload timeout | Large packages may take time. The script automatically renews the Azure SAS URI every 7 minutes. Blob uploads retry on transient failures. If it still fails, check your network connection. |
| `412` / `ConditionNotMet` on **contentVersions** | The script retries automatically. If it still fails, wait a few minutes and re-run deploy, or resolve a stuck publishing state for that app in Intune Admin Center. |
| “Unknown host” / DNS during **blob** upload | Retries run automatically on each block PUT. Fix DNS or proxy on the machine running `deploy.ps1` if errors persist. |

### 💻 On-device issues

| Issue | Solution |
|-------|----------|
| WinGet not working as SYSTEM | Deploy [Winget-SystemContext](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) via Intune first. It registers required UWP dependency paths. |
| Install fails, then works on retry | Normal. Some apps fail with `--scope machine` and succeed without it. The script handles this automatically. |
| Uninstall says "no packages found" | Expected when the install used a scope fallback. The uninstall script retries without `--scope` automatically. |
| Install exits 0 but app not installed | This means a transient error occurred (RetryLater category). Intune will retry. Check `install.log` for the WinGet exit code. |
| WinGet version check fails | The script exits 0 so Intune retries after reboot. Deploy Winget-SystemContext to make UWP dependencies available to SYSTEM. |
| Want verbose logs | Set `$logDebug = $true` at the top of the template script, set `$forceRepack = $true` in `package.ps1`, re-package and redeploy. |

### 🌐 WinGet localization

If `package.ps1` runs on a non-English Windows (e.g. German, French), `winget show` output labels are in the local language. The script automatically normalizes them to English using `jsons/language.json`. If your locale is missing, add it to `language.json` following the existing pattern.

---

## 📚 References

- 📜 [`templates/README.md`](templates/README.md) — Detailed documentation for the install/uninstall/detection scripts
- 📖 [WinGet documentation](https://learn.microsoft.com/en-us/windows/package-manager/winget/) — Microsoft Learn
- 🔢 [WinGet return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md) — Exit code reference
- 📦 [Prepare Win32 app content](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-prepare) — Intune documentation
- 🔗 [Win32LobApp Graph API](https://learn.microsoft.com/en-us/graph/api/resources/intune-apps-win32lobapp) — API reference used by deploy.ps1
- 🔗 [mobileApp: updateRelationships](https://learn.microsoft.com/en-us/graph/api/intune-shared-mobileapp-updaterelationships?view=graph-rest-beta) — how Win32 app dependencies are applied on current Intune backends
- 🔧 [IntuneWinAppUtil.exe](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases) — Microsoft Win32 Content Prep Tool
- ⚙️ [Winget-SystemContext](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) — Make WinGet work in SYSTEM context
- 📄 [Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory) — Collect device logs remotely via Intune
