# Script version: 2025-08-10 13:45
# Script author: Barg0

# ---------------------------[ Script Start Timestamp ]---------------------------

# Capture start time to log script duration
$scriptStartTime = Get-Date

# ---------------------------[ Winget App ID ]---------------------------

# Define the Winget App ID
$applicationName = "__APPLICATION_NAME__"
$wingetAppID     = "__WINGET_APP_ID__"

# ---------------------------[ Log name ]---------------------------

$logFileName = "detection.log"

# ---------------------------[ Logging Setup ]---------------------------

# Logging control switches
$log = $true                     # Set to $false to disable logging in shell
$enableLogFile = $true           # Set to $false to disable file output

# Define the log output location
$logFileDirectory = "$env:ProgramData\IntuneLogs\Applications\$($env:USERNAME)\$applicationName"
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
    Write-Log "======== Detection Script Completed ========" -Tag "End"
    exit $ExitCode
}

# ---------------------------[ Winget Path Resolver ]---------------------------

function Test-Winget {
    # Write-Log "Checking Winget version" -Tag "Debug"
    $wingetPath = "winget"
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

Write-Log "======== Detection Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Application: $applicationName" -Tag "Info"
Write-Log "Winget App ID: $wingetAppID" -Tag "Info"

# ---------------------------[ Winget version check ]---------------------------

if (-not (Test-Winget)) {
    Write-Log "Winget not working correctly. Proceeding to repair." -Tag "Info"

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

# ---------------------------[ App detection ]---------------------------

# Run Winget list to check if app is installed
# Write-Log "Running Winget list to check if $applicationName is installed..." -Tag "Check"

try {
    $wingetPath = "winget"
    $installedOutput = & $wingetPath list -e --id $wingetAppID --accept-source-agreements
    $wingetExitCode = $LASTEXITCODE

    if ($wingetExitCode -eq -1978335212 -and $installedOutput -match 'No installed package found matching input criteria.') {
        Write-Log "App NOT detected - $applicationName is NOT installed." -Tag "Error"
        Complete-Script -ExitCode 1
    }
    elseif ($wingetExitCode -ne 0) {
        Write-Log "Winget execution failed with exit code: $wingetExitCode" -Tag "Error"
        Complete-Script -ExitCode 1
    }
    else {
        Write-Log "App detected - $applicationName IS installed." -Tag "Success"
        Complete-Script -ExitCode 0
    }
} catch {
    Write-Log "Exception occurred during Winget detection: $_" -Tag "Error"
    Complete-Script -ExitCode 1

}


