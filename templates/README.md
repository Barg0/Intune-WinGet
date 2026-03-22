# 🚀 Win32 – App Deployment (Winget + Intune)

This project provides three PowerShell scripts (`detection.ps1`, `install.ps1`, and `uninstall.ps1`) to deploy **Win32 apps using Winget** via **Microsoft Intune**.

All scripts share a common structure and require variables to be defined at the top. Values are injected from `apps.csv` by `package.ps1`.

---

## 📋 Required Variables

| Variable | Used in | Description |
|----------|---------|-------------|
| `$applicationName` | All | Display name of the app (e.g. for logs and Intune) |
| `$wingetAppId` | All | Winget package ID (e.g. `7zip.7zip`) |
| `$installContext` | All | `system` or `user` – controls winget invocation mode (see below) |

**Example:**

```powershell
$applicationName = "7-Zip"
$wingetAppId     = "7zip.7zip"
$installContext  = "system"
```

---

## 🔧 Optional Variables

| Variable | Used in | Description |
|----------|---------|-------------|
| `$installOverride` | install.ps1 | Set from `apps.csv` InstallOverride column when non-empty. String passed to `winget install --override`. Leave empty for none. |

**Example (Citrix-style override):**

```powershell
$installOverride = "/silent STORE0='AppStore;https://testserver.net/Citrix/MyStore/discovery;on;HR App Store'"
```

---

## 🔍 Finding a Winget App ID

Open PowerShell and run:

```powershell
winget search "AppName"
```

Example output:
```PowerShell
PS C:\> winget search "7-Zip"
Name              Id                  Version            Match              Source
----------------------------------------------------------------------------------
7-Zip             7zip.7zip           24.09              ProductCode: 7-zip winget
7-Zip ZS          mcmilk.7zip-zstd    24.09 ZS v1.5.7 R1 Tag: 7-zip         winget
7-Zip Alpha (exe) 7zip.7zip.Alpha.exe 24.01                                 winget
7-Zip Alpha (msi) 7zip.7zip.Alpha.msi 24.01.00.0                            winget
```

Copy the **Id** into `$wingetAppId` and the **Name** into `$applicationName`.

---

## 📦 Packaging the Win32 App

Use the official [Microsoft Win32 Content Prep Tool](https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool) to package your scripts.

📚 [Prepare Win32 app content](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-prepare) (Microsoft Docs)

### 📁 Folder Structure Example

```
.
├─📁 7-Zip
│  ├──📜 install.ps1
│  └──📜 uninstall.ps1
```

### 📝 Packaging Steps

Run `IntuneWinAppUtil.exe` from CMD:

```cmd
C:\Microsoft-Win32-Content-Prep-Tool>IntuneWinAppUtil.exe
Please specify the source folder: C:\Win32WingetDeployment\7-Zip
Please specify the setup file: install.ps1
Please specify the output folder: C:\Win32WingetDeployment
```

Rename the output to match your app:

```
install.intunewin → 7-Zip.intunewin
```

---

## 🛠️ Deploying in Intune

### 1️⃣ App Information

