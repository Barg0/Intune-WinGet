#requires -Version 5.1
<#
    Package.ps1
    Bulk-pack Win32 (winget) apps for Intune

    Expected layout:
        .\Templates\install.ps1     (template, uses placeholders)
        .\Templates\uninstall.ps1   (template, uses placeholders)
        .\Templates\detection.ps1   (template, uses placeholders)
        .\Apps\                     (output root; created if missing)
        .\Package.ps1               (this script)
        .\apps.csv                  (ApplicationName,WingetAppId)
        .\IntuneWinAppUtil.exe      (Microsoft Win32 Content Prep Tool)

    Placeholders to use at the top of each template:
        $applicationName = "__APPLICATION_NAME__"
        $wingetAppID     = "__WINGET_APP_ID__"

    Output per app:
        Apps\<App>\
            install.ps1, uninstall.ps1, detection.ps1, <App>.intunewin
#>

#region --- Config (no parameters; tweak here) ---
$RootDir               = Split-Path -Parent $PSCommandPath
$CsvPath               = Join-Path $RootDir 'apps.csv'
$TemplatesPath         = Join-Path $RootDir 'Templates'
$OutputRoot            = Join-Path $RootDir 'Apps'
$IntuneWinAppUtilPath  = Join-Path $RootDir 'IntuneWinAppUtil.exe'

# Behavior toggles
$KeepPlainScripts      = $false  # If $false, remove ONLY install.ps1 and uninstall.ps1 (keep detection.ps1)
$Quiet                 = $true   # Pass -q to IntuneWinAppUtil.exe (overwrite quietly)
#endregion

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script name ]---------------------------
$scriptName = 'PackageApps'
$logFileName = 'log.log'

# ---------------------------[ Logging Setup ]---------------------------
$log = $true
$enableLogFile = $true
$logFileDirectory = "$PSScriptRoot"
$logFile = "$logFileDirectory\$logFileName"
if ($enableLogFile -and -not (Test-Path $logFileDirectory)) { New-Item -ItemType Directory -Path $logFileDirectory -Force | Out-Null }

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

function Complete-Script {
    param([int]$ExitCode)
    $scriptEndTime = Get-Date
    $duration = $scriptEndTime - $scriptStartTime
    Write-Log "Script execution time: $($duration.ToString("hh\:mm\:ss\.ff"))" -Tag "Info"
    Write-Log "Exit Code: $ExitCode" -Tag "Info"
    Write-Log "======== Script Completed ========" -Tag "End"
    exit $ExitCode
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"
#endregion

#region --- Helpers ---
function Assert-Path {
    param([string]$Path, [string]$Description = "Path")
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "$Description not found: $Path" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

function Get-SafeName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $regex = "[" + [Regex]::Escape($invalid) + "]"
    return ($Name -replace $regex, '_').Trim()
}

function Set-Placeholders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$TemplatePath,
        [Parameter(Mandatory)] [string]$OutputPath,
        [Parameter(Mandatory)] [string]$ApplicationName,
        [Parameter(Mandatory)] [string]$WingetAppId
    )

    $content = Get-Content -LiteralPath $TemplatePath -Raw

    # Preferred: placeholder replacement
    $content = $content.Replace('__APPLICATION_NAME__', $ApplicationName)
    $content = $content.Replace('__WINGET_APP_ID__', $WingetAppId)

    # Fallback: rewrite ONLY these two variable lines if placeholders not present
    $content = $content -replace '(?m)^\s*\$applicationName\s*=\s*.*$', "`$applicationName = `"$ApplicationName`""
    $content = $content -replace '(?m)^\s*\$wingetAppID\s*=\s*.*$', "`$wingetAppID = `"$WingetAppId`""

    # IMPORTANT: Do not touch $scriptName or $logFileName (left exactly as in templates)

    Set-Content -LiteralPath $OutputPath -Value $content -Encoding UTF8
}

function New-IntuneWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$SourceFolder,
        [Parameter(Mandatory)] [string]$SetupFile,
        [Parameter(Mandatory)] [string]$OutputFolder
    )
    $intuneArgs = @('-c', "`"$SourceFolder`"", '-s', "`"$SetupFile`"", '-o', "`"$OutputFolder`"")
    if ($Quiet) { $intuneArgs += '-q' }
    # Write-Log "Running IntuneWinAppUtil.exe $($intuneArgs -join ' ')" -Tag "Debug"
    $p = Start-Process -FilePath $IntuneWinAppUtilPath -ArgumentList $intuneArgs -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
        Write-Log "IntuneWinAppUtil exited with code $($p.ExitCode)" -Tag "Error"
        throw "Packaging failed."
    }
}
#endregion

