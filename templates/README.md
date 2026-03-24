# 🧩 Win32 App Templates -- What Runs on the Device

This folder contains three PowerShell script templates that **run on target devices** when Intune deploys, detects, or uninstalls a Win32 app. These scripts are the core of the system: they call WinGet, handle retries, manage scope fallbacks, and write detailed logs.

You do not normally need to edit these files. `package.ps1` reads your `apps.csv` and generates per-app copies with the correct values filled in. But if you want to understand what happens on the device, customize behavior, use the scripts standalone, or troubleshoot a failed deployment, this document covers everything.

---

## 📋 Table of Contents

- [📋 What's in Here](#-whats-in-here)
- [🔧 How Values Are Injected](#-how-values-are-injected)
- [🛠️ Using Scripts Standalone](#-using-scripts-standalone)
- [🧪 Testing Locally with PsExec](#-testing-locally-with-psexec)
- [⚙️ Manual Intune Upload Settings](#-manual-intune-upload-settings)
- [🔍 Script Behavior -- detection.ps1](#-script-behavior----detectionps1)
- [📥 Script Behavior -- install.ps1](#-script-behavior----installps1)
- [🗑️ Script Behavior -- uninstall.ps1](#-script-behavior----uninstallps1)
- [📊 WinGet Exit Code Reference](#-winget-exit-code-reference)
- [📋 Logging](#-logging)
- [🔒 WinGet Version Check and Repair](#-winget-version-check-and-repair)
- [🔬 Install Override Deep Dive](#-install-override-deep-dive)
- [🐛 Troubleshooting](#-troubleshooting)
- [📚 References](#-references)

---

## 📋 What's in Here

| Script | Purpose | When Intune runs it |
|--------|---------|---------------------|
| **detection.ps1** | Checks if the app is installed | Before install, periodically after install, before uninstall |
| **install.ps1** | Installs the app via WinGet | When deploying Required, or when user clicks Install in Company Portal |
| **uninstall.ps1** | Removes the app via WinGet | When uninstalling the app from Intune |

---

## 🔧 How Values Are Injected

Each template has placeholders at the top. When `package.ps1` generates the per-app scripts, it replaces these placeholders with values from `apps.csv`.

**Template (before packaging):**

```powershell
$applicationName  = '__APPLICATION_NAME__'
$wingetAppId      = '__WINGET_APP_ID__'
$installContext   = '__INSTALL_CONTEXT__'
$installOverride  = '__INSTALL_OVERRIDE__'    # install.ps1 only
```

**Generated script (after packaging):**

```powershell
$applicationName  = '7-Zip'
$wingetAppId      = '7zip.7zip'
$installContext   = 'system'
$installOverride  = ''
```

| Placeholder | Used in | Source | Description |
|-------------|---------|--------|-------------|
| `__APPLICATION_NAME__` | All three scripts | `apps.csv` > ApplicationName | Display name used in logs and log file paths |
| `__WINGET_APP_ID__` | All three scripts | `apps.csv` > WingetAppId | WinGet package ID passed to `winget install/uninstall/list` |
| `__INSTALL_CONTEXT__` | All three scripts | `apps.csv` > InstallContext | `system` or `user` -- controls how WinGet is invoked |
| `__INSTALL_OVERRIDE__` | install.ps1 only | `apps.csv` > InstallOverride | Extra arguments for `winget install --override` |

Values are stored in single-quoted PowerShell strings. Apostrophes in names (e.g. `Dell's Optimizer`) are automatically escaped as `''`. Double quotes in override values (e.g. `/v "/qn"`) are preserved as literal characters inside single quotes.

---

## 🛠️ Using Scripts Standalone

You can use these scripts without `package.ps1` or `deploy.ps1` -- for example, to deploy a single app manually or to integrate them into a different deployment system.

### Step 1: Copy the templates

Copy all three scripts from this folder to a new folder:

```
MyApp/
├── install.ps1
├── uninstall.ps1
└── detection.ps1
```

### Step 2: Replace the placeholders

Open each script and edit the variables at the top. Replace the `__PLACEHOLDER__` values with real values:

```powershell
$applicationName  = 'Google Chrome'
$wingetAppId      = 'Google.Chrome'
$installContext   = 'system'
$installOverride  = ''                    # install.ps1 only
```

How to find the WinGet App ID:

```powershell
winget search "Google Chrome"
```

```
Name           Id             Version  Source
----------------------------------------------
Google Chrome  Google.Chrome  133.0... winget
```

Use the **Id** column value.

### Step 3: Run the scripts directly

You can now run these scripts directly from PowerShell:

```powershell
# Install the app
.\install.ps1

# Check if it's detected
.\detection.ps1

# Uninstall it
.\uninstall.ps1
```

The scripts will work exactly the same as when Intune runs them. They write logs to `%ProgramData%\IntuneLogs\Applications\<ApplicationName>\`.

### Step 4 (optional): Package for Intune

If you want to deploy through Intune manually, package the scripts using [IntuneWinAppUtil.exe](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases):

```cmd
IntuneWinAppUtil.exe -c "C:\Path\To\MyApp" -s install.ps1 -o "C:\Path\To\Output"
```

This creates `install.intunewin` containing both `install.ps1` and `uninstall.ps1`. Upload it to Intune manually (see [Manual Intune Upload Settings](#manual-intune-upload-settings) below).

---

## 🧪 Testing Locally with PsExec

Before deploying through Intune, test the scripts on a VM or test machine. This catches issues before they affect production devices.

### Testing in SYSTEM context (simulates what Intune does)

Download [PsExec](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec) from Sysinternals. Then open an **elevated** Command Prompt (Run as Administrator) and run:

```cmd
psexec -i -s powershell.exe
```

This opens a PowerShell window running as the SYSTEM account -- the same context Intune uses for system-context apps. You can verify with:

```powershell
whoami
# Output: nt authority\system
```

Now navigate to the scripts folder and test the full cycle:

```powershell
# 1. Install the app
cd "C:\Intune-WinGet\apps\Google Chrome\scripts"
.\install.ps1

# 2. Verify detection works
.\detection.ps1
# Expected: exit code 0 (echo $LASTEXITCODE to check)

# 3. Uninstall the app
.\uninstall.ps1

# 4. Verify detection reports not installed
.\detection.ps1
# Expected: exit code 1
```

### Testing in user context

For apps with `$installContext = 'user'`, no PsExec is needed. Just open a normal PowerShell window and run the scripts directly.

### Checking the logs

After running, check the logs:

```powershell
Get-Content "$env:ProgramData\IntuneLogs\Applications\Google Chrome\install.log"
```

Look for:
- `[  Success ]` -- operation completed successfully
- `[  Error   ]` -- something went wrong (the log includes the WinGet exit code and description)
- `[  Info    ]` -- retry and fallback information

### Common testing issues

| Issue | Cause | Fix |
|-------|-------|-----|
| `winget` not found in SYSTEM context | WinGet UWP dependencies not available to SYSTEM | Deploy [Winget-SystemContext](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) to register them |
| Detection returns wrong result | WinGet package ID doesn't match what's installed | Run `winget list` in the same context (SYSTEM or user) and verify the ID |
| Override not applied | Override contains unescaped characters | Check the `install.log` for the exact command being invoked (enable `$logDebug = $true` for full details) |

---

## ⚙️ Manual Intune Upload Settings

When uploading a `.intunewin` package manually in [Intune Admin Center](https://intune.microsoft.com) > **Apps** > **Windows** > **Add** > **Windows app (Win32)**, use these settings.

### App Information

| Field | Value |
|-------|-------|
| Name | Your app name (e.g. `Google Chrome`) |
| Description | From `winget show <id>` or your own |
| Publisher | From `winget show <id>` |
| App version | `WinGet` (WinGet handles versioning) |
| Logo | Optional PNG |

### Program

**For system context apps:**

| Setting | Value |
|---------|-------|
| Install command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\install.ps1` |
| Uninstall command | `%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1` |
| Install behavior | System |

**For user context apps:**

| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden .\install.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden .\uninstall.ps1` |
| Install behavior | User |

*User context uses `-NoProfile -NonInteractive -WindowStyle Hidden` to reduce visible console window.*

**Shared settings:**

| Setting | Value |
|---------|-------|
| Device restart behavior | Determine behavior based on return codes |
| Return codes | `0` = Success, `1` = Failed |
| Max install time | 60 minutes |

**Why `sysnative`?** When Intune runs a 32-bit process as SYSTEM, `%WINDIR%\System32` redirects to `SysWOW64` due to WoW64 file system redirection. The `sysnative` virtual path bypasses this and ensures 64-bit PowerShell is used, which is required for WinGet.

### Requirements

| Setting | Suggested value |
|---------|-----------------|
| OS architecture | 32-bit and 64-bit |
| Minimum OS | Windows 10 21H1 |

### Detection Rules

| Setting | Value |
|---------|-------|
| Rules format | Use a custom detection script |
| Script file | Upload `detection.ps1` |
| Run script as 32-bit | No |
| Enforce script signature check | No |

The detection script exits `0` when the app is installed, `1` when not.

### Assignments

| Assignment type | Group | Notifications |
|-----------------|-------|---------------|
| Required | `Win - SW - RQ - <AppName>` | Hide all toast notifications |
| Available | `Win - SW - AV - <AppName>` | Default |

---

## 🔍 Script Behavior -- detection.ps1

**Purpose:** Check if the app is installed on the device.

### Flow

1. Resolve WinGet path (system context: search `WindowsApps` for the latest `DesktopAppInstaller` folder; user context: use `winget` from PATH).
2. Run `winget --version` to verify WinGet is working. If it fails, exit 0 (Intune retries later rather than marking the app as failed).
3. Set console encoding to UTF-8 around the `winget list` call (handles Unicode characters in app names).
4. Run `winget list -e --id <wingetAppId>` and capture the output.
5. Parse the output: if the app ID appears in a results row, the app is detected.
6. **Exit 0** = app installed. **Exit 1** = app not found.

### Log example -- app not installed

```
2026-03-22 17:12:05 [  Start   ] ======== Detection Script Started ========
2026-03-22 17:12:05 [  Info    ] ComputerName: VM-WIN11 | User: user | Application: Proton Authenticator
2026-03-22 17:12:05 [  Info    ] Winget App ID: Proton.ProtonAuthenticator | Install context: user
2026-03-22 17:12:05 [  Info    ] Winget version: v1.28.220
2026-03-22 17:12:05 [  Run     ] Checking installed packages for: Proton.ProtonAuthenticator
2026-03-22 17:12:05 [  Info    ] App NOT detected - Proton Authenticator is NOT installed.
2026-03-22 17:12:05 [  Info    ] Exit Code: 1
2026-03-22 17:12:05 [  End     ] ======== Detection Script Completed ========
```

### Log example -- app installed

```
2026-03-22 17:12:19 [  Start   ] ======== Detection Script Started ========
2026-03-22 17:12:19 [  Info    ] ComputerName: VM-WIN11 | User: user | Application: Proton Authenticator
2026-03-22 17:12:19 [  Info    ] Winget App ID: Proton.ProtonAuthenticator | Install context: user
2026-03-22 17:12:19 [  Info    ] Winget version: v1.28.220
2026-03-22 17:12:19 [  Run     ] Checking installed packages for: Proton.ProtonAuthenticator
2026-03-22 17:12:20 [  Success ] App detected - Proton Authenticator IS installed.
2026-03-22 17:12:20 [  Info    ] Exit Code: 0
2026-03-22 17:12:20 [  End     ] ======== Detection Script Completed ========
```

---

## 📥 Script Behavior -- install.ps1

**Purpose:** Install the app using WinGet with automatic retry logic for common failure scenarios.

### Flow

1. Resolve WinGet path.
2. Check WinGet version. If unhealthy, exit 0 (Intune retries later).
3. Build the install command:

```
winget install -e --id <id> --silent --skip-dependencies
    --accept-package-agreements --accept-source-agreements --force
    --scope machine       (or --scope user)
    --override "<value>"  (if InstallOverride is set)
```

4. Execute the command using `ProcessStartInfo` (not PowerShell splatting) to ensure override arguments with spaces and quotes are passed as a single argument to WinGet.
5. Check the WinGet exit code and apply the retry engine:

```
Attempt 1: winget install --scope machine (or user)
  |
  | If "no applicable installer for scope" or "no packages found"
  v
Attempt 2: winget install (no --scope)
  |
  | If "pinned certificate mismatch"
  v
Attempt 3: winget install --source winget (no --scope)
  |
  | If "another installation in progress"
  v
Wait 2 minutes, retry (up to 15 times)
  |
  | If transient error (disk full, reboot needed, no network)
  v
Exit 0 (Intune retries later)
  |
  | If unrecoverable error (policy block, invalid parameter)
  v
Exit 1 (Intune marks as failed)
```

6. On success, exit 0.

### Exit code categories

| Category | What the script does | Example WinGet errors |
|----------|---------------------|----------------------|
| **Success** | Exit 0 | Installed successfully, already installed, higher version installed |
| **RetryScope** | Remove `--scope` and try again | No applicable installer for scope, no packages found |
| **RetrySource** | Add `--source winget` and try again | Pinned certificate mismatch |
| **RetryLater** | Exit 0 so Intune can retry later | App in use, disk full, reboot needed, no network |
| **Fail** | Exit 1 | Blocked by policy, invalid parameter, missing dependency |
| **Unknown** | Log and treat as Fail | Any unmapped exit code |

Each workaround (RetryScope, RetrySource) is tried at most once. They can chain: a RetrySource followed by a RetryScope produces a final attempt with `--source winget` and no `--scope`.

### Log example -- install with scope fallback

```
2026-03-22 17:12:10 [  Start   ] ======== Install Script Started ========
2026-03-22 17:12:10 [  Info    ] ComputerName: VM-WIN11 | User: user | Application: Proton Authenticator
2026-03-22 17:12:10 [  Info    ] Winget App ID: Proton.ProtonAuthenticator | Install context: user
2026-03-22 17:12:10 [  Info    ] Winget version: v1.28.220
2026-03-22 17:12:10 [  Run     ] Installing (scope user).
No applicable installer found; see logs for more details.
2026-03-22 17:12:11 [  Info    ] Winget exit code: -1978335216 (No applicable installer for scope); Category=RetryScope
2026-03-22 17:12:11 [  Info    ] No applicable installer for scope user; retrying without --scope.
2026-03-22 17:12:11 [  Run     ] Installing (no scope).
Successfully installed
2026-03-22 17:12:16 [  Info    ] Winget exit code: 0 (Success); Category=Success
2026-03-22 17:12:16 [  Success ] Installation completed successfully after workaround (no scope).
2026-03-22 17:12:16 [  Info    ] Exit Code: 0
2026-03-22 17:12:16 [  End     ] ======== Install Script Completed ========
```

---

## 🗑️ Script Behavior -- uninstall.ps1

**Purpose:** Remove the app using WinGet with scope fallback.

### Flow

1. Resolve WinGet path.
2. Check WinGet version. If unhealthy, exit 0 (Intune retries later).
3. Run `winget uninstall -e --id <id> --silent --scope <scope>`.
4. If "no packages found" (exit code -1978335212), retry without `--scope`. This handles the case where the install script fell back to installing without scope -- the uninstall must do the same.
5. Exit 0 on success or when the package is genuinely not found (already uninstalled).

### Why the scope fallback matters

If `install.ps1` fell back to installing without `--scope` (e.g. because the app had no applicable installer for `--scope machine`), then the package was registered without a scope. Running `winget uninstall --scope machine` won't find it. The uninstall script automatically detects this and retries without `--scope`.

### Log example -- uninstall with scope fallback

```
2026-03-22 17:15:01 [  Start   ] ======== Uninstall Script Started ========
2026-03-22 17:15:01 [  Info    ] Winget App ID: Proton.ProtonAuthenticator | Install context: user
2026-03-22 17:15:01 [  Info    ] Winget version: v1.28.220
2026-03-22 17:15:01 [  Run     ] Uninstalling with scope user.
No installed package found matching input criteria.
2026-03-22 17:15:02 [  Info    ] Winget uninstall exit code: -1978335212; Category=Success
2026-03-22 17:15:02 [  Info    ] No package found for scope user; retrying without --scope.
2026-03-22 17:15:02 [  Run     ] Uninstalling with no scope.
Successfully uninstalled
2026-03-22 17:15:05 [  Success ] Uninstallation completed successfully after retry (no scope).
2026-03-22 17:15:05 [  Info    ] Exit Code: 0
2026-03-22 17:15:05 [  End     ] ======== Uninstall Script Completed ========
```

---

## 📊 WinGet Exit Code Reference

The install script maps WinGet exit codes to categories that determine retry behavior. Here is the full table:

### Success (exit 0)

| Exit Code | Description |
|-----------|-------------|
| `0` | Success |
| `-1978335135` | Package already installed |
| `-1978334963` | Another version already installed |
| `-1978334962` | Higher version already installed |
| `-1978334965` | Reboot initiated to finish installation |

### RetryScope (retry without --scope)

| Exit Code | Description |
|-----------|-------------|
| `-1978335216` | No applicable installer for scope |
| `-1978335212` | No packages found |

### RetrySource (retry with --source winget)

| Exit Code | Description |
|-----------|-------------|
| `-1978335138` | Pinned certificate mismatch |

### RetryLater (exit 0, Intune retries)

| Exit Code | Description |
|-----------|-------------|
| `-1978334975` | Application is currently running |
| `-1978334974` | Another installation in progress |
| `-1978334973` | One or more file is in use |
| `-1978334971` | Disk full |
| `-1978334970` | Insufficient memory |
| `-1978334969` | No network connectivity |
| `-1978334967` | Reboot required to finish installation |
| `-1978334966` | Reboot required then try again |
| `-1978334959` | Package in use by another application |
| `-1978335125` | Service busy or unavailable |

### Fail (exit 1)

| Exit Code | Description |
|-----------|-------------|
| `-1978335217` | No applicable installer |
| `-1978334972` | Missing dependency |
| `-1978334968` | Installation error; contact support |
| `-1978334964` | Installation cancelled by user |
| `-1978334961` | Blocked by organization policy |
| `-1978334960` | Failed to install dependencies |
| `-1978334958` | Invalid parameter |
| `-1978334957` | Package not supported on this system |
| `-1978334956` | Installer does not support upgrade |

Any exit code not in this table is logged as **Unknown** and treated as Fail.

---

## 📋 Logging

All three scripts use the same logging system with timestamped, color-coded, tagged entries written to both the console and a log file.

### Log location on devices

```
%ProgramData%\IntuneLogs\Applications\<ApplicationName>\
├── install.log
├── uninstall.log
└── detection.log
```

### Log tags

| Tag | Color | Meaning |
|-----|-------|---------|
| Start / End | Cyan | Script start/end banners |
| Get | Blue | Discovery operations (resolving paths, reading data) |
| Run | Magenta | Execution (WinGet commands, Graph API calls) |
| Info | Yellow | General status messages |
| Success | Green | Successful operations |
| Error | Red | Failures |
| Debug | DarkYellow | Verbose troubleshooting (only when `$logDebug = $true`) |

### Log switches (top of each script)

| Variable | Default | Description |
|----------|---------|-------------|
| `$log` | `$true` | Master switch -- disable all logging |
| `$logDebug` | `$false` | Enable verbose Debug-tagged output |
| `$logGet` | `$true` | Enable Get-tagged lines (path resolution, data reads) |
| `$logRun` | `$true` | Enable Run-tagged lines (WinGet commands) |
| `$enableLogFile` | `$true` | Write logs to file on disk |

### Collecting logs from devices

Use Intune **Collect diagnostics** with a platform script that includes the log directory:

[Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory)

Or read logs manually via remote PowerShell / RDP / another remote management tool.

---

## 🔒 WinGet Version Check and Repair

Every script runs `winget --version` before performing any operations. If the check fails (non-zero exit code or no output):

- The script logs a warning suggesting a restart or repair.
- **Exits with code 0** so Intune does not mark the app as permanently failed.
- Intune will retry the deployment after the device reboots or checks in again.

This is a deliberate design choice: if WinGet is broken (e.g. after a Windows update that removes the App Installer), exiting 1 would cause Intune to mark the app as "failed" with no automatic retry. Exiting 0 lets Intune retry silently once WinGet is repaired.

**To make WinGet work in SYSTEM context**, deploy this script via Intune as a Platform Script:

[Winget-SystemContext](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) -- Registers the required UWP dependency paths (`Microsoft.VCLibs`, `Microsoft.UI.Xaml`) so they are available to WinGet when running as SYSTEM.

---

## 🔬 Install Override Deep Dive

The `--override` flag tells WinGet to replace its default silent install arguments with the value you provide. This is necessary for apps that need custom installer flags (e.g. Citrix store configuration, MSI properties, custom install paths).

### How the script passes the override to WinGet

The override value from `$installOverride` must be passed as **a single argument** to `winget.exe`. If it gets split (e.g. at spaces), WinGet interprets the extra pieces as package search queries and fails with "An argument was provided that can only be used for single package."

To avoid this, the install script uses `System.Diagnostics.ProcessStartInfo` instead of PowerShell's `& $exe @args` splatting:

- **PowerShell 7 / .NET Core 5+:** Uses `ProcessStartInfo.ArgumentList`, which automatically handles escaping per Windows conventions.
- **PowerShell 5.1 / .NET Framework:** Uses `ProcessStartInfo.Arguments` with manual escaping that follows the [`CommandLineToArgvW`](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-commandlinetoargvw) rules (the same algorithm as .NET's [`PasteArguments`](https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/PasteArguments.cs)).

### What is handled correctly

| Content in override | Example | Status |
|---------------------|---------|--------|
| Spaces | `/silent /norestart` | Handled |
| Double quotes | `STORE0="AppStore;..."` | Handled |
| Backslashes in paths | `INSTALLDIR=C:\Program Files\App` | Handled |
| Trailing backslash | `C:\Path\` | Handled |
| Semicolons | `STORE0="App;https://...;on;Name"` | Handled |
| URLs | `https://server.net/path` | Handled |
| Empty value | *(leave blank)* | Handled (no `--override` passed) |

### Known WinGet / installer limitations

These are issues in WinGet itself, not in this script. They cannot be fixed by the override escaping.

| Scenario | Limitation | Workaround |
|----------|------------|------------|
| Environment variables with spaces in override | [winget-cli #2399](https://github.com/microsoft/winget-cli/issues/2399): WinGet's parser stops at the first space inside an expanded variable like `$Env:ProgramFiles` | Use paths without spaces (e.g. `C:\Progra~1\...`) or hardcode the full path |
| Non-ASCII characters in paths | [winget-cli #4765](https://github.com/microsoft/winget-cli/issues/4765): characters like e, B are encoded incorrectly | Avoid accented characters in usernames or paths when possible |
| PowerShell variables in override | The generated script uses single-quoted strings, so `$Env:TEMP` is a literal string, not expanded | Use concrete values in `apps.csv`, not PowerShell variables |

### Override examples

| Scenario | Value in apps.csv | What the installer receives |
|----------|------------------|-----------------------------|
| Default (none) | *(leave empty)* | WinGet uses its built-in silent flags |
| Force silent | `/silent` | `/silent` |
| MSI quiet (EXE-wrapped) | `/s /v "/qn"` | `/s /v "/qn"` |
| Custom path (NSIS) | `/D=C:\Apps\MyApp` | `/D=C:\Apps\MyApp` |
| Citrix store config | `/silent STORE0="AppStore;https://server/Store/discovery;on;My Store"` | `/silent STORE0="AppStore;https://server/Store/discovery;on;My Store"` |

For more details on WinGet override handling, see:
- [winget-cli #1317](https://github.com/microsoft/winget-cli/issues/1317) -- Override with spaces in paths
- [winget-cli #5240](https://github.com/microsoft/winget-cli/issues/5240) -- Override with double quotes

---

## 🐛 Troubleshooting

These are issues that occur **on the device** when the scripts run. For issues with `package.ps1` or `deploy.ps1`, see the [main README](../README.md#troubleshooting).

| Issue | Solution |
|-------|----------|
| WinGet not working as SYSTEM | Deploy [Winget-SystemContext](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) via Intune, then restart devices. |
| App installs but detection fails | Check `%ProgramData%\IntuneLogs\Applications\<App>\detection.log`. Verify the WinGet App ID matches what `winget list` shows in the same context (SYSTEM vs user). |
| Uninstall says "no packages found" | Expected when install used scope fallback. The uninstall script retries without `--scope` automatically. Check the log to confirm. |
| Install exits 0 but app not installed | A transient error occurred (RetryLater category). Intune will retry. Check `install.log` for the specific WinGet exit code. |
| Install fails with "single package" error | Override with spaces/quotes was being split into multiple arguments. This was fixed by using `ProcessStartInfo.ArgumentList`. Make sure you are using the latest template. Re-package and redeploy. |
| WinGet version check fails | The script exits 0 so Intune can retry after reboot. Deploy Winget-SystemContext to make UWP dependencies available. |
| Override not applied correctly | Enable `$logDebug = $true` in the script, re-package, redeploy, and check the `[Debug]` log lines for the exact command being invoked. |
| Non-English Windows causes issues | `package.ps1` normalizes `winget show` output via `jsons/language.json`. If your locale is missing, add it following the existing pattern. This only affects packaging, not on-device scripts. |

---

## 📚 References

- [WinGet return codes](https://github.com/microsoft/winget-cli/blob/master/doc/windows/package-manager/winget/returnCodes.md) -- Exit code reference
- [WinGet install --override](https://learn.microsoft.com/en-us/windows/package-manager/winget/install) -- Override documentation
- [winget-cli #1317](https://github.com/microsoft/winget-cli/issues/1317) -- Override with spaces in paths (PowerShell escaping)
- [winget-cli #5240](https://github.com/microsoft/winget-cli/issues/5240) -- Override with double quotes
- [winget-cli #2399](https://github.com/microsoft/winget-cli/issues/2399) -- Environment variables with spaces in override
- [CommandLineToArgvW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-commandlinetoargvw) -- Windows argument parsing rules
- [.NET PasteArguments source](https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/PasteArguments.cs) -- The escaping algorithm used in the fallback
- [Everyone quotes command line arguments the wrong way](https://learn.microsoft.com/en-us/archive/blogs/twistylittlepassagesallalike/everyone-quotes-command-line-arguments-the-wrong-way) -- Microsoft blog explaining the quoting problem
- [FileWave -- WinGet troubleshooting](https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget) -- Common error codes
- [Winget-SystemContext](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Winget-SystemContext) -- Make WinGet work in SYSTEM context
- [PsExec](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec) -- Sysinternals tool for testing as SYSTEM
- [Prepare Win32 app content](https://learn.microsoft.com/en-us/mem/intune/apps/apps-win32-prepare) -- Intune documentation for manual packaging
- [Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory) -- Collect device logs remotely via Intune
