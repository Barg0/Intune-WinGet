# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName  = "__APPLICATION_NAME__"
$wingetAppID      = "__WINGET_APP_ID__"

# Optional: pass a string directly to the installer (e.g. "/silent /configID=XXXXX"). Leave empty for none.
# See: https://learn.microsoft.com/en-us/windows/package-manager/winget/install (--override)
$installOverride = ""

$logFileName      = "install.log"

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
    Write-Log "======== Install Script Completed ========" -Tag "End"

    exit $ExitCode
}

# ---------------------------[ Winget Exit Code Helper ]---------------------------
# Reference: https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget
#
# Categories:
#   Success   - Desired state (installed or already installed). Exit 0.
#   RetryScope - No applicable installer for scope; retry without --scope. Exit 0/1 after retry.
#   RetrySource - Pinned certificate mismatch; retry with --source winget. Exit 0/1 after retry.
#   RetryLater - Transient (app in use, disk full, reboot needed, etc.). Exit 0 so Intune retries.
#   Fail      - Unrecoverable (policy, unsupported, invalid param). Exit 1.
#   Unknown   - Unmapped code; log and treat as Fail.
#
# Retry engine: A loop applies workarounds based on category. Each workaround (RetryScope,
# RetrySource) is tried at most once. Workarounds chain automatically – e.g. RetrySource ->
# RetryScope produces a final attempt with --source winget and no --scope. Every winget call
# is also wrapped in an in-progress wait loop (RetryLater for -1978334974).
#
# Install-specific errors (0x8A150101–0x8A150114) and general errors are included so logs are clear
# and behaviour is consistent. Some codes are unlikely in silent/automated runs but are still mapped.
function Get-WingetExitCodeInfo {
    [CmdletBinding()]
    param([int]$ExitCode)

    $codeMap = @{
        # --- Success / treat as success ---
        0              = @{ Category = "Success"; Description = "Success" }
        -1978335135    = @{ Category = "Success"; Description = "Package already installed (general)" }      # PACKAGE_ALREADY_INSTALLED
        -1978334963    = @{ Category = "Success"; Description = "Another version already installed" }       # INSTALL_ALREADY_INSTALLED
        -1978334962    = @{ Category = "Success"; Description = "Higher version already installed" }         # INSTALL_DOWNGRADE
        -1978334965    = @{ Category = "Success"; Description = "Reboot initiated to finish installation" } # INSTALL_REBOOT_INITIATED

        # --- RetryScope: retry without machine scope ---
        -1978335216    = @{ Category = "RetryScope"; Description = "No applicable installer for scope" }      # NO_APPLICABLE_INSTALLER

        # --- RetrySource: retry with --source winget ---
        -1978335138    = @{ Category = "RetrySource"; Description = "Pinned certificate mismatch" }            # PINNED_CERTIFICATE_MISMATCH

        # --- RetryLater: transient; exit 0 so Intune can retry ---
        -1978334975    = @{ Category = "RetryLater"; Description = "Application is currently running" }       # INSTALL_PACKAGE_IN_USE
        -1978334974    = @{ Category = "RetryLater"; Description = "Another installation in progress" }       # INSTALL_IN_PROGRESS
        -1978334973    = @{ Category = "RetryLater"; Description = "One or more file is in use" }            # INSTALL_FILE_IN_USE
        -1978334971    = @{ Category = "RetryLater"; Description = "Disk full" }                             # INSTALL_DISK_FULL
        -1978334970    = @{ Category = "RetryLater"; Description = "Insufficient memory" }                    # INSTALL_INSUFFICIENT_MEMORY
        -1978334969    = @{ Category = "RetryLater"; Description = "No network connectivity" }               # INSTALL_NO_NETWORK
        -1978334967    = @{ Category = "RetryLater"; Description = "Reboot required to finish installation" } # INSTALL_REBOOT_REQUIRED_TO_FINISH
        -1978334966    = @{ Category = "RetryLater"; Description = "Reboot required then try again" }         # INSTALL_REBOOT_REQUIRED_TO_INSTALL
        -1978334959    = @{ Category = "RetryLater"; Description = "Package in use by another application" } # INSTALL_PACKAGE_IN_USE_BY_APPLICATION
        -1978335125    = @{ Category = "RetryLater"; Description = "Service busy or unavailable" }            # SERVICE_UNAVAILABLE (general)

        # --- Fail: unrecoverable without admin or script change ---
        -1978335212    = @{ Category = "Fail"; Description = "No packages found" }                             # NO_APPLICATIONS_FOUND
        -1978335217    = @{ Category = "Fail"; Description = "No applicable installer" }                     # NO_APPLICABLE_INSTALLER (general)
        -1978334972    = @{ Category = "Fail"; Description = "Missing dependency" }                          # INSTALL_MISSING_DEPENDENCY
        -1978334968    = @{ Category = "Fail"; Description = "Installation error; contact support" }         # INSTALL_CONTACT_SUPPORT
        -1978334964    = @{ Category = "Fail"; Description = "Installation cancelled by user" }            # INSTALL_CANCELLED_BY_USER
        -1978334961    = @{ Category = "Fail"; Description = "Blocked by organization policy" }              # INSTALL_BLOCKED_BY_POLICY
        -1978334960    = @{ Category = "Fail"; Description = "Failed to install dependencies" }             # INSTALL_DEPENDENCIES
        -1978334958    = @{ Category = "Fail"; Description = "Invalid parameter" }                            # INSTALL_INVALID_PARAMETER
        -1978334957    = @{ Category = "Fail"; Description = "Package not supported on this system" }        # INSTALL_SYSTEM_NOT_SUPPORTED
        -1978334956    = @{ Category = "Fail"; Description = "Installer does not support upgrade" }         # INSTALL_UPGRADE_NOT_SUPPORTED
    }

    if ($codeMap.ContainsKey($ExitCode)) {
        return $codeMap[$ExitCode]
    }
    return @{ Category = "Unknown"; Description = "Unmapped exit code $ExitCode" }
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
    param([Parameter(Mandatory)][string]$WingetPath)

    $versionOutput = & $WingetPath --version 2>&1
    $exitCode = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy = ($exitCode -eq 0)
    Write-Log "Winget --version exit code: $exitCode; output length: $($versionString.Length)" -Tag "Debug"
    return @{ IsHealthy = $isHealthy; Version = $versionString; ExitCode = $exitCode }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Install Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Application: $applicationName" -Tag "Info"
Write-Log "Winget App ID: $wingetAppID" -Tag "Info"

# ---------------------------[ Winget Install ]---------------------------
try {
    Write-Log "Entering install try block. wingetAppID=$wingetAppID" -Tag "Debug"
    $wingetPath = Get-WingetPath
    Write-Log "Resolved Winget path." -Tag "Get"

    $wingetCheck = Test-WingetVersion -WingetPath $wingetPath
    Write-Log "Winget version: $($wingetCheck.Version)" -Tag "Info"
    if (-not $wingetCheck.IsHealthy) {
        Write-Log "Winget version check failed. Restart your computer so Intune can retry, or run the Winget repair script (e.g. Winget - System Context)." -Tag "Error"
        Write-Log "Exit code from winget --version: $($wingetCheck.ExitCode)" -Tag "Debug"
        Complete-Script -ExitCode 0
    }
    Write-Log "Winget version check passed." -Tag "Debug"

    # ---------------------------[ Retry Engine ]---------------------------
    # Workaround flags – each is applied at most once. The engine loops until success or
    # no more workarounds remain. Every winget invocation is wrapped with the in-progress
    # wait loop so that "another installation in progress" is handled consistently.
    $useScope           = $true   # start with --scope machine
    $useSource          = $false  # start without --source winget
    $triedNoScope       = $false
    $triedSource        = $false

    $maxInProgressRetries   = 15
    $inProgressDelaySeconds = 120

    if ($installOverride) {
        Write-Log "Using install override: $installOverride" -Tag "Info"
    }

    while ($true) {
        # --- Build argument list for this attempt ---
        $currentArgs = @('install', '-e', '--id', $wingetAppID, '--silent', '--skip-dependencies',
                         '--accept-package-agreements', '--accept-source-agreements', '--force')
        if ($useScope)  { $currentArgs += '--scope',  'machine' }
        if ($useSource) { $currentArgs += '--source', 'winget'  }
        if ($installOverride) {
            $currentArgs += '--override'
            $currentArgs += $installOverride
        }

        $scopeLabel  = if ($useScope)  { "scope machine" } else { "no scope" }
        $sourceLabel = if ($useSource) { ", source winget" } else { "" }
        $attemptLabel = "$scopeLabel$sourceLabel"

        # --- In-progress retry loop (wraps every attempt) ---
        $inProgressCount = 0
        do {
            if ($inProgressCount -gt 0) {
                Write-Log "Another installation is in progress. Waiting $inProgressDelaySeconds seconds before retry $inProgressCount of $maxInProgressRetries..." -Tag "Info"
                Start-Sleep -Seconds $inProgressDelaySeconds
            }

            $runLabel = "Installing ($attemptLabel)"
            if ($inProgressCount -gt 0) { $runLabel += " [in-progress retry $inProgressCount/$maxInProgressRetries]" }
            Write-Log "$runLabel." -Tag "Run"
            Write-Log "Invoking: winget $($currentArgs -join ' ')" -Tag "Debug"

            & $wingetPath @currentArgs
            $exitCode = $LASTEXITCODE
            $exitInfo = Get-WingetExitCodeInfo -ExitCode $exitCode
            Write-Log "Winget exit code: $exitCode ($($exitInfo.Description)); Category=$($exitInfo.Category)" -Tag "Info"

            if ($exitCode -ne -1978334974) { break }

            $inProgressCount++
        } while ($inProgressCount -le $maxInProgressRetries)

        # Still blocked after all in-progress retries – exit 0 so Intune can retry later
        if ($exitCode -eq -1978334974) {
            Write-Log "Installation still blocked after $maxInProgressRetries retries (another installation in progress). Exiting 0 for Intune retry." -Tag "Error"
            Complete-Script -ExitCode 0
        }

        # --- Success ---
        if ($exitCode -eq 0 -or $exitInfo.Category -eq "Success") {
            if ($triedNoScope -or $triedSource) {
                Write-Log "Installation completed successfully after workaround ($attemptLabel)." -Tag "Success"
            } else {
                Write-Log "Installation completed successfully." -Tag "Success"
            }
            Complete-Script -ExitCode 0
        }

        # --- RetryLater (transient) – exit 0 so Intune can retry later ---
        if ($exitInfo.Category -eq "RetryLater") {
            Write-Log "Install blocked (retry later): $($exitInfo.Description). Exiting 0 for Intune retry." -Tag "Info"
            Complete-Script -ExitCode 0
        }

        # --- Apply known workarounds ---
        $workaroundApplied = $false

        if ($exitInfo.Category -eq "RetryScope" -and -not $triedNoScope) {
            Write-Log "No applicable installer for machine scope; retrying without --scope." -Tag "Info"
            $useScope      = $false
            $triedNoScope  = $true
            $workaroundApplied = $true
        }

        if ($exitInfo.Category -eq "RetrySource" -and -not $triedSource) {
            Write-Log "Pinned certificate mismatch detected; retrying with --source winget." -Tag "Info"
            $useSource     = $true
            $triedSource   = $true
            $workaroundApplied = $true
        }

        if (-not $workaroundApplied) {
            Write-Log "No further workarounds available for: $($exitInfo.Description) (Category=$($exitInfo.Category))" -Tag "Debug"
            Write-Log "Install failed: $($exitInfo.Description)" -Tag "Error"
            Complete-Script -ExitCode 1
        }

        Write-Log "Workaround applied; retrying..." -Tag "Debug"
    }
}
catch {
    Write-Log "Install failed. Exception: $_" -Tag "Error"
    Write-Log "Exception details: $($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}

