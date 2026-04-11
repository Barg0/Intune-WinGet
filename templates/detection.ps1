# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName  = '__APPLICATION_NAME__'
$wingetAppId      = '__WINGET_APP_ID__'
$installContext   = '__INSTALL_CONTEXT__'

$logFileName      = "detection.log"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

if ($installContext -eq 'user') {
    $logFileDirectory = "$env:ProgramData\IntuneLogs\Applications\$($env:USERNAME)\$applicationName"
} else {
    $logFileDirectory = "$env:ProgramData\IntuneLogs\Applications\$applicationName"
}
$logFile          = "$logFileDirectory\$logFileName"

if ($enableLogFile -and -not (Test-Path -Path $logFileDirectory)) {
    try {
        $null = New-Item -ItemType Directory -Path $logFileDirectory -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to create log directory '$logFileDirectory': $($_.Exception.Message)"
    }
}

# Logging aligned with https://github.com/Barg0/Intune-WinGet-Update (compact line, I/O warnings).
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
    $tagList   = @("Start", "Get", "Run", "Info", "Success", "Error", "Debug", "End")
    $rawTag    = $Tag.Trim()

    if ($tagList -contains $rawTag) {
        $rawTag = $rawTag.PadRight(7)
    }
    else {
        $rawTag = "Error "
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

    $logMessage = "$timestamp [ $rawTag ] $Message"

    if ($enableLogFile) {
        try {
            Add-Content -Path $logFile -Value $logMessage -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to write to log file: $($_.Exception.Message)"
        }
    }

    Write-Host "$timestamp " -NoNewline
    Write-Host "[ " -NoNewline -ForegroundColor White
    Write-Host "$rawTag" -NoNewline -ForegroundColor $color
    Write-Host " ] " -NoNewline -ForegroundColor White
    Write-Host "$Message"
}

# ---------------------------[ Exit Function ]---------------------------
function Complete-Script {
    param([int]$ExitCode)

    $scriptEndTime = Get-Date
    $duration      = $scriptEndTime - $scriptStartTime

    Write-Log "Runtime $($duration.ToString('hh\:mm\:ss\.ff'))" -Tag "Info"
    Write-Log "Exit $ExitCode" -Tag "Info"
    Write-Log "==================== End ====================" -Tag "End"

    exit $ExitCode
}

# ---------------------------[ Winget Path Resolver ]---------------------------
function Get-WingetPath {
    $wingetBase = "$env:ProgramW6432\WindowsApps"
    Write-Log "WinGet path: resolve" -Tag "Debug"
    try {
        $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
            Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe' }

        if (-not $wingetFolders) {
            $wingetFolders = Get-ChildItem -Path $wingetBase -Directory -ErrorAction Stop |
                Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_arm64__8wekyb3d8bbwe' }
        }

        if (-not $wingetFolders) {
            throw "No DesktopAppInstaller folder (x64/arm64)."
        }

        $latestWingetFolder = $wingetFolders |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        $resolvedPath = Join-Path $latestWingetFolder.FullName 'winget.exe'

        if (-not (Test-Path $resolvedPath)) {
            throw "winget.exe missing under $($latestWingetFolder.FullName)"
        }
        Write-Log "WinGet path: $resolvedPath" -Tag "Debug"
        return $resolvedPath
    }
    catch {
        Write-Log "WinGet path: $_" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

# ---------------------------[ Winget Version Check ]---------------------------
# If version check fails we exit 0 so Intune does not flag the app as failed and can retry after reboot.
function Test-WingetVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$wingetPath)

    Write-Log "WinGet check" -Tag "Debug"
    $versionOutput = & $wingetPath --version 2>&1
    $exitCode = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy = ($exitCode -eq 0)
    if (-not $isHealthy) {
        Write-Log "WinGet --version: exit $exitCode" -Tag "Debug"
    }
    return @{ IsHealthy = $isHealthy; Version = $versionString; ExitCode = $exitCode }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "Host $env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"
Write-Log "Id $wingetAppId | Context $installContext" -Tag "Info"

# ---------------------------[ App Detection ]---------------------------
# WinGet list: exit 0 = package found; -1978335212 (NO_APPLICATIONS_FOUND) = not installed
$isUserContext = ($installContext -eq 'user')
$wingetExe = if ($isUserContext) { 'winget' } else { (Get-WingetPath) }
if (-not $isUserContext) { Write-Log "WinGet path OK (system)" -Tag "Debug" }

try {
    $wingetCheck = Test-WingetVersion -wingetPath $wingetExe
    if ($wingetCheck.IsHealthy) {
        $verLine = $wingetCheck.Version -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1
        if ($verLine -match '(\d+\.\d+(?:\.\d+)?(?:\.\d+)?)') {
            Write-Log "WinGet: v$($matches[1])" -Tag "Success"
        }
        else {
            Write-Log "WinGet OK" -Tag "Success"
        }
    }
    if (-not $wingetCheck.IsHealthy) {
        Write-Log "WinGet unavailable (exit $($wingetCheck.ExitCode)); retry later or repair App Installer / system context" -Tag "Error"
        Complete-Script -ExitCode 0
    }

    Write-Log "List: $wingetAppId" -Tag "Run"
    Write-Log "winget list -e --id ..." -Tag "Debug"

    # Set UTF-8 encoding so winget output (e.g. app names with Unicode) is captured correctly.
    # Prevents garbled characters in Debug logs and ensures -match works reliably.
    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    try {
        $installedOutput = & $wingetExe list -e --id $wingetAppId --accept-source-agreements
        $wingetExitCode  = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousOutputEncoding
    }

    Write-Log "List exit: $wingetExitCode" -Tag "Debug"
    if ($logDebug) {
        $outStr = ($installedOutput | Out-String).Trim()
        if ($outStr.Length -gt 0) {
            $snippet = $outStr.Substring(0, [Math]::Min(500, $outStr.Length))
            Write-Log "List output (500): $snippet" -Tag "Debug"
        }
    }

    if ($wingetExitCode -eq -1978335212 -and $installedOutput -match 'No installed package found matching input criteria.') {
        Write-Log "List: not installed (-1978335212)" -Tag "Debug"
        Write-Log "Detect: not installed" -Tag "Info"
        Complete-Script -ExitCode 1
    }

    if ($wingetExitCode -ne 0) {
        Write-Log "List failed: exit $wingetExitCode" -Tag "Error"
        Write-Log "$($installedOutput | Out-String)" -Tag "Debug"
        Complete-Script -ExitCode 1
    }

    Write-Log "Detect: installed" -Tag "Success"
    Complete-Script -ExitCode 0
}
catch {
    Write-Log "Unhandled: $_" -Tag "Error"
    Write-Log "$($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}
