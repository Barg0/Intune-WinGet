# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Winget"
$logFileName = "detection.log"

# ---------------------------[ Configuration ]---------------------------
$minimumRequiredVersion = [Version]"1.12.470"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

$logFileDirectory = "$env:ProgramData\IntuneLogs\Scripts\$scriptName"
$logFile          = "$logFileDirectory\$logFileName"

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null
}

# ---------------------------[ Logging Function ]---------------------------
function Write-Log {
    [CmdletBinding()]
    param (
        [string]$Message,
        [string]$Tag = "Info"
    )

    if (-not $log) { return }

    if (($Tag -eq "Debug") -and (-not $logDebug)) { return }
    if (($Tag -eq "Get")   -and (-not $logGet))   { return }
    if (($Tag -eq "Run")   -and (-not $logRun))   { return }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tagList   = @("Start","Get","Run","Info","Success","Error","Debug","End")
    $rawTag    = $Tag.Trim()

    if ($tagList -contains $rawTag) {
        $rawTag = $rawTag.PadRight(7)
    }
    else {
        $rawTag = "Error  "
    }

    $color = switch ($rawTag.Trim()) {
        "Start"   { "Cyan" }
        "Get"     { "Blue" }
        "Run"     { "Magenta" }
        "Info"    { "Yellow" }
        "Success" { "Green" }
        "Error"   { "Red" }
        "Debug"   { "DarkYellow" }
        "End"     { "Cyan" }
        default   { "White" }
    }

    $logMessage = "$timestamp [  $rawTag ] $Message"

    if ($enableLogFile) {
        try {
            Add-Content -Path $logFile -Value $logMessage -Encoding UTF8
        }
        catch {
            # Logging must never block script execution
        }
    }

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
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Script execution time: $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit Code: $ExitCode" -Tag "Info"
    Write-Log "======== Script Completed ========" -Tag "End"

    exit $ExitCode
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"
Write-Log "Minimum required version: $minimumRequiredVersion" -Tag "Info"

# ---------------------------[ Winget Path Resolver ]---------------------------
function Get-WingetPath {
    $wingetBase = "$env:ProgramW6432\WindowsApps"
    Write-Log "Resolving winget path from: $wingetBase" -Tag "Debug"

    try {
        $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
            Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' }
        Write-Log "x64 DesktopAppInstaller folders found: $($wingetFolders.Count)" -Tag "Debug"

        if (-not $wingetFolders) {
            $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
                Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_arm64__8wekyb3d8bbwe' }
            Write-Log "arm64 DesktopAppInstaller folders found: $($wingetFolders.Count)" -Tag "Debug"
        }

        if (-not $wingetFolders) {
            Write-Log "No matching winget installation folders found (x64 or arm64)" -Tag "Debug"
            return $null
        }

        $latestWingetFolder = $wingetFolders |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
        Write-Log "Selected folder: $($latestWingetFolder.FullName)" -Tag "Debug"

        $resolvedPath = Join-Path $latestWingetFolder.FullName 'winget.exe'

        if (-not (Test-Path $resolvedPath)) {
            Write-Log "winget.exe not found at expected location: $resolvedPath" -Tag "Debug"
            return $null
        }

        Write-Log "Winget executable path: $resolvedPath" -Tag "Debug"
        return $resolvedPath
    }
    catch {
        Write-Log "Failed to resolve winget path: $_" -Tag "Error"
        Write-Log "Exception type: $($_.Exception.GetType().FullName)" -Tag "Debug"
        return $null
    }
}

# ---------------------------[ Winget Version Check ]---------------------------
function Test-WingetVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WingetPath)

    Write-Log "Testing winget version at: $WingetPath" -Tag "Debug"

    $versionOutput = & $WingetPath --version 2>&1
    $exitCode      = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy     = ($exitCode -eq 0)

    Write-Log "Winget --version exit code: $exitCode | output: '$versionString' | healthy: $isHealthy" -Tag "Debug"

    return @{
        IsHealthy = $isHealthy
        Version   = $versionString
        ExitCode  = $exitCode
    }
}

# ---------------------------[ Main Logic ]---------------------------
$wingetPath = Get-WingetPath

if ($null -eq $wingetPath) {
    Write-Log "Winget not found on this device" -Tag "Error"
    Complete-Script -ExitCode 1
}

$versionInfo = Test-WingetVersion -WingetPath $wingetPath

if (-not $versionInfo.IsHealthy) {
    Write-Log "Winget found but broken in SYSTEM context (exit code: $($versionInfo.ExitCode))" -Tag "Error"
    Complete-Script -ExitCode 1
}

try {
    $installedVersion = [Version]($versionInfo.Version -replace '^v|-.+$', '')
    Write-Log "Installed winget version: $installedVersion" -Tag "Info"
}
catch {
    Write-Log "Failed to parse winget version string: '$($versionInfo.Version)'" -Tag "Error"
    Complete-Script -ExitCode 1
}

if ($installedVersion -ge $minimumRequiredVersion) {
    Write-Host "Winget $installedVersion detected"
    Write-Log "Version $installedVersion meets minimum requirement ($minimumRequiredVersion)" -Tag "Success"
    Complete-Script -ExitCode 0
}
else {
    Write-Log "Version $installedVersion is below minimum $minimumRequiredVersion" -Tag "Info"
    Complete-Script -ExitCode 1
}
