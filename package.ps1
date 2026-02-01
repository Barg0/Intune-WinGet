# ---------------------------[ Configuration ]---------------------------
$keepPlainScripts      = $true   # If $false, remove ONLY install.ps1 and uninstall.ps1 (keep detection.ps1)
$quiet                 = $true   # Pass -q to IntuneWinAppUtil.exe (overwrite quietly)
$fetchWingetShow       = $true   # Run winget show for each app and save JSON to app folder (for deploy.ps1 / Graph API)
$forceRepack           = $false  # If $true, clear each app folder and rebuild from scratch; if $false, skip apps that already have .intunewin

# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "package"
$logFileName = "$($scriptName).log"

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false   # Set to $true for verbose DEBUG logging
$logGet        = $true    # enable/disable all [Get] logs
$logRun        = $true    # enable/disable all [Run] logs
$enableLogFile = $true

$logFileDirectory = Join-Path $PSScriptRoot 'logs'
$logFile         = Join-Path $logFileDirectory $logFileName

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

# ---------------------------[ File and Folder Config ]---------------------------
$rootDir               = Split-Path -Parent $PSCommandPath
$csvPath               = Join-Path $rootDir 'apps.csv'
$templatesPath         = Join-Path $rootDir 'templates'
$outputRoot            = Join-Path $rootDir 'apps'
$intuneWinAppUtilPath  = Join-Path $rootDir 'IntuneWinAppUtil.exe'

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"
Write-Log "Config: rootDir=$rootDir | csvPath=$csvPath | outputRoot=$outputRoot" -Tag "Debug"
Write-Log "Config: keepPlainScripts=$keepPlainScripts | quiet=$quiet | logDebug=$logDebug | fetchWingetShow=$fetchWingetShow | forceRepack=$forceRepack" -Tag "Debug"

#region --- Helpers ---
function Assert-Path {
    [CmdletBinding()]
    param([string]$path, [string]$description = "Path")
    Write-Log "Assert-Path: checking path '$path' ($description)" -Tag "Debug"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "$description not found: $path" -Tag "Error"
        Complete-Script -ExitCode 1
    }
    Write-Log "Assert-Path: path exists '$path'" -Tag "Debug"
}

function Get-SafeName {
    [CmdletBinding()]
    param([string]$name)
    Write-Log "Get-SafeName: input name='$name'" -Tag "Debug"
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $regex   = "[" + [Regex]::Escape($invalid) + "]"
    $result  = ($name -replace $regex, '_').Trim()
    Write-Log "Get-SafeName: output safeName='$result'" -Tag "Debug"
    return $result
}

function Set-Placeholders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$templatePath,
        [Parameter(Mandatory)] [string]$outputPath,
        [Parameter(Mandatory)] [string]$applicationName,
        [Parameter(Mandatory)] [string]$wingetAppId
    )

    Write-Log "Set-Placeholders: templatePath='$templatePath' -> outputPath='$outputPath'" -Tag "Debug"
    Write-Log "Set-Placeholders: applicationName='$applicationName' | wingetAppId='$wingetAppId'" -Tag "Debug"

    $content = Get-Content -LiteralPath $templatePath -Raw
    Write-Log "Set-Placeholders: read template ($($content.Length) chars)" -Tag "Debug"

    # Preferred: placeholder replacement
    $content = $content.Replace('__APPLICATION_NAME__', $applicationName)
    $content = $content.Replace('__WINGET_APP_ID__', $wingetAppId)

    # Fallback: rewrite ONLY these two variable lines if placeholders not present
    $content = $content -replace '(?m)^\s*\$applicationName\s*=\s*.*$', "`$applicationName = `"$applicationName`""
    $content = $content -replace '(?m)^\s*\$wingetAppID\s*=\s*.*$', "`$wingetAppID = `"$wingetAppId`""

    Set-Content -LiteralPath $outputPath -Value $content -Encoding UTF8
    Write-Log "Set-Placeholders: wrote output file '$outputPath'" -Tag "Debug"
}

