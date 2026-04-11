# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Configuration ]---------------------------
$applicationName  = '__APPLICATION_NAME__'
$wingetAppId      = '__WINGET_APP_ID__'
$installContext   = '__INSTALL_CONTEXT__'

# Optional: pass a string directly to the installer (e.g. "/silent /configID=XXXXX"). Leave empty for none.
# See: https://learn.microsoft.com/en-us/windows/package-manager/winget/install (--override)
# Set from apps.csv InstallOverride column when non-empty.
$installOverride  = '__INSTALL_OVERRIDE__'

$logFileName      = "install.log"

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

# ---------------------------[ Argument Escaping for Winget Override ]---------------------------
# Winget requires --override as a single argument; spaces, quotes, backslashes must be preserved.
# .NET Core/5+ ProcessStartInfo.ArgumentList handles this; .NET Framework needs manual escaping.
# Uses CommandLineToArgvW rules: \" for literal ", backslashes before " or at end doubled.
# Ref: https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/PasteArguments.cs
function Join-ArgumentsForProcess {
    param([string[]]$ArgumentList)
    $escaped = foreach ($arg in $ArgumentList) {
        $needsQuoting = $arg.Length -eq 0 -or $arg -match '[\s"]'
        if (-not $needsQuoting) {
            $arg
        } else {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.Append('"')
            $i = 0
            while ($i -lt $arg.Length) {
                $c = $arg[$i]
                $i++
                if ($c -eq [char]0x5C) {
                    $n = 1
                    while ($i -lt $arg.Length -and $arg[$i] -eq [char]0x5C) { $i++; $n++ }
                    if ($i -eq $arg.Length) {
                        [void]$sb.Append([char]0x5C, $n * 2)
                    } elseif ($arg[$i] -eq '"') {
                        [void]$sb.Append([char]0x5C, $n * 2 + 1)
                        [void]$sb.Append('"')
                        $i++
                    } else {
                        [void]$sb.Append([char]0x5C, $n)
                    }
                    continue
                }
                if ($c -eq '"') {
                    [void]$sb.Append([char]0x5C)
                    [void]$sb.Append('"')
                } else {
                    [void]$sb.Append($c)
                }
            }
            [void]$sb.Append('"')
            $sb.ToString()
        }
    }
    $escaped -join ' '
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

# ---------------------------[ Winget Exit Code Helper ]---------------------------
# Reference: https://kb.filewave.com/books/microsoft-windows-package-manager-winget/page/troubleshooting-errors-with-winget
#
# Categories:
#   Success   - Desired state (installed or already installed). Exit 0.
#   RetryScope - No applicable installer for scope; retry without --scope. Exit 0/1 after retry.
#   RetrySource - Pinned certificate mismatch; retry with --source winget. Exit 0/1 after retry.
#   RetryLater - Transient (app in use, disk full, reboot needed, etc.). Exit 0 so Intune retries.
#   RetryBusy  - Same install should be retried after a delay (shared queue / engine busy). Mapped
#                codes use the inner wait loop ($maxInProgressRetries x $inProgressDelaySeconds); add
#                more hashtable entries here only when that backoff is appropriate.
#   Fail      - Unrecoverable (policy, unsupported, invalid param). Exit 1.
#   Unknown   - Unmapped code; log and treat as Fail.
#
# Retry engine: A loop applies workarounds based on category. Each workaround (RetryScope,
# RetrySource) is tried at most once. Workarounds chain automatically - e.g. RetrySource ->
# RetryScope produces a final attempt with --source winget and no --scope. Every winget call
# is wrapped in a RetryBusy wait loop (see $maxInProgressRetries / $inProgressDelaySeconds).
#
# Install-specific errors (0x8A150101-0x8A150114) and general errors are included so logs are clear
# and behaviour is consistent. Some codes are unlikely in silent/automated runs but are still mapped.
#
# WinGet often returns signed 32-bit HRESULTs (negative). Do not cast those directly to [uint32] for
# hex display - it throws. Reinterpret bits via BitConverter (same as Intune-WinGet-Update remediation.ps1).
function Format-WingetExitCodeHex {
    param([int]$Code)
    $u = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int32]$Code), 0)
    return ('0x{0:X8}' -f $u)
}

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

        # --- RetryBusy: wait and re-run same winget install (see inner loop in retry engine) ---
        -1978334974    = @{ Category = "RetryBusy"; Description = "Another installation in progress" }       # INSTALL_IN_PROGRESS
        -1978335226    = @{ Category = "RetryBusy"; Description = "Shell install failed" }                  # SHELLEXEC_INSTALL_FAILED
        
        # --- RetryLater: transient; exit 0 so Intune can retry ---
        -1978334975    = @{ Category = "RetryLater"; Description = "Application is currently running" }       # INSTALL_PACKAGE_IN_USE
        -1978334973    = @{ Category = "RetryLater"; Description = "One or more file is in use" }            # INSTALL_FILE_IN_USE
        -1978334971    = @{ Category = "RetryLater"; Description = "Disk full" }                             # INSTALL_DISK_FULL
        -1978334970    = @{ Category = "RetryLater"; Description = "Insufficient memory" }                    # INSTALL_INSUFFICIENT_MEMORY
        -1978334969    = @{ Category = "RetryLater"; Description = "No network connectivity" }               # INSTALL_NO_NETWORK
        -1978334967    = @{ Category = "RetryLater"; Description = "Reboot required to finish installation" } # INSTALL_REBOOT_REQUIRED_TO_FINISH
        -1978334966    = @{ Category = "RetryLater"; Description = "Reboot required then try again" }         # INSTALL_REBOOT_REQUIRED_TO_INSTALL
        -1978334959    = @{ Category = "RetryLater"; Description = "Package in use by another application" } # INSTALL_PACKAGE_IN_USE_BY_APPLICATION
        -1978335125    = @{ Category = "RetryLater"; Description = "Service busy or unavailable" }            # SERVICE_UNAVAILABLE (general)

        # --- RetryScope: some packages are not found when --scope is specified ---
        -1978335212    = @{ Category = "RetryScope"; Description = "No packages found" }                         # NO_APPLICATIONS_FOUND
        -1978335217    = @{ Category = "RetryScope"; Description = "No applicable installer" }                     # NO_APPLICABLE_INSTALLER (general)
        
        # --- Fail: unrecoverable without admin or script change ---
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
    $hex = Format-WingetExitCodeHex -Code $ExitCode
    return @{ Category = "Unknown"; Description = "Unmapped exit code $ExitCode ($hex)" }
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
# Accepts full path (system) or "winget" (user context, resolved via PATH).
function Test-WingetVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$wingetPath)

    Write-Log "WinGet check" -Tag "Debug"
    $versionOutput = & $wingetPath --version 2>&1
    $exitCode = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy = ($exitCode -eq 0)
    if (-not $isHealthy) {
        Write-Log "WinGet --version: exit $exitCode $(Format-WingetExitCodeHex $exitCode)" -Tag "Debug"
    }
    return @{ IsHealthy = $isHealthy; Version = $versionString; ExitCode = $exitCode }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "Host $env:COMPUTERNAME | $env:USERNAME | $applicationName" -Tag "Info"
