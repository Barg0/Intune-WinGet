# Script version: 2025-08-10 21:30
# Script author: Barg0

# ---------------------------[ Script Start Timestamp ]---------------------------

# Capture start time to log script duration
$scriptStartTime = Get-Date

# ---------------------------[ Winget App ID ]---------------------------

# Define the Winget App ID
$applicationName = "__APPLICATION_NAME__"
$wingetAppID     = "__WINGET_APP_ID__"

# ---------------------------[ Log name ]---------------------------

$logFileName = "uninstall.log"

# ---------------------------[ Logging Setup ]---------------------------

# Logging control switches
$log = $true                     # Set to $false to disable logging in shell
$enableLogFile = $true           # Set to $false to disable file output

# Define the log output location
$logFileDirectory = "$env:ProgramData\IntuneLogs\Applications\$applicationName"
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
    Write-Log "======== Uninstall Script Completed ========" -Tag "End"
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

Write-Log "======== Uninstall Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Application: $applicationName" -Tag "Info"
Write-Log "Winget App ID: $wingetAppID" -Tag "Info"

# ---------------------------[ Winget version check ]---------------------------

if (-not (Test-Winget)) {
    Write-Log "Winget not working correctly. Proceeding to repair." -Tag "Info"

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

# ---------------------------[ Winget app uninstall ]---------------------------

try {
    $wingetPath = Get-WingetPath

    # Write-Log "Attempt: Uninstall by ID with machine scope..." -Tag "Debug"
    & $wingetPath uninstall -e --id $wingetAppID --silent --scope machine --accept-source-agreements --force
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        Write-Log "Uninstallation completed successfully" -Tag "Success"
        Complete-Script -ExitCode 0
    }
    elseif ($exitCode -eq -1978335212) {
        Write-Log "Uninstall failed with exit code $($exitCode). Retrying ..." -Tag "Debug"

        # Retry without scope
        & $wingetPath uninstall -e --id $wingetAppID --silent --accept-source-agreements --force
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log "Uninstallation completed successfully." -Tag "Success"
            Complete-Script -ExitCode 0
        } else {
            Write-Log "Uninstall failed again without scope (ExitCode: $exitCode)." -Tag "Error"
            Complete-Script -ExitCode 1
        }
    }
    else {
        Write-Log "Uninstall failed with unexpected exit code $exitCode." -Tag "Error"
        Complete-Script -ExitCode 1
    }
}
catch {
    Write-Log "Uninstallation failed. Exception: $_" -Tag "Error"
    Complete-Script -ExitCode 1
}