function New-IntuneWinPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$sourceFolder,
        [Parameter(Mandatory)] [string]$setupFile,
        [Parameter(Mandatory)] [string]$outputFolder
    )

    $intuneArgs = @('-c', "`"$sourceFolder`"", '-s', "`"$setupFile`"", '-o', "`"$outputFolder`"")
    if ($quiet) { $intuneArgs += '-q' }

    Write-Log "New-IntuneWinPackage: sourceFolder='$sourceFolder' | setupFile='$setupFile' | outputFolder='$outputFolder'" -Tag "Debug"
    Write-Log "New-IntuneWinPackage: IntuneWinAppUtil path='$intuneWinAppUtilPath'" -Tag "Debug"
    Write-Log "New-IntuneWinPackage: arguments: $($intuneArgs -join ' ')" -Tag "Debug"
    Write-Log "Running IntuneWinAppUtil.exe (packaging)" -Tag "Run"

    $process = Start-Process -FilePath $intuneWinAppUtilPath -ArgumentList $intuneArgs -Wait -PassThru -WindowStyle Hidden

    Write-Log "New-IntuneWinPackage: process exit code=$($process.ExitCode)" -Tag "Debug"
    if ($process.ExitCode -ne 0) {
        Write-Log "IntuneWinAppUtil exited with code $($process.ExitCode)" -Tag "Error"
        throw "Packaging failed."
    }
    Write-Log "New-IntuneWinPackage: completed successfully" -Tag "Debug"
}

