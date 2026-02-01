# Win32 – App Deployment

This project provides three PowerShell scripts (`detection.ps1`, `install.ps1`, and `uninstall.ps1`) to deploy **Win32 apps using Winget** via **Microsoft Intune**.

All scripts share a common structure and require two variables to be defined at the top:

Example:
```PowerShell
# Define the Winget App ID
$applicationName = "7-Zip"
$wingetAppID = "7zip.7zip"
```

To find a Winget App ID, open PowerShell and run:
```PowerShell
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

Copy the `Id` into `$wingetAppID` and the `Name` into `$applicationName`.

---

## 📦 Packaging the Win32 App

Use the official [Microsoft-Win32-Content-Prep-Tool](https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool) to package your scripts.

📝 Microsoft documentation:
[Prepare Win32 app content](https://learn.microsoft.com/en-us/intune/intune-service/apps/apps-win32-prepare)

### Folder Structure Example

```
.
├─📁 7-Zip
│  ├──📜 install.ps1
│  └──📜 uninstall.ps1
```

### Packaging Steps

Run `IntuneWinAppUtil.exe` from CMD:

```cmd
C:\Microsoft-Win32-Content-Prep-Tool>IntuneWinAppUtil.exe
Please specify the source folder: C:\Win32WingetDeployment\7-Zip
Please specify the setup file: install.ps1
Please specify the output folder: C:\Win32WingetDeployment
```

The tool will output a file named `install.intunewin`. Rename it to match your app:

```
install.intunewin → 7-Zip.intunewin
```

---

## 🛠️ Deploying the App in Intune

### 1️⃣ App Information

In [Intune Admin Center](https://intune.microsoft.com):

Navigate to:
`Apps` → `Windows` → `Create` → `Windows app (Win32)`

Upload the `.intunewin` file.
Use the following PowerShell command to get detailed app info:

```powershell
winget show "$wingetAppID"
```

Use the output to fill out the **Publisher**, **Description**, **Homepage**, etc.

> [!TIP]
> Search online for a logo to improve the appearance in the **Company Portal**.

---

### 2️⃣ Program Settings ⚙️

**Install command** 🟢

```text
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\install.ps1
```

**Uninstall command** 🔴

```text
%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1
```

* Install behavior: `System`
* Device restart behavior: `Determine behavior based on return codes`
  * `0` - Success
  * `1` - Failed

---

### 3️⃣ Requirements

Configure according to your app. A common baseline:

* Operating system architecture: `32-bit` and `64-bit`
* Minimum OS: `Windows 10 20H2`

---

### 4️⃣ Detection Rules

* **Rules format**: `Use a custom detection script`
* **Script file**: `detection.ps1`

You can skip the remaining app creation steps except for **Assignments**, where you target your desired user or device groups.

---

## \</> Script Behavior

### ✅ `detection.ps1`

**Example (not installed):**

```
2025-05-31 11:08:45 [  Start   ] ======== Detection Script Started ========
2025-05-31 11:08:45 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:08:45 [  Info    ] Starting detection for 7-Zip
2025-05-31 11:08:45 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:08:45 [  Info    ] Winget folder count: 1
2025-05-31 11:08:45 [  Info    ] Winget folder path: C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.25.390.0_x64__8wekyb3d8bbwe
2025-05-31 11:08:45 [  Info    ] Winget folder creation date: 2025-04-23 18:36:54
2025-05-31 11:08:45 [  Success ] Navigated to Winget directory successfully.
2025-05-31 11:08:45 [  Check   ] Checking Winget version
2025-05-31 11:08:45 [  Info    ] Winget version: v1.10.390
2025-05-31 11:08:45 [  Success ] Winget is functioning correctly.
2025-05-31 11:08:45 [  Check   ] Running Winget list to check if 7-Zip is installed...
2025-05-31 11:08:46 [  Error   ] App NOT detected - 7-Zip is NOT installed.
2025-05-31 11:08:46 [  Info    ] Script execution time: 00:00:01.17
2025-05-31 11:08:46 [  Info    ] Exit Code: 1
2025-05-31 11:08:46 [  End     ] ======== Detection Script Completed ========
```

**Example (installed):**

```
2025-05-31 11:11:42 [  Start   ] ======== Detection Script Started ========
2025-05-31 11:11:42 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:11:42 [  Info    ] Starting detection for 7-Zip
2025-05-31 11:11:42 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:11:42 [  Info    ] Winget folder count: 1
2025-05-31 11:11:42 [  Info    ] Winget folder path: C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.25.390.0_x64__8wekyb3d8bbwe
2025-05-31 11:11:42 [  Info    ] Winget folder creation date: 2025-04-23 18:36:54
2025-05-31 11:11:42 [  Success ] Navigated to Winget directory successfully.
2025-05-31 11:11:42 [  Check   ] Checking Winget version
2025-05-31 11:11:42 [  Info    ] Winget version: v1.10.390
2025-05-31 11:11:42 [  Success ] Winget is functioning correctly.
2025-05-31 11:11:42 [  Check   ] Running Winget list to check if 7-Zip is installed...
2025-05-31 11:11:43 [  Success ] App detected - 7-Zip IS installed.
2025-05-31 11:11:43 [  Info    ] Script execution time: 00:00:01.15
2025-05-31 11:11:43 [  Info    ] Exit Code: 0
2025-05-31 11:11:43 [  End     ] ======== Detection Script Completed ========
```

---

### 📅 `install.ps1`

Installs the defined Winget app.

```
2025-05-31 11:10:12 [  Start   ] ======== Install Script Started ========
2025-05-31 11:10:12 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:10:12 [  Info    ] Preparing to install 7-Zip
2025-05-31 11:10:12 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:10:12 [  Info    ] Winget folder count: 1
2025-05-31 11:10:12 [  Info    ] Winget folder path: C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.25.390.0_x64__8wekyb3d8bbwe
2025-05-31 11:10:12 [  Info    ] Winget folder creation date: 2025-04-23 18:36:54
2025-05-31 11:10:12 [  Success ] Navigated to Winget directory successfully.
2025-05-31 11:10:12 [  Check   ] Checking Winget version
2025-05-31 11:10:12 [  Info    ] Winget version: v1.10.390
2025-05-31 11:10:12 [  Success ] Winget is functioning correctly.
2025-05-31 11:10:12 [  Info    ] Executing Winget install command...
2025-05-31 11:10:18 [  Success ] Installation completed successfully.
2025-05-31 11:10:18 [  Info    ] Script execution time: 00:00:05.50
2025-05-31 11:10:18 [  Info    ] Exit Code: 0
2025-05-31 11:10:18 [  End     ] ======== Install Script Completed ========
```

---

### 🗑️ `uninstall.ps1`

Uninstalls the app using Winget.

```
2025-05-31 11:12:10 [  Start   ] ======== Uninstall Script Started ========
2025-05-31 11:12:10 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Application: 7-Zip
2025-05-31 11:12:10 [  Info    ] Preparing to uninstall 7-Zip
2025-05-31 11:12:10 [  Info    ] Winget App ID: 7zip.7zip
2025-05-31 11:12:10 [  Info    ] Winget folder count: 1
2025-05-31 11:12:10 [  Info    ] Winget folder path: C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.25.390.0_x64__8wekyb3d8bbwe
2025-05-31 11:12:10 [  Info    ] Winget folder creation date: 2025-04-23 18:36:54
2025-05-31 11:12:10 [  Success ] Navigated to Winget directory successfully.
2025-05-31 11:12:10 [  Check   ] Checking Winget version
2025-05-31 11:12:10 [  Info    ] Winget version: v1.10.390
2025-05-31 11:12:10 [  Success ] Winget is functioning correctly.
2025-05-31 11:12:10 [  Info    ] Running Winget uninstall command...
2025-05-31 11:12:12 [  Success ] Uninstallation completed successfully.
2025-05-31 11:12:12 [  Info    ] Script execution time: 00:00:01.65
2025-05-31 11:12:12 [  Info    ] Exit Code: 0
2025-05-31 11:12:12 [  End     ] ======== Uninstall Script Completed ========
```

---

> [!TIP]
> The **📄 Log files** for all three scripts are saved at:
> `C:\ProgramData\IntuneLogs\Applications\$applicationName\`
>
> ```
> C:  
> ├─📁 ProgramData
> │  └─📁 IntuneLogs
> │     └─📁 Applications
> │        └─📁 $applicationName
> │           ├─📄 detection.log
> │           ├─📄 install.log
> │           └─📄 uninstall.log
> ```
> To enable log collection from this custom directory using the **Collect diagnostics** feature in Intune, deploy the following platform script:
>
> [Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory)


