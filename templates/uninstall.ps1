# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName  = '__APPLICATION_NAME__'
$wingetAppId      = '__WINGET_APP_ID__'
$installContext   = '__INSTALL_CONTEXT__'

$logFileName      = "uninstall.log"

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

# ---------------------------[ Winget Uninstall Exit Code Helper ]---------------------------
# Reference: https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget
function Get-WingetUninstallExitCodeInfo {
    [CmdletBinding()]
    param([int]$ExitCode)

    $codeMap = @{
        0              = @{ Category = "Success"; Description = "Success" }
        -1978335212    = @{ Category = "Success"; Description = "No packages found (already uninstalled)" }  # NO_APPLICATIONS_FOUND
        -1978335130    = @{ Category = "Fail";    Description = "One or more applications failed to uninstall" }  # MULTIPLE_UNINSTALL_FAILED
        -1978335183    = @{ Category = "Fail";    Description = "Running uninstall command failed" }  # EXEC_UNINSTALL_COMMAND_FAILED
    }

    if ($codeMap.ContainsKey($ExitCode)) {
        return $codeMap[$ExitCode]
    }
    return @{ Category = "Unknown"; Description = "Exit code $ExitCode" }
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

# ---------------------------[ Winget Uninstall ]---------------------------
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

    # Match install script: if install fell back to no-scope, uninstall must also try no-scope
    # before treating "no packages found" as success.
    $defaultScope = if ($isUserContext) { 'user' } else { 'machine' }
    $triedNoScope = $false

    while ($true) {
        $useScope = -not $triedNoScope
        $scopeLabel = if ($useScope) { "scope $defaultScope" } else { "no scope" }

        Write-Log "Uninstall ($scopeLabel)" -Tag "Run"
        $uninstallArgs = @('uninstall', '-e', '--id', $wingetAppId, '--silent', '--accept-source-agreements', '--force')
        if ($useScope) { $uninstallArgs += '--scope', $defaultScope }
        Write-Log "winget $($uninstallArgs -join ' ')" -Tag "Debug"

        & $wingetExe @uninstallArgs
        $exitCode = $LASTEXITCODE
        $exitInfo = Get-WingetUninstallExitCodeInfo -exitCode $exitCode
        Write-Log "Exit $exitCode | $($exitInfo.Category) | $($exitInfo.Description)" -Tag "Info"

        if ($exitCode -eq 0) {
            if ($triedNoScope) {
                Write-Log "Uninstall OK (no scope)" -Tag "Success"
            }
            else {
                Write-Log "Uninstall OK" -Tag "Success"
            }
            Complete-Script -ExitCode 0
        }

        # -1978335212 = NO_APPLICATIONS_FOUND. If we tried with scope first, the app may have been
        # installed without scope (install workaround). Retry without scope before treating as success.
        if ($exitCode -eq -1978335212 -and -not $triedNoScope) {
            Write-Log "Retry: no --scope (not found for scope)" -Tag "Info"
            $triedNoScope = $true
            continue
        }

        if ($exitCode -eq -1978335212) {
            Write-Log "Uninstall OK (nothing to remove)" -Tag "Success"
            Complete-Script -ExitCode 0
        }

        # Other failure - retry without scope once (same as install fallback)
        if (-not $triedNoScope) {
            Write-Log "Retry: no --scope (fail for scope)" -Tag "Info"
            $triedNoScope = $true
            continue
        }

        Write-Log "Fail: $($exitInfo.Description)" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}
catch {
    Write-Log "Unhandled: $_" -Tag "Error"
    Write-Log "$($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}