function Export-WingetShowToJson {
    <#
    .SYNOPSIS
        Runs winget show for the given app id, parses output, and saves structured JSON to the app folder.
        Used by deploy.ps1 for Graph API (version, publisher, description, etc.).
    .DESCRIPTION
        Parses winget show text output generically: optional fields (Privacy Url, Author, Release Notes,
        Documentation, multiple installers, etc.) are preserved. Only metadata submitted with the app
        is shown by winget, so structure varies per package. UTF-8 encoding is used when invoking
        winget so Unicode (e.g. app names) is captured correctly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$wingetId,
        [Parameter(Mandatory)] [string]$appFolder,
        [Parameter(Mandatory)] [string]$applicationName
    )

    $jsonFileName = 'info.json'
    $jsonPath     = Join-Path $appFolder $jsonFileName

    Write-Log "Export-WingetShowToJson: wingetId='$wingetId' -> $jsonPath" -Tag "Debug"
    Write-Log "Fetching app info for $applicationName" -Tag "Get"
    Write-Log "Running winget show --id `"$wingetId`"" -Tag "Debug"

    # Set UTF-8 encoding so winget output (e.g. app names with Unicode) is captured correctly.
    # Prevents garbled characters in JSON and ensures parsing works reliably across locales.
    $previousOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    try {
        try {
            $rawOutput = & winget show --id $wingetId 2>&1 | Out-String
        } catch {
            Write-Log "winget show failed for '$wingetId': $($_.Exception.Message)" -Tag "Error"
            return
        }
    }
    finally {
        [Console]::OutputEncoding = $previousOutputEncoding
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($rawOutput)) {
        Write-Log "winget show returned no output or error for '$wingetId' (exit: $LASTEXITCODE)" -Tag "Debug"
        return
    }
    if ($rawOutput -match 'No package found|No applicable package') {
        Write-Log "winget: no package found for '$wingetId'" -Tag "Debug"
        return
    }

    $lines = $rawOutput -split "`r?`n"
    $obj   = [ordered]@{ }
    $currentKey = $null
    $currentValue = [System.Collections.ArrayList]::new()
    $currentSection = $null  # 'ReleaseNotes' | 'Tags' | 'Documentation' | 'Installer'
    $installersList = [System.Collections.ArrayList]::new()  # multiple Installer blocks

    # Normalize key for JSON: "Publisher Url" -> PublisherUrl, "Installer SHA256" -> InstallerSHA256
    $normalizeKey = { param([string]$k) ($k -replace '\s+', '').Trim() }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # First line: "Found 7-Zip [7zip.7zip]"
        if ($i -eq 0 -and $line -match 'Found\s+(.+?)\s+\[(.+?)\]') {
            $obj['Name'] = $Matches[1].Trim()
            $obj['Id']   = $Matches[2].Trim()
            continue
        }

        # Top-level "Key: Value" (line does not start with 2+ spaces)
        if ($line -match '^([A-Za-z][A-Za-z0-9\s\-]*):\s*(.*)$' -and $line -notmatch '^\s{2,}') {
            # Flush previous multi-line section (ReleaseNotes, Tags)
            if ($currentKey -and $currentValue.Count -gt 0) {
                $val = if ($currentValue.Count -eq 1) { $currentValue[0] } else { $currentValue.ToArray() }
                $obj[$currentKey] = $val
            }
            $key = $Matches[1].Trim() -replace '\s+', ' '
            $val = $Matches[2].Trim()
            $currentKey = $null
            $currentValue = [System.Collections.ArrayList]::new()

            if ($key -eq 'Release Notes') {
                $currentKey = 'ReleaseNotes'
                $currentSection = 'ReleaseNotes'
                if ($val) { [void]$currentValue.Add($val) }
            } elseif ($key -eq 'Tags') {
                $currentKey = 'Tags'
                $currentSection = 'Tags'
                if ($val) { [void]$currentValue.Add($val) }
            } elseif ($key -eq 'Documentation') {
                $currentSection = 'Documentation'
                if (-not $obj['Documentation']) { $obj['Documentation'] = [ordered]@{ } }
            } elseif ($key -match '^Installer(\s+\d+)?$') {
                # "Installer" or "Installer 1", "Installer 2" -> support multiple installers
                $currentSection = 'Installer'
                $singleInstaller = [ordered]@{ }
                if ($obj['Installer'] -is [System.Collections.Specialized.OrderedDictionary]) {
                    [void]$installersList.Add($obj['Installer'])
                    $obj.Remove('Installer')
                }
                [void]$installersList.Add($singleInstaller)
                $obj['Installer'] = $singleInstaller
            } else {
                # Any other top-level key (Version, Publisher, Author, Privacy Url, Copyright, etc.)
                $currentSection = $null
                $normKey = & $normalizeKey $key
                if ($normKey -and ($val -or $val -eq '')) { $obj[$normKey] = $val }
            }
            continue
        }

        # Indented "SubKey: Value" (under Documentation or Installer, or tag line under Tags)
        if ($line -match '^\s{2,}([^:]+):\s*(.*)$') {
            $subKey = & $normalizeKey $Matches[1].Trim()
            $subVal = $Matches[2].Trim()

            if ($currentSection -eq 'Documentation' -and $obj['Documentation'] -is [System.Collections.Specialized.OrderedDictionary]) {
                $obj['Documentation'][$subKey] = $subVal
            } elseif ($currentSection -eq 'Installer' -and $obj['Installer'] -is [System.Collections.Specialized.OrderedDictionary]) {
                $obj['Installer'][$subKey] = $subVal
            } elseif ($currentSection -eq 'ReleaseNotes') {
                [void]$currentValue.Add($line.Trim())
            } elseif ($currentSection -eq 'Tags') {
                [void]$currentValue.Add($subKey)
            }
            continue
        }

        # Indented continuation line (no colon) under Release Notes or Tags
        if ($line -match '^\s{2,}(.+)$' -and $currentSection -in 'ReleaseNotes','Tags') {
            [void]$currentValue.Add($Matches[1].Trim())
        }
    }

    if ($currentKey -and $currentValue.Count -gt 0) {
        $val = if ($currentValue.Count -eq 1) { $currentValue[0] } else { $currentValue.ToArray() }
        $obj[$currentKey] = $val
    }

    # Multiple installers: expose as Installers array; keep Installer as first for backward compatibility
    if ($installersList.Count -gt 1) {
        $obj['Installers'] = @($installersList.ToArray())
        $obj['Installer'] = $installersList[0]
    }

    if (-not $obj['Id'] -and $wingetId) { $obj['Id'] = $wingetId }
    $obj['Name']     = $applicationName   # From CSV (display name for deploy/Graph API)
    $obj['WingetId'] = $wingetId
    $obj['FetchedAt'] = (Get-Date -Format 'o')

    $jsonContent = $obj | ConvertTo-Json -Depth 10 -Compress:$false
    try {
        Set-Content -LiteralPath $jsonPath -Value $jsonContent -Encoding UTF8
        $shortPath = (Split-Path $appFolder -Leaf) + "\" + $jsonFileName
        Write-Log "Saved winget metadata to $shortPath" -Tag "Info"
    } catch {
        Write-Log "Failed to write $jsonPath : $($_.Exception.Message)" -Tag "Error"
    }
}
#endregion

#region --- Validate inputs & setup ---
Write-Log "Validating required paths..." -Tag "Debug"
Assert-Path -path $intuneWinAppUtilPath -description 'IntuneWinAppUtil.exe'
Assert-Path -path $csvPath -description 'CSV'

$tplInstall   = Join-Path $templatesPath 'install.ps1'
$tplUninstall = Join-Path $templatesPath 'uninstall.ps1'
$tplDetect    = Join-Path $templatesPath 'detection.ps1'

Write-Log "Template paths: install='$tplInstall' | uninstall='$tplUninstall' | detect='$tplDetect'" -Tag "Debug"
Assert-Path -path $tplInstall   -description 'install.ps1 template'
Assert-Path -path $tplUninstall -description 'uninstall.ps1 template'
Assert-Path -path $tplDetect    -description 'detection.ps1 template'

if (-not (Test-Path $outputRoot)) {
    Write-Log "Creating output root directory: $outputRoot" -Tag "Debug"
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
} else {
    Write-Log "Output root already exists: $outputRoot" -Tag "Debug"
}
#endregion

#region --- Load CSV ---
Write-Log "Loading CSV from: $csvPath" -Tag "Get"
try {
    $rows = Import-Csv -LiteralPath $csvPath -Delimiter ','
    Write-Log "CSV loaded: $($rows.Count) row(s)" -Tag "Debug"
} catch {
    Write-Log "Failed to read CSV: $($_.Exception.Message)" -Tag "Error"
    Complete-Script -ExitCode 1
}
if (-not $rows -or $rows.Count -eq 0) {
    Write-Log 'CSV contains no rows.' -Tag 'Error'
    Complete-Script -ExitCode 1
}
Write-Log "Processing $($rows.Count) app(s) from CSV" -Tag "Info"
#endregion

#region --- Main ---
$rowIndex = 0
foreach ($row in $rows) {
    $rowIndex++
    $appName   = ($row.ApplicationName).ToString().Trim()
    $wingetId  = ($row.WingetAppId).ToString().Trim()

    Write-Log "Row $rowIndex : appName='$appName' | wingetId='$wingetId'" -Tag "Debug"

    if ([string]::IsNullOrWhiteSpace($appName) -or [string]::IsNullOrWhiteSpace($wingetId)) {
        Write-Log 'Skipping row with missing ApplicationName or WingetAppId.' -Tag 'Error'
        continue
    }

    $safeName   = Get-SafeName $appName
    $appFolder  = Join-Path $outputRoot $safeName

    Write-Log "Processing: $appName ($wingetId)" -Tag "Info"
    Write-Log "Ensuring app folder exists: $appFolder" -Tag "Debug"

    if ($forceRepack -and (Test-Path $appFolder)) {
        Write-Log "Force repack: clearing app folder $safeName" -Tag "Info"
        Get-ChildItem -LiteralPath $appFolder -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $appFolder)) {
        New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
        Write-Log "Created app folder: $appFolder" -Tag "Debug"
    }

    $targetIntuneWin = Join-Path $appFolder ("{0}.intunewin" -f $safeName)
    if (-not $forceRepack -and (Test-Path $targetIntuneWin)) {
        Write-Log "Skipped (already packed): $safeName" -Tag "Info"
        continue
    }

    if ($fetchWingetShow) {
        Export-WingetShowToJson -wingetId $wingetId -appFolder $appFolder -applicationName $appName
    }

    # When keepPlainScripts: put install/uninstall under apps\$appName\scripts\; detection.ps1 stays in app root.
    if ($keepPlainScripts) {
        $scriptsDir = Join-Path $appFolder 'scripts'
        if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
        $genInstall   = Join-Path $scriptsDir 'install.ps1'
        $genUninstall = Join-Path $scriptsDir 'uninstall.ps1'
    } else {
        $genInstall   = Join-Path $appFolder 'install.ps1'
        $genUninstall = Join-Path $appFolder 'uninstall.ps1'
    }
    $genDetect = Join-Path $appFolder 'detection.ps1'

    Write-Log "Generated script paths: install=$genInstall | uninstall=$genUninstall | detect=$genDetect" -Tag "Debug"

    Set-Placeholders -templatePath $tplInstall   -outputPath $genInstall   -applicationName $appName -wingetAppId $wingetId
    Set-Placeholders -templatePath $tplUninstall -outputPath $genUninstall -applicationName $appName -wingetAppId $wingetId
    Set-Placeholders -templatePath $tplDetect    -outputPath $genDetect    -applicationName $appName -wingetAppId $wingetId

    # Package only install.ps1 and uninstall.ps1 in apps\temp; then move .intunewin to app folder and delete temp.
    $tempRoot   = Join-Path $outputRoot 'temp'
    $packTemp   = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
    if (-not (Test-Path $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }
    try {
        New-Item -ItemType Directory -Path $packTemp -Force | Out-Null
        Copy-Item -LiteralPath $genInstall -Destination (Join-Path $packTemp 'install.ps1') -Force
        Copy-Item -LiteralPath $genUninstall -Destination (Join-Path $packTemp 'uninstall.ps1') -Force
        Write-Log "Starting Intune package build for: $safeName (pack in temp, install.ps1 + uninstall.ps1 only)" -Tag "Debug"
        try {
            New-IntuneWinPackage -sourceFolder $packTemp -setupFile "install.ps1" -outputFolder $packTemp
        } catch {
            Write-Log "Packaging error for $($appName): $($_.Exception.Message)" -Tag "Error"
            continue
        }
        $defaultIntuneWin = Join-Path $packTemp 'install.intunewin'
        if (Test-Path $defaultIntuneWin) {
            if (Test-Path $targetIntuneWin) { Remove-Item -LiteralPath $targetIntuneWin -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $defaultIntuneWin -Destination $targetIntuneWin -Force
            Write-Log "Moved .intunewin to app folder; removing temp" -Tag "Debug"
        } else {
            Write-Log "Expected file not found after packaging: $defaultIntuneWin" -Tag "Debug"
        }
    }
    finally {
        if (Test-Path $packTemp) {
            Remove-Item -LiteralPath $packTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $keepPlainScripts) {
        Write-Log "Cleanup: removing plain scripts (keepPlainScripts=$keepPlainScripts)" -Tag "Debug"
        foreach ($filePath in @($genInstall, $genUninstall)) {
            try {
                Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
                Write-Log "Removed: $filePath" -Tag "Debug"
            } catch {
                Write-Log "Cleanup failed for $($filePath): $($_.Exception.Message)" -Tag "Debug"
            }
        }
    } else {
        Write-Log "Keeping plain scripts (keepPlainScripts=$keepPlainScripts)" -Tag "Debug"
    }

    Write-Log "Packaged: $safeName" -Tag 'Success'
}
#endregion

Write-Log "All apps processed. Exiting successfully." -Tag "Debug"
Complete-Script -ExitCode 0