In [Intune Admin Center](https://intune.microsoft.com):

- **Apps** → **Windows** → **Create** → **Windows app (Win32)**
- Upload the `.intunewin` file.
- Use `winget show "<wingetAppId>"` to fill **Publisher**, **Description**, **Homepage**, etc.

> 💡 Search online for a logo to improve appearance in **Company Portal**.

---

### 2️⃣ Program Settings ⚙️

| Setting | Value |
|--------|--------|
| **Install command** 🟢 | **System context:** `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\install.ps1`<br>**User context:** `powershell.exe -ExecutionPolicy Bypass .\install.ps1` |
| **Uninstall command** 🔴 | **System context:** `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1`<br>**User context:** `powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1` |
| **Install behavior** | `System` or `User` (matches `$installContext`) |
| **Device restart behavior** | `Determine behavior based on return codes` → `0` = Success, `1` = Failed |

---

### 3️⃣ Requirements

Configure as needed for your app, for example:

- **OS architecture:** 32-bit and 64-bit  
- **Minimum OS:** Windows 10 20H2  

---

### 4️⃣ Detection Rules

- **Rules format:** `Use a custom detection script`
- **Script file:** `detection.ps1`

Then complete **Assignments** to target your groups.

---

## 📜 Script Behavior

### 🧩 Shared Behavior

- **Install context – system:** Winget path is resolved from `%ProgramW6432%\WindowsApps` (x64, then arm64). Uses `--scope machine`. Required when Intune runs scripts as SYSTEM.
- **Install context – user:** Calls `winget` directly (PATH / App Execution Alias). Uses `--scope user`. Use when deploying in user context (script runs as the logged-in user).
- **Winget version check:** Each script runs `winget --version`. If it fails, the script logs a friendly message, **exits with code 0** (so Intune does not mark the app as failed and can retry after reboot), and suggests restarting the PC or running a Winget repair script (e.g. [Winget - System Context](https://github.com/Barg0/Intune-Platform-Scripts/blob/main/Winget%20-%20System%20Context.ps1)).
- **No built-in Winget repair:** Repair (e.g. PATH for Winget dependencies) is handled by a separate platform script; these templates do not modify PATH or run repair.

---

### 📊 Logging

All scripts use the same logging function with **tags** and **switches**:

| Tag | Color (console) | Typical use |
|-----|------------------|-------------|
| Start / End | Cyan | Script start/end banners |
| Get | Blue | Resolving Winget path, reading data |
| Run | Magenta | Running winget install/list/uninstall |
| Info | Yellow | General info (version, exit code, duration) |
| Success | Green | Success messages |
| Error | Red | Errors |
| Debug | DarkYellow | Verbose troubleshooting (only when `$logDebug = $true`) |

**Switches (top of script):**

- `$log` – Master switch for logging.
- `$logDebug` – Enable **verbose Debug** output for troubleshooting.
- `$logGet` – Enable `[Get]` lines.
- `$logRun` – Enable `[Run]` lines.
- `$enableLogFile` – Write logs to file.

**Log location:** `%ProgramData%\IntuneLogs\Applications\<applicationName>\`  
Files: `detection.log`, `install.log`, `uninstall.log`.

---

### ✅ `detection.ps1`

- Resolves Winget path and checks Winget version.
- Sets **UTF-8** console encoding around `winget list` so Unicode app names are captured correctly.
- Runs `winget list -e --id $wingetAppId`.
- **Exit 0** if the package is listed (app detected); **Exit 1** if not found or on error.

**Example (not installed):**

```
2025-05-31 11:08:45 [  Start   ] ======== Detection Script Started ========
2025-05-31 11:08:45 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:08:45 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:08:45 [  Get     ] Resolved Winget path.
2025-05-31 11:08:45 [  Info    ] Winget version: v1.10.390
2025-05-31 11:08:45 [  Run     ] Checking installed packages for: 7zip.7zip
2025-05-31 11:08:46 [  Info    ] App NOT detected - 7-Zip is NOT installed.
2025-05-31 11:08:46 [  Info    ] Script execution time: 00:00:01.17
2025-05-31 11:08:46 [  Info    ] Exit Code: 1
2025-05-31 11:08:46 [  End     ] ======== Detection Script Completed ========
```

**Example (installed):**

```
2025-05-31 11:11:42 [  Start   ] ======== Detection Script Started ========
2025-05-31 11:11:42 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:11:42 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:11:42 [  Get     ] Resolved Winget path.
2025-05-31 11:11:42 [  Info    ] Winget version: v1.10.390
2025-05-31 11:11:42 [  Run     ] Checking installed packages for: 7zip.7zip
2025-05-31 11:11:43 [  Success ] App detected - 7-Zip IS installed.
2025-05-31 11:11:43 [  Info    ] Script execution time: 00:00:01.15
2025-05-31 11:11:43 [  Info    ] Exit Code: 0
2025-05-31 11:11:43 [  End     ] ======== Detection Script Completed ========
```

---

### 📥 `install.ps1`

- Resolves Winget path and checks Winget version (exits 0 if check fails, so Intune can retry).
- **First attempt:** `winget install -e --id $wingetAppId --silent --skip-dependencies --scope machine` (or `--scope user` for user context) with optional `--override $installOverride`.
- **Exit code handling:** Uses a WinGet exit-code map (Success, RetryScope, RetryLater, Fail). References: [FileWave – Troubleshooting WinGet](https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget), [Microsoft – winget return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md).
- **RetryScope:** If “no applicable installer for scope”, retries **without** `--scope` (some packages only support one scope).
- **RetryLater:** Transient errors (app in use, disk full, reboot required, etc.) → script **exits 0** so Intune can retry later.
- **Success:** Exit 0 on success or “already installed” / “higher version installed”.

**Example (success):**

```
2025-05-31 11:10:12 [  Start   ] ======== Install Script Started ========
2025-05-31 11:10:12 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:10:12 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:10:12 [  Get     ] Resolved Winget path.
2025-05-31 11:10:12 [  Info    ] Winget version: v1.10.390
2025-05-31 11:10:12 [  Run     ] Installing with scope machine.
2025-05-31 11:10:18 [  Info    ] Winget install exit code: 0 (Success); Category=Success
2025-05-31 11:10:18 [  Success ] Installation completed successfully.
2025-05-31 11:10:18 [  Info    ] Script execution time: 00:00:05.50
2025-05-31 11:10:18 [  Info    ] Exit Code: 0
2025-05-31 11:10:18 [  End     ] ======== Install Script Completed ========
```

---

### 🗑️ `uninstall.ps1`

- Resolves Winget path and checks Winget version (exits 0 if check fails).
- **First attempt:** `winget uninstall -e --id $wingetAppId --silent --scope machine` (or `--scope user` for user context).
- **Retry without scope:** If "no packages found" with scope, retries **without** `--scope` before treating as success. Matches install workaround: when install fell back to no-scope (e.g. Proton Authenticator), uninstall must try no-scope to find and remove the package.
- **Success:** Exit 0 on success or “no packages found” (already uninstalled) after trying both scoped and unscoped.

**Example (success):**

```
2025-05-31 11:12:10 [  Start   ] ======== Uninstall Script Started ========
2025-05-31 11:12:10 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:12:10 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:12:10 [  Get     ] Resolved Winget path.
2025-05-31 11:12:10 [  Info    ] Winget version: v1.10.390
2025-05-31 11:12:10 [  Run     ] Uninstalling with scope machine.
2025-05-31 11:12:12 [  Info    ] Winget uninstall exit code: 0 (Success); Category=Success
2025-05-31 11:12:12 [  Success ] Uninstallation completed successfully.
2025-05-31 11:12:12 [  Info    ] Script execution time: 00:00:01.65
2025-05-31 11:12:12 [  Info    ] Exit Code: 0
2025-05-31 11:12:12 [  End     ] ======== Uninstall Script Completed ========
```

---

## 📄 Log Files & Diagnostics

Logs are written to:

```
%ProgramData%\IntuneLogs\Applications\<applicationName>\
├── detection.log
├── install.log
└── uninstall.log
```

To collect these via Intune **Collect diagnostics**, use a platform script that includes this path, for example:

🔗 [Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory)

---

## 🐛 Troubleshooting

| What to do | How |
|------------|-----|
| **Verbose logging** | Set `$logDebug = $true` at the top of the script. Debug lines (path resolution, full commands, exit code details) will appear in the log. |
| **Winget not working** | Run a separate Winget repair script (e.g. [Winget - System Context](https://github.com/Barg0/Intune-Platform-Scripts/blob/main/Winget%20-%20System%20Context.ps1)) and/or restart the device. These templates exit 0 on Winget version failure so Intune can retry. |
| **Install override with spaces/semicolons** | Use a **single-quoted** PowerShell string for `$installOverride` so the whole value is one argument (e.g. `'/silent STORE0=''...'''`). |

---

*Happy deploying! 🎉*
