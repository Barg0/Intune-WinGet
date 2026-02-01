# ---------------------------[ Script Start Timestamp ]---------------------------

# Capture start time to log script duration
$scriptStartTime = Get-Date

# ---------------------------[ Script name ]---------------------------

# Script name used for folder/log naming
$scriptName = "Winget - App Update"
$logFileName = "remediation.log"

# ---------------------------[ Winget App IDs ]---------------------------

$wingetApps = @(
    @{ ID = "Microsoft.VCRedist.2005.x86"; FriendlyName = "Microsoft Visual C++ 2005 Redistributable (x86)" },
    @{ ID = "Microsoft.VCRedist.2005.x64"; FriendlyName = "Microsoft Visual C++ 2005 Redistributable (x64)" },
    @{ ID = "Microsoft.VCRedist.2008.x86"; FriendlyName = "Microsoft Visual C++ 2008 Redistributable (x86)" },
    @{ ID = "Microsoft.VCRedist.2008.x64"; FriendlyName = "Microsoft Visual C++ 2008 Redistributable (x64)" },
    @{ ID = "Microsoft.VCRedist.2010.x86"; FriendlyName = "Microsoft Visual C++ 2010 Redistributable (x86)" },
    @{ ID = "Microsoft.VCRedist.2010.x64"; FriendlyName = "Microsoft Visual C++ 2010 Redistributable (x64)" },
    @{ ID = "Microsoft.VCRedist.2012.x86"; FriendlyName = "Microsoft Visual C++ 2012 Redistributable (x86)" },
    @{ ID = "Microsoft.VCRedist.2012.x64"; FriendlyName = "Microsoft Visual C++ 2012 Redistributable (x64)" },
    @{ ID = "Microsoft.VCRedist.2013.x86"; FriendlyName = "Microsoft Visual C++ 2013 Redistributable (x86)" },
    @{ ID = "Microsoft.VCRedist.2013.x64"; FriendlyName = "Microsoft Visual C++ 2013 Redistributable (x64)" },
    @{ ID = "Microsoft.VCRedist.2015+.x86"; FriendlyName = "Microsoft Visual C++ 2015-2022 Redistributable (x86)" },
    @{ ID = "Microsoft.VCRedist.2015+.x64"; FriendlyName = "Microsoft Visual C++ 2015-2022 Redistributable (x64)" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.3_1"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 3.1" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.5"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 5.0" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.6"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 6.0" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.7"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 7.0" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.8"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 8.0" },
    @{ ID = "Microsoft.DotNet.DesktopRuntime.9"; FriendlyName = "Microsoft .NET Windows Desktop Runtime 9.0" },
    @{ ID = "Microsoft.DotNet.AspNetCore.3_1"; FriendlyName = "Microsoft ASP.NET Core Runtime 3.1" },
    @{ ID = "Microsoft.DotNet.AspNetCore.5"; FriendlyName = "Microsoft ASP.NET Core Runtime 5.0" },
    @{ ID = "Microsoft.DotNet.AspNetCore.6"; FriendlyName = "Microsoft ASP.NET Core Runtime 6.0" },
    @{ ID = "Microsoft.DotNet.AspNetCore.7"; FriendlyName = "Microsoft ASP.NET Core Runtime 7.0" },
    @{ ID = "Microsoft.DotNet.AspNetCore.8"; FriendlyName = "Microsoft ASP.NET Core Runtime 8.0" },
    @{ ID = "Microsoft.DotNet.AspNetCore.9"; FriendlyName = "Microsoft ASP.NET Core Runtime 9.0" },
    @{ ID = "Microsoft.DotNet.HostingBundle.3_1"; FriendlyName = "Microsoft ASP.NET Core Hosting Bundle 3.1" },
    @{ ID = "Microsoft.DotNet.HostingBundle.5"; FriendlyName = "Microsoft ASP.NET Core Hosting Bundle 5.0" },
    @{ ID = "Microsoft.DotNet.HostingBundle.6"; FriendlyName = "Microsoft ASP.NET Core Hosting Bundle 6.0" },
    @{ ID = "Microsoft.DotNet.HostingBundle.7"; FriendlyName = "Microsoft ASP.NET Core Hosting Bundle 7.0 " },
    @{ ID = "Microsoft.DotNet.HostingBundle.8"; FriendlyName = "Microsoft ASP.NET Core Hosting Bundle 8.0" },
    @{ ID = "Microsoft.DotNet.HostingBundle.9"; FriendlyName = "Microsoft ASP.NET Core Hosting Bundle 9.0" },
    @{ ID = "Microsoft.DotNet.Runtime.3_1"; FriendlyName = "Microsoft .NET Runtime 3.1" },
    @{ ID = "Microsoft.DotNet.Runtime.5"; FriendlyName = "Microsoft .NET Runtime 5.0" },
    @{ ID = "Microsoft.DotNet.Runtime.6"; FriendlyName = "Microsoft .NET Runtime 6.0" },
    @{ ID = "Microsoft.DotNet.Runtime.7"; FriendlyName = "Microsoft .NET Runtime 7.0" },
    @{ ID = "Microsoft.DotNet.Runtime.8"; FriendlyName = "Microsoft .NET Runtime 8.0" },
    @{ ID = "Microsoft.DotNet.Runtime.9"; FriendlyName = "Microsoft .NET Runtime 9.0" },
    @{ ID = "Microsoft.msodbcsql.11"; FriendlyName = "Microsoft ODBC Driver 11 for SQL Server" },
    @{ ID = "Microsoft.msodbcsql.13"; FriendlyName = "Microsoft ODBC Driver 13 for SQL Server" },
    @{ ID = "Microsoft.msodbcsql.17"; FriendlyName = "Microsoft ODBC Driver 17 for SQL Server" },
    @{ ID = "Microsoft.msodbcsql.18"; FriendlyName = "Microsoft ODBC Driver 18 for SQL Server" },
    @{ ID = "Microsoft.VSTOR"; FriendlyName = "Visual Studio 2010 Tools for Office Runtime" },
    @{ ID = "7zip.7zip"; FriendlyName = "7-Zip" },
    @{ ID = "Google.Chrome"; FriendlyName = "Google Chrome" },
    @{ ID = "Google.Chrome.EXE"; FriendlyName = "Google Chrome" },
    @{ ID = "3Dconnexion.3DxWare.10"; FriendlyName = "3Dconnexion 3DxWare 10" },
    @{ ID = "JGraph.Draw"; FriendlyName = "draw.io" },
    @{ ID = "DYMO.DYMOConnect"; FriendlyName = "DYMO Connect" },
    @{ ID = "SolidWorks.eDrawings"; FriendlyName = "eDrawings" },
    @{ ID = "LuxTrust.LuxTrustMiddleware"; FriendlyName = "LuxTrust Middleware" },
    @{ ID = "uvncbvba.UltraVNC"; FriendlyName = "UltraVNC" },
    @{ ID = "Notepad++.Notepad++"; FriendlyName = "Notepad++" },
    @{ ID = "uvncbvba.UltraVNC"; FriendlyName = "eDrawings" },
    @{ ID = "Unity.UnityHub"; FriendlyName = "Unity Hub" },
    @{ ID = "Microsoft.VisualStudio.2022.Professional"; FriendlyName = "Visual Studio Professional 2022" },
    @{ ID = "Yubico.YubiKeySmartCardMinidriver"; FriendlyName = "YubiKey Smart Card Minidriver" }
#   @{ ID = "TEMP"; FriendlyName = "TEMP" }
)