Write-Log "Id $wingetAppId | Context $installContext" -Tag "Info"

# ---------------------------[ Winget Install ]---------------------------
# User context: call winget directly (available in PATH). System context: resolve path from WindowsApps.
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
        $ec = $wingetCheck.ExitCode
        Write-Log "WinGet unavailable (exit $ec $(Format-WingetExitCodeHex $ec)); retry later or repair App Installer / system context" -Tag "Error"
        Complete-Script -ExitCode 0
    }

    # ---------------------------[ Retry Engine ]---------------------------
    # Workaround flags - each is applied at most once. The engine loops until success or
    # no more workarounds remain. Every winget invocation is wrapped in the RetryBusy wait loop
    # (codes mapped as RetryBusy in Get-WingetExitCodeInfo).
    $defaultScope      = if ($isUserContext) { 'user' } else { 'machine' }
    $useScope          = $true
    $useSource         = $false
    $triedNoScope      = $false
    $triedSource       = $false

    # Used only for Category RetryBusy (default: INSTALL_IN_PROGRESS).
    $maxInProgressRetries   = 15
    $inProgressDelaySeconds = 120

    if (-not [string]::IsNullOrWhiteSpace($installOverride)) {
        Write-Log "Override: $installOverride" -Tag "Info"
    }

    while ($true) {
        $currentArgs = @('install', '-e', '--id', $wingetAppId, '--silent', '--skip-dependencies',
                         '--accept-package-agreements', '--accept-source-agreements', '--force')
        if ($useScope)  { $currentArgs += '--scope', $defaultScope }
        if ($useSource) { $currentArgs += '--source', 'winget'  }
        if (-not [string]::IsNullOrWhiteSpace($installOverride)) {
            $currentArgs += '--override'
            $currentArgs += $installOverride
        }

        $scopeLabel  = if ($useScope)  { "scope $defaultScope" } else { "no scope" }
        $sourceLabel = if ($useSource) { ", source winget" } else { "" }
        $attemptLabel = "$scopeLabel$sourceLabel"

        # --- RetryBusy: wait and re-invoke winget (category-driven; see Get-WingetExitCodeInfo) ---
        $inProgressCount = 0
        do {
            if ($inProgressCount -gt 0) {
                Write-Log "RetryBusy; wait ${inProgressDelaySeconds}s ($inProgressCount/$maxInProgressRetries)" -Tag "Info"
                Start-Sleep -Seconds $inProgressDelaySeconds
            }

            $runLabel = "Install ($attemptLabel)"
            if ($inProgressCount -gt 0) { $runLabel += " [RetryBusy $inProgressCount/$maxInProgressRetries]" }
            Write-Log "$runLabel" -Tag "Run"
            Write-Log "winget $($currentArgs -join ' ')" -Tag "Debug"

            # Use ProcessStartInfo so --override is passed as exactly one argument.
            # PowerShell's & splatting can split args with spaces; winget fails with
            # "An argument was provided that can only be used for single package".
            # Ref: https://github.com/microsoft/winget-cli/issues/1317, https://github.com/microsoft/winget-cli/issues/5240
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $wingetExe
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            if ($psi.PSObject.Properties['ArgumentList']) {
                foreach ($arg in $currentArgs) { [void]$psi.ArgumentList.Add($arg) }
            } else {
                $psi.Arguments = Join-ArgumentsForProcess -ArgumentList $currentArgs
            }
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.WaitForExit()
            $exitCode = $p.ExitCode
            $exitInfo = Get-WingetExitCodeInfo -exitCode $exitCode
            Write-Log "Exit $exitCode $(Format-WingetExitCodeHex $exitCode) | $($exitInfo.Category) | $($exitInfo.Description)" -Tag "Info"

            if ($exitInfo.Category -ne "RetryBusy") { break }

            $inProgressCount++
        } while ($inProgressCount -le $maxInProgressRetries)

        # Still RetryBusy after max waits; exit 0 so Intune can retry later
        if ($exitInfo.Category -eq "RetryBusy") {
            Write-Log "RetryBusy (max waits); exit 0 for retry" -Tag "Error"
            Complete-Script -ExitCode 0
        }

        # --- Success ---
        if ($exitCode -eq 0 -or $exitInfo.Category -eq "Success") {
            if ($triedNoScope -or $triedSource) {
                Write-Log "Install OK ($attemptLabel)" -Tag "Success"
            } else {
                Write-Log "Install OK" -Tag "Success"
            }
            Complete-Script -ExitCode 0
        }

        # --- RetryLater (transient); exit 0 so Intune can retry later ---
        if ($exitInfo.Category -eq "RetryLater") {
            Write-Log "Defer: $($exitInfo.Description); exit 0" -Tag "Info"
            Complete-Script -ExitCode 0
        }

        # --- Apply known workarounds ---
        $workaroundApplied = $false

        if ($exitInfo.Category -eq "RetryScope" -and -not $triedNoScope) {
            Write-Log "Retry: no --scope" -Tag "Info"
            $useScope      = $false
            $triedNoScope  = $true
            $workaroundApplied = $true
        }

        if ($exitInfo.Category -eq "RetrySource" -and -not $triedSource) {
            Write-Log "Retry: --source winget" -Tag "Info"
            $useSource     = $true
            $triedSource   = $true
            $workaroundApplied = $true
        }

        if (-not $workaroundApplied) {
            Write-Log "No workaround: $($exitInfo.Category) $($exitInfo.Description)" -Tag "Debug"
            Write-Log "Fail: $($exitInfo.Description)" -Tag "Error"
            Complete-Script -ExitCode 1
        }

        Write-Log "Retry winget" -Tag "Debug"
    }
}
catch {
    Write-Log "Unhandled: $_" -Tag "Error"
    Write-Log "$($_.ScriptStackTrace)" -Tag "Debug"
    Complete-Script -ExitCode 1
}
