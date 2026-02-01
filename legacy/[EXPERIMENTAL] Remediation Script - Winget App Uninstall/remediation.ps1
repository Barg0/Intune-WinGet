# Script version: 2025-07-06 10:00
# Script author: Barg0

# ---------------------------[ Script Start Timestamp ]---------------------------

# Capture start time to log script duration
$scriptStartTime = Get-Date

# ---------------------------[ Script name ]---------------------------

# Script name used for folder/log naming
$scriptName = "Winget - App Uninstall"
$logFileName = "remediation.log"

# ---------------------------[ Winget App IDs ]---------------------------

# List of applications to uninstall
$wingetApps = @(
    @{ ID = "OBSProject.OBSStudio"; FriendlyName = "OBS Studio" },
    @{ ID = "uvncbvba.UltraVNC"; FriendlyName = "UltraVNC" },
    @{ ID = "Microsoft.RemoteDesktopClient"; FriendlyName = "Remote Desktop" },
    @{ ID = "TeamViewer.TeamViewer.Host"; FriendlyName = "TeamViewer Host" }
)

# ---------------------------[ Log Control ]---------------------------

# Logging control switches
$log = $true                     # Set to $false to disable logging in shell
$enableLogFile = $true           # Set to $false to disable file output

# ---------------------------[ Log Folder ]---------------------------

# Define the log output location
$logFileDirectory = "$env:ProgramData\IntuneLogs\Scripts\$scriptName"
$logFile = "$logFileDirectory\$logFileName"