# ---------------------------[ Logging Setup ]---------------------------

# Logging control switches
$log = $true                     # Set to $false to disable logging in shell
$enableLogFile = $true           # Set to $false to disable file output

# Define the log output location
$logFileDirectory = "$env:ProgramData\IntuneLogs\Scripts\$scriptName"
$logFile = "$logFileDirectory\$logFileName"

# Ensure the log directory exists
if ($enableLogFile -and -not (Test-Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# Function to write structured logs to file and console
function Write-Log {
    param ([string]$Message, [string]$Tag = "Info")

    if (-not $log) { return } # Exit if logging is disabled

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tagList = @("Start", "Check", "Info", "Success", "Error", "Debug", "End")
    $rawTag = $Tag.Trim()

    if ($tagList -contains $rawTag) {
        $rawTag = $rawTag.PadRight(7)
    } else {
        $rawTag = "Error  "  # Fallback if an unrecognized tag is used
    }

    # Set tag colors
    $color = switch ($rawTag.Trim()) {
        "Start"   { "Cyan" }
        "Check"   { "Blue" }
        "Info"    { "Yellow" }
        "Success" { "Green" }
        "Error"   { "Red" }
        "Debug"   { "DarkYellow"}
        "End"     { "Cyan" }
        default   { "White" }
    }

    $logMessage = "$timestamp [  $rawTag ] $Message"

    # Write to file if enabled
    if ($enableLogFile) {
        "$logMessage" | Out-File -FilePath $logFile -Append
    }

    # Write to console with color formatting
    Write-Host "$timestamp " -NoNewline
    Write-Host "[  " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------

function Complete-Script {
    param([int]$ExitCode)
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    Write-Log "Script execution time: $($duration.ToString("hh\:mm\:ss\.ff"))" -Tag "Info"
    Write-Log "Exit Code: $ExitCode" -Tag "Info"
    Write-Log "======== Remediation Script Completed ========" -Tag "End"
    exit $ExitCode
}

# ---------------------------[ Winget Path Resolver ]---------------------------
function Get-WingetPath {
    $wingetBase = "$env:ProgramW6432\WindowsApps"
    try {
        # Try x64 first
        $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
            Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' }

        # If x64 not found, try arm64
        if (-not $wingetFolders) {
            $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
                Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_arm64__8wekyb3d8bbwe' }
        }

        if (-not $wingetFolders) {
            throw "No matching Winget installation folders found (x64 or arm64)."
        }

        $latestWingetFolder = $wingetFolders |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        $wingetPath = Join-Path $latestWingetFolder.FullName 'winget.exe'

        if (-not (Test-Path $wingetPath)) {
            throw "winget.exe not found at expected location."
        }

        return $wingetPath
    }
    catch {
        Write-Log "Failed to detect Winget installation: $_" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

# ---------------------------[ Winget Repair Function ]---------------------------

function Invoke-WingetRepair {
    Write-Log "Starting Winget repair..." -Tag "Info"

    Register-WingetDependencyPaths

    Write-Log "Restart required..." -Tag "Info"
    Complete-Script -ExitCode 0
}

function Register-WingetDependencyPaths {
    Write-Log "Registering Winget dependency DLL directories into SYSTEM PATH..." -Tag "Info"
    try {
        $windowsApps = "$env:ProgramW6432\WindowsApps"
        if (-not (Test-Path $windowsApps)) {
            Write-Log "WindowsApps folder not found: $windowsApps" -Tag "Error"
            return
        }

        $dllPackages = @(
            'Microsoft.VCLibs.140.00.UWPDesktop',
            'Microsoft.UI.Xaml.2.8'
        )

        $pathsToAdd = @()

        foreach ($pkg in $dllPackages) {
            $folder = Get-ChildItem -Path $windowsApps -Directory |
                Where-Object { $_.Name -like "$pkg*_x64__*" } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($folder) {
                Write-Log "Found $pkg at: $($folder.FullName)" -Tag "Info"
                $pathsToAdd += $folder.FullName
            } else {
                Write-Log "Could not find folder for $pkg" -Tag "Error"
            }
        }

        $currentPath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $updated = $false
        foreach ($path in $pathsToAdd | Select-Object -Unique) {
            if ($currentPath -notlike "*$path*") {
                Write-Log "Adding path to SYSTEM PATH: $path" -Tag "Info"
                $currentPath += ";$path"
                $updated = $true
            } else {
                Write-Log "Path already present: $path" -Tag "Debug"
            }
        }

        if ($updated) {
            [Environment]::SetEnvironmentVariable("Path", $currentPath, "Machine")
            Write-Log "SYSTEM PATH updated with dependency directories." -Tag "Success"
        } else {
            Write-Log "No changes made to SYSTEM PATH." -Tag "Info"
        }
    } catch {
        Write-Log "Failed to update SYSTEM PATH: $_" -Tag "Error"
    }
}

function Test-NuGetProvider {
    [CmdletBinding()]
    param ([version]$MinimumVersion = [version]'2.8.5.201')
    $provider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $provider) {
        Write-Log 'NuGet Provider Package not detected, installing...' -Tag "Info"
        Install-PackageProvider -Name NuGet -Force | Out-Null
    } elseif ($provider.Version -lt $MinimumVersion) {
        Write-Log "NuGet provider v$($provider.Version) is less than required v$MinimumVersion; updating." -Tag "Info"
        Install-PackageProvider -Name NuGet -Force | Out-Null
    } else {
        Write-Log "NuGet provider meets min requirements (v:$($provider.Version))." -Tag "Success"
    }
}

function Test-Winget {
    # Write-Log "Checking Winget version" -Tag "Debug"
    $wingetPath = Get-WingetPath
    $output = & $wingetPath -v
    $exitCode = $LASTEXITCODE

    if ($null -ne $output -and $exitCode -eq 0) {
        Write-Log "Winget version: $output" -Tag "Info"
    } else {
        Write-Log "Winget execution failed with exit code: $exitCode" -Tag "Error"
        Write-Log "Winget output: $output" -Tag "Debug"
    }

    return $exitCode -eq 0
}

# ---------------------------[ Script Start ]---------------------------

Write-Log "======== Remediation Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"

# ---------------------------[ Winget version check ]---------------------------

if (-not (Test-Winget)) {
    Write-Log "Winget not working correctly. Proceeding to repair." -Tag "Info"
    Test-NuGetProvider
    Invoke-WingetRepair

    Write-Log "Retrying Winget version check after repair..." -Tag "Info"
    if (-not (Test-Winget)) {
        Write-Log "Winget is still not working after repair. Exiting script." -Tag "Error"
        Complete-Script -ExitCode 1
    } else {
        Write-Log "Winget is now functioning after repair." -Tag "Success"
    }
} else {
    # Write-Log "Winget is functioning correctly." -Tag "Debug"
}

# ---------------------------[ Winget app update ]---------------------------

$wingetPath = Get-WingetPath
$hasFailures = $false

foreach ($app in $wingetApps) {
    # Write-Log "Attempting to update $($app.FriendlyName)..." -Tag "Info"
    try {
        $output = & $wingetPath upgrade -e --id $($app.ID) --silent --accept-package-agreements --accept-source-agreements 2>&1
        $outputText = $output -join "`n"

        if ($LASTEXITCODE -eq 0) {
            Write-Log "$($app.FriendlyName) update completed successfully." -Tag "Success"
        }
        elseif ($outputText -match "No available upgrade found|No newer package versions are available") {
            # Write-Log "$($app.FriendlyName) is already up to date." -Tag "Success"
        }
        elseif ($outputText -match "No installed package found") {
            # Write-Log "$($app.FriendlyName) is not installed." -Tag "Info"
        }
        else {
            Write-Log "$($app.FriendlyName) failed with exit code $LASTEXITCODE." -Tag "Error"
            $hasFailures = $true
        }

    } catch {
        Write-Log "Exception while updating $($app.FriendlyName): $_" -Tag "Error"
        $hasFailures = $true
    }
}

# ---------------------------[ Script End ]---------------------------

if ($hasFailures) {
    Complete-Script -ExitCode 1
} else {
    Complete-Script -ExitCode 0

}
