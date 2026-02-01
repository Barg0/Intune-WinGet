## Remediation Script - Winget App Update

This remediation script updates all applications defined in the `$wingetApps` array. Both `detection.ps1` and `remediation.ps1` use the same structure for this variable.

```PowerShell
$wingetApps = @(
    @{ ID = "7zip.7zip"; FriendlyName = "7-Zip" },
    @{ ID = "Microsoft.VCRedist.2015+.x64"; FriendlyName = "Microsoft Visual C++ 2015-2022 Redistributable (x64)" },
    @{ ID = "Microsoft.VCRedist.2015+.x86"; FriendlyName = "Microsoft Visual C++ 2015-2022 Redistributable (x86)" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.8"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 8.0" },
    @{ ID = "Microsoft.DotNet.AspNetCore.8"; FriendlyName = "Microsoft ASP.NET Core Runtime 8.0" }
#   @{ ID = "Google.Chrome"; FriendlyName = "Google Chrome" }
)
```

To find the Winget ID for an app, open PowerShell and run:
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

Copy the `Id` value into the `ID` field in the script, and the `Name` into the `FriendlyName` field.

---

### Detection Script

The detection script checks each defined application and exits with code `1` if __any__ update is available.

Example output:
```
2025-05-31 09:19:06 [  Start   ] ======== Detection Script Started ========
2025-05-31 09:19:06 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Script: Winget - App Update
2025-05-31 09:19:06 [  Info    ] Winget folder count: 1
2025-05-31 09:19:06 [  Info    ] Winget folder path: C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.25.390.0_x64__8wekyb3d8bbwe
2025-05-31 09:19:06 [  Info    ] Winget folder creation date: 2025-05-03 05:09:20
2025-05-31 09:19:06 [  Success ] Navigated to Winget directory successfully.
2025-05-31 09:19:06 [  Check   ] Checking Winget version
2025-05-31 09:19:07 [  Info    ] Winget version: v1.10.390
2025-05-31 09:19:07 [  Success ] Winget is functioning correctly.
2025-05-31 09:19:07 [  Check   ] Checking for updates for 7-Zip
2025-05-31 09:19:08 [  Success ] 7-Zip is up to date or not installed.
2025-05-31 09:19:08 [  Check   ] Checking for updates for Microsoft Visual C++ 2015-2022 Redistributable (x64)
2025-05-31 09:19:09 [  Info    ] Update required for Microsoft Visual C++ 2015-2022 Redistributable (x64).
2025-05-31 09:19:09 [  Check   ] Checking for updates for Microsoft Visual C++ 2015-2022 Redistributable (x86)
2025-05-31 09:19:10 [  Info    ] Update required for Microsoft Visual C++ 2015-2022 Redistributable (x86).
2025-05-31 09:19:10 [  Check   ] Checking for updates for Microsoft .NET Windows Desktop Runtime 8.0
2025-05-31 09:19:11 [  Success ] Microsoft .NET Windows Desktop Runtime 8.0 is up to date or not installed.
2025-05-31 09:19:11 [  Check   ] Checking for updates for Microsoft ASP.NET Core Runtime 8.0
2025-05-31 09:19:12 [  Success ] Microsoft ASP.NET Core Runtime 8.0 is up to date or not installed.
2025-05-31 09:19:12 [  Info    ] Script execution time: 00:00:05.59
2025-05-31 09:19:12 [  Info    ] Exit Code: 1
2025-05-31 09:19:12 [  End     ] ======== Detection Script Completed ========

```
### Remediation Script

If the detection script returns `1`, the remediation script will run and attempt to update the apps.

Example output:
```
2025-05-31 09:27:33 [  Start   ] ======== Remediation Script Started ========
2025-05-31 09:27:33 [  Info    ] ComputerName: WS-81F690CC7DE6 | User: WS-81F690CC7DE6$ | Script: Winget - App Update
2025-05-31 09:27:33 [  Info    ] Winget folder count: 1
2025-05-31 09:27:33 [  Info    ] Winget folder path: C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.25.390.0_x64__8wekyb3d8bbwe
2025-05-31 09:27:33 [  Info    ] Winget folder creation date: 2025-05-03 05:09:20
2025-05-31 09:27:33 [  Success ] Navigated to Winget directory successfully.
2025-05-31 09:27:33 [  Check   ] Checking Winget version
2025-05-31 09:27:33 [  Info    ] Winget version: v1.10.390
2025-05-31 09:27:33 [  Success ] Winget is functioning correctly.
2025-05-31 09:27:33 [  Info    ] Attempting to update 7-Zip...
2025-05-31 09:27:34 [  Success ] 7-Zip is already up to date.
2025-05-31 09:27:34 [  Info    ] Attempting to update Microsoft Visual C++ 2015-2022 Redistributable (x64)...
2025-05-31 09:28:13 [  Success ] Microsoft Visual C++ 2015-2022 Redistributable (x64) update completed successfully.
2025-05-31 09:28:13 [  Info    ] Attempting to update Microsoft Visual C++ 2015-2022 Redistributable (x86)...
2025-05-31 09:28:43 [  Success ] Microsoft Visual C++ 2015-2022 Redistributable (x86) update completed successfully.
2025-05-31 09:28:43 [  Info    ] Attempting to update Microsoft .NET Windows Desktop Runtime 8.0...
2025-05-31 09:28:45 [  Success ] Microsoft .NET Windows Desktop Runtime 8.0 is already up to date.
2025-05-31 09:28:45 [  Info    ] Attempting to update Microsoft ASP.NET Core Runtime 8.0...
2025-05-31 09:28:46 [  Info    ] Microsoft ASP.NET Core Runtime 8.0 is not installed.
2025-05-31 09:28:46 [  Info    ] Script execution time: 00:01:12.88
2025-05-31 09:28:46 [  Info    ] Exit Code: 0
2025-05-31 09:28:46 [  End     ] ======== Remediation Script Completed ========

```
---

> [!TIP]
> The **📄 Log files** for both scripts are saved at: `C:\ProgramData\IntuneLogs\Scripts\Winget - App Update\`
> ```
> C:  
> ├─ 📁 ProgramData
> │  └─📁 IntuneLogs
> │     └─📁 Scripts
> │        └─📁 Winget - App Update
> │           ├─📄 detection.log
> │           └─📄 remediation.log  
> ```
> To enable log collection from this custom directory using the **Collect diagnostics** feature in Intune, deploy the following platform script:
>
> [Diagnostics - Custom Log File Directory](https://github.com/Barg0/Intune-Platform-Scripts/tree/main/Diagnostics%20-%20Custom%20Log%20File%20Directory)

---

### Intune Script Settings

In the [Intune Admin Center](https://intune.microsoft.com):

Navigate to:
`Devices` -> `Windows` -> `Scripts and remediations` -> `Remediations` -> `Create`

- Run this script using the logged-on credentials:  `No`
- Enforce script signature check:                   `No`
- Run script in 64-bit PowerShell:                  `Yes`

Assign the script to a group or to all devices, and schedule it according to your desired frequency.