# Ensure the log directory exists
if ($enableLogFile -and -not (Test-Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# ---------------------------[ Log Function ]---------------------------

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

# ---------------------------[ Script Start ]---------------------------

Write-Log "======== Remediation Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"

# ---------------------------[ Winget folder Detection ]---------------------------

# Change to the correct path so winget.exe can run in SYSTEM context
$wingetBase = "$env:ProgramW6432\WindowsApps"

try {
    # Find all matching x64 Winget folders
    $wingetFolders = Get-ChildItem -Path $wingetBase -Directory |
        Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' }
        Write-Log "Winget folder count: $($wingetFolders.Count)" -Tag "Info"
    if ($null -eq $wingetFolders -or $wingetFolders.Count -eq 0) {
        throw "No matching Winget installation folders found."
    }

    # Sort by CreationTime (latest first)
    $latestWingetFolder = $wingetFolders |
        Sort-Object CreationTime -Descending |
        Select-Object -First 1

    # Log selected folder path and creation date
    Write-Log "Winget folder path: $($latestWingetFolder.FullName)" -Tag "Info"
    Write-Log "Winget folder creation date: $($latestWingetFolder.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'))" -Tag "Info"

    # Change to the most recent folder
    Set-Location -Path $latestWingetFolder.FullName
    Write-Log "Navigated to Winget directory successfully." -Tag "Success"

} catch {
    Write-Log "Failed to access Winget directory. Exception: $_" -Tag "Error"
    Complete-Script -ExitCode 1
}

# ---------------------------[ Winget repair functions ]---------------------------

function Test-NuGetProvider {
	[CmdletBinding()]
	param (
		[version]$MinimumVersion = [version]'2.8.5.201'
	)
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
    Write-Log "Checking Winget version" -Tag "Check"
    $wingetVersionOutput = & .\winget.exe -v
    $wingetVersionExitCode = $LASTEXITCODE

    if ($null -ne $wingetVersionOutput -and $wingetVersionExitCode -eq 0) {
        Write-Log "Winget version: $wingetVersionOutput" -Tag "Info"
    }
    elseif ($wingetVersionExitCode -ne 0) {
        Write-Log "Winget execution failed with exit code: $wingetVersionExitCode" -Tag "Error"
        Write-Log "Winget output: $wingetVersionOutput" -Tag "Debug"
    }

    return $wingetVersionExitCode -eq 0
}

function Invoke-WingetRepair {
    Write-Log "Attempting Winget repair..." -Tag "Info"

    try {
        Write-Log "Installing Microsoft.WinGet.Client from PSGallery..." -Tag "Info"
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -Scope AllUsers -ErrorAction Stop | Out-Null
        Write-Log "Module installed successfully." -Tag "Success"

        Write-Log "Running Repair-WinGetPackageManager..." -Tag "Info"
        Repair-WinGetPackageManager -AllUsers -Force -Latest -ErrorAction Stop | Out-Null
        Write-Log "Repair completed successfully." -Tag "Success"
    }
    catch {
        Write-Log "Exception during Winget repair attempt: $_" -Tag "Error"
    }
}

# ---------------------------[ Winget version check ]---------------------------

# Run initial check
if (-not (Test-Winget)) {
    Write-Log "Winget not working correctly. Proceeding to repair." -Tag "Info"

    Test-NuGetProvider
    Invoke-WingetRepair

    # Retry after repair
    Write-Log "Retrying Winget version check after repair..." -Tag "Info"
    if (-not (Test-Winget)) {
        Write-Log "Winget is still not working after repair. Exiting script." -Tag "Error"
        Complete-Script -ExitCode 1
    }
    else {
        Write-Log "Winget is now functioning after repair." -Tag "Success"
    }
}
else {
    Write-Log "Winget is functioning correctly." -Tag "Success"
}

# ---------------------------[ Detection Function ]---------------------------

function Test-WingetAppInstalled {
    param (
        [string]$AppID,
        [string]$AppName
    )

    # Run Winget list to check if app is installed
    $output = & .\winget.exe list -e --id $AppID --accept-source-agreements
    $exitCode = $LASTEXITCODE

    # Exit code -1978335212 means no installed package found
    if ($exitCode -eq -1978335212 -and $output -match 'No installed package') {
        Write-Log "$AppName is NOT installed." -Tag "Success"
        return $false
    }
    elseif ($exitCode -ne 0) {
        # Unexpected Winget error - assume installed to be safe
        Write-Log "Winget failed while checking $AppName (code: $exitCode)." -Tag "Error"
        return $true
    }
    else {
        Write-Log "$AppName IS installed." -Tag "Info"
        return $true
    }
}

# ---------------------------[ Uninstall Logic ]---------------------------

# Will be set to false if any app fails to uninstall
$allUninstallsSuccessful = $true

foreach ($app in $wingetApps) {
    $appName = $app.FriendlyName
    $appID = $app.ID

    # Skip if already uninstalled
    if (-not (Test-WingetAppInstalled -AppID $appID -AppName $appName)) {
        Write-Log "$appName is already uninstalled. Skipping." -Tag "Info"
        continue
    }

    Write-Log "Attempting to uninstall $appName..." -Tag "Check"

    try {
        # Attempt uninstall
        .\winget.exe uninstall -e --id $appID --silent --force --accept-source-agreements
        Start-Sleep -Seconds 5
    } catch {
        Write-Log "Initial uninstall failed for $($appName): $_" -Tag "Error"
    }

    # Check if uninstall succeeded
    if (Test-WingetAppInstalled -AppID $appID -AppName $appName) {
        Write-Log "$appName still detected. Retrying uninstall..." -Tag "Check"

        try {
            # Retry once
            .\winget.exe uninstall -e --id $appID --silent --force --accept-source-agreements
            Start-Sleep -Seconds 5
        } catch {
            Write-Log "Retry uninstall failed for $($appName): $_" -Tag "Error"
        }
    }

    # Final verification
    if (Test-WingetAppInstalled -AppID $appID -AppName $appName) {
        Write-Log "Final check: $appName was NOT removed." -Tag "Error"
        $allUninstallsSuccessful = $false
    } else {
        Write-Log "$appName uninstalled successfully." -Tag "Success"
    }
}

# ---------------------------[ Completion ]---------------------------

# Exit with 1 if any uninstalls failed (to flag failure in Intune)
if ($allUninstallsSuccessful) {
    Complete-Script -ExitCode 0
} else {
    Complete-Script -ExitCode 1
}