# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName  = "__APPLICATION_NAME__"
$wingetAppId      = "__WINGET_APP_ID__"
$installContext   = "__INSTALL_CONTEXT__"

$logFileName      = "uninstall.log"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

$logFileDirectory = "$env:ProgramData\IntuneLogs\Applications\$applicationName"
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

    # Per-tag switches
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
    Write-Log "======== Uninstall Script Completed ========" -Tag "End"

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
    Write-Log "Resolving Winget path from: $wingetBase" -Tag "Debug"
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
            throw "No matching Winget installation folders found (x64 or arm64)."
        }

        $latestWingetFolder = $wingetFolders |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
        Write-Log "Selected folder: $($latestWingetFolder.FullName)" -Tag "Debug"

        $resolvedPath = Join-Path $latestWingetFolder.FullName 'winget.exe'

        if (-not (Test-Path $resolvedPath)) {
            throw "winget.exe not found at expected location."
        }
        Write-Log "Winget executable path: $resolvedPath" -Tag "Debug"

        return $resolvedPath
    }
    catch {
        Write-Log "Failed to resolve Winget path: $_" -Tag "Error"
        Write-Log "Exception type: $($_.Exception.GetType().FullName)" -Tag "Debug"
        Complete-Script -ExitCode 1
    }
}

# ---------------------------[ Winget Version Check ]---------------------------
# If version check fails we exit 0 so Intune does not flag the app as failed and can retry after reboot.
function Test-WingetVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$wingetPath)

    $versionOutput = & $wingetPath --version 2>&1
    $exitCode = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy = ($exitCode -eq 0)
    Write-Log "Winget --version exit code: $exitCode; output length: $($versionString.Length)" -Tag "Debug"
    return @{ IsHealthy = $isHealthy; Version = $versionString; ExitCode = $exitCode }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Uninstall Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Application: $applicationName" -Tag "Info"
Write-Log "Winget App ID: $wingetAppId | Install context: $installContext" -Tag "Info"

# ---------------------------[ Winget Uninstall ]---------------------------
$isUserContext = ($installContext -eq 'user')
$wingetExe = if ($isUserContext) { 'winget' } else { (Get-WingetPath) }
if (-not $isUserContext) { Write-Log "Resolved Winget path (system context)." -Tag "Get" }

try {
    Write-Log "Entering uninstall try block. wingetAppId=$wingetAppId | context=$installContext" -Tag "Debug"
    $wingetCheck = Test-WingetVersion -wingetPath $wingetExe
    Write-Log "Winget version: $($wingetCheck.Version)" -Tag "Info"
    if (-not $wingetCheck.IsHealthy) {
        Write-Log "Winget version check failed. Restart your computer so Intune can retry, or run the Winget repair script (e.g. Winget - System Context)." -Tag "Error"
        Write-Log "Exit code from winget --version: $($wingetCheck.ExitCode)" -Tag "Debug"
        Complete-Script -ExitCode 0
    }
    Write-Log "Winget version check passed." -Tag "Debug"

    # Match install script: if install fell back to no-scope, uninstall must also try no-scope
    # before treating "no packages found" as success.
    $defaultScope = if ($isUserContext) { 'user' } else { 'machine' }
    $triedNoScope = $false

    while ($true) {
        $useScope = -not $triedNoScope
        $scopeLabel = if ($useScope) { "scope $defaultScope" } else { "no scope" }

        Write-Log "Uninstalling with $scopeLabel." -Tag "Run"
        $uninstallArgs = @('uninstall', '-e', '--id', $wingetAppId, '--silent', '--accept-source-agreements', '--force')
        if ($useScope) { $uninstallArgs += '--scope', $defaultScope }
        Write-Log "Invoking: winget $($uninstallArgs -join ' ')" -Tag "Debug"

        & $wingetExe @uninstallArgs
        $exitCode = $LASTEXITCODE
        $exitInfo = Get-WingetUninstallExitCodeInfo -exitCode $exitCode
        Write-Log "Winget uninstall ($scopeLabel) exit code: $exitCode ($($exitInfo.Description)); Category=$($exitInfo.Category)" -Tag "Info"

        if ($exitCode -eq 0) {
            $msg = if ($triedNoScope) { "Uninstallation completed successfully after retry (no scope)." } else { "Uninstallation completed successfully." }
            Write-Log $msg -Tag "Success"
            Complete-Script -ExitCode 0
        }

        # -1978335212 = NO_APPLICATIONS_FOUND. If we tried with scope first, the app may have been
        # installed without scope (install workaround). Retry without scope before treating as success.
        if ($exitCode -eq -1978335212 -and -not $triedNoScope) {
            Write-Log "No package found for scope $defaultScope; retrying without --scope (install may have used no-scope workaround)." -Tag "Info"
            $triedNoScope = $true
            continue
        }

        if ($exitCode -eq -1978335212) {
            Write-Log "No package to uninstall; treating as success." -Tag "Success"
            Complete-Script -ExitCode 0
        }

        # Other failure – retry without scope once (same as install fallback)
        if (-not $triedNoScope) {
            Write-Log "Uninstall failed for scope $defaultScope; retrying without --scope." -Tag "Info"
            $triedNoScope = $true
            continue
        }

        Write-Log "Uninstall failed: $($exitInfo.Description)" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}
catch {
    Write-Log "Uninstall failed. Exception: $_" -Tag "Error"
    Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}