#region --- Validate inputs & setup ---
Assert-Path -Path $IntuneWinAppUtilPath -Description 'IntuneWinAppUtil.exe'
Assert-Path -Path $CsvPath -Description 'CSV'

$tplInstall   = Join-Path $TemplatesPath 'install.ps1'
$tplUninstall = Join-Path $TemplatesPath 'uninstall.ps1'
$tplDetect    = Join-Path $TemplatesPath 'detection.ps1'

Assert-Path -Path $tplInstall   -Description 'install.ps1 template'
Assert-Path -Path $tplUninstall -Description 'uninstall.ps1 template'
Assert-Path -Path $tplDetect    -Description 'detection.ps1 template'

if (-not (Test-Path $OutputRoot)) { New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null }
#endregion

#region --- Load CSV ---
try {
    $rows = Import-Csv -LiteralPath $CsvPath -Delimiter ','
} catch {
    Write-Log "Failed to read CSV: $($_.Exception.Message)" -Tag "Error"
    Complete-Script -ExitCode 1
}
if (-not $rows -or $rows.Count -eq 0) { Write-Log 'CSV contains no rows.' -Tag 'Error'; Complete-Script -ExitCode 1 }
#endregion

#region --- Main ---
foreach ($row in $rows) {
    $appName = ($row.ApplicationName).ToString().Trim()
    $wingetId = ($row.WingetAppId).ToString().Trim()

    if ([string]::IsNullOrWhiteSpace($appName) -or [string]::IsNullOrWhiteSpace($wingetId)) {
        Write-Log 'Skipping row with missing ApplicationName or WingetAppId.' -Tag 'Error'
        continue
    }

    $safeName = Get-SafeName $appName
    $appFolder = Join-Path $OutputRoot $safeName

    # Write-Log "--- Processing: $appName ($wingetId) ---" -Tag 'Info'
    if (-not (Test-Path $appFolder)) { New-Item -ItemType Directory -Path $appFolder -Force | Out-Null }

    # Generate scripts directly in the per-app folder
    $genInstall   = Join-Path $appFolder 'install.ps1'
    $genUninstall = Join-Path $appFolder 'uninstall.ps1'
    $genDetect    = Join-Path $appFolder 'detection.ps1'

    Set-Placeholders -TemplatePath $tplInstall   -OutputPath $genInstall   -ApplicationName $appName -WingetAppId $wingetId
    Set-Placeholders -TemplatePath $tplUninstall -OutputPath $genUninstall -ApplicationName $appName -WingetAppId $wingetId
    Set-Placeholders -TemplatePath $tplDetect    -OutputPath $genDetect    -ApplicationName $appName -WingetAppId $wingetId

    # Build package (setup file = install.ps1) with output into the same app folder
    try {
        New-IntuneWinPackage -SourceFolder $appFolder -SetupFile "install.ps1" -OutputFolder $appFolder
    } catch {
        Write-Log "Packaging error for $($appName): $($_.Exception.Message)" -Tag "Error"
        continue
    }

    # Rename install.intunewin -> <App>.intunewin
    $defaultIntuneWin = Join-Path $appFolder 'install.intunewin'
    $targetIntuneWin  = Join-Path $appFolder ("{0}.intunewin" -f $safeName)
    if (Test-Path $defaultIntuneWin) {
        try {
            if (Test-Path $targetIntuneWin) { Remove-Item -LiteralPath $targetIntuneWin -Force -ErrorAction SilentlyContinue }
            Rename-Item -LiteralPath $defaultIntuneWin -NewName (Split-Path $targetIntuneWin -Leaf) -Force
        } catch {
            Write-Log "Rename failed (install.intunewin -> $safeName.intunewin): $($_.Exception.Message)" -Tag 'Error'
        }
    }

    # Optionally remove ONLY install.ps1 and uninstall.ps1 after packaging (never delete detection.ps1)
    if (-not $KeepPlainScripts) {
        foreach ($f in @($genInstall, $genUninstall)) {
            try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
            catch { Write-Log "Cleanup failed for $($f): $($_.Exception.Message)" -Tag 'Debug' }
        }
    }

    Write-Log "Packaged: $safeName" -Tag 'Success'
}
#endregion

Complete-Script -ExitCode 0