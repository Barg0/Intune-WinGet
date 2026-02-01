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
$logFile          = Join-Path $logFileDirectory $logFileName

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

function ConvertFrom-WingetLocalizedOutput {
    <#
    .SYNOPSIS
        Normalizes localized winget show output to English using jsons/language.json.
        Enables parsing on non-English Windows (de-DE, fr-FR, zh-CN, etc.).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$RawOutput)

    $langPath = Join-Path (Join-Path $PSScriptRoot 'jsons') 'language.json'
    if (-not (Test-Path -LiteralPath $langPath)) {
        Write-Log "ConvertFrom-WingetLocalizedOutput: language.json not found, using raw output" -Tag "Debug"
        return $RawOutput
    }

    try {
        $lang = Get-Content -LiteralPath $langPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "ConvertFrom-WingetLocalizedOutput: failed to load language.json: $($_.Exception.Message)" -Tag "Debug"
        return $RawOutput
    }

    $culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name
    $localeKey = $null
    if ($lang.locales.PSObject.Properties.Name -contains $culture) {
        $localeKey = $culture
    } elseif ($culture -match '^([a-z]{2})-') {
        $baseCulture = $Matches[1]
        $localeKey = $lang.locales.PSObject.Properties.Name | Where-Object { $_ -like "$baseCulture-*" } | Select-Object -First 1
    }

    if (-not $localeKey) {
        Write-Log "ConvertFrom-WingetLocalizedOutput: no mapping for culture '$culture', using raw output" -Tag "Debug"
        return $RawOutput
    }

    $locale = $lang.locales.$localeKey
    $result = $RawOutput

    # Check for "no package" patterns (localized)
    $noPkgPatterns = @($lang.english.noPackageSubstrings)
    if ($locale.noPackageSubstrings -and $locale.noPackageSubstrings.Count -gt 0) {
        $noPkgPatterns = @($locale.noPackageSubstrings)
    }
    foreach ($pat in $noPkgPatterns) {
        if ($result -like "*$pat*") {
            return $null  # Signal: no package found (caller should exit)
        }
    }

    # Replace localized "Found" word on first line
    $foundWord = $locale.foundWord
    if ($foundWord -and $foundWord -ne 'Found') {
        $lines = $result -split "`r?`n"
        if ($lines.Count -gt 0 -and $lines[0] -match "^$([regex]::Escape($foundWord))\s+") {
            $lines[0] = $lines[0] -replace "^$([regex]::Escape($foundWord))\s+", 'Found '
            $result = $lines -join "`n"
        }
    }

    # Replace localized labels with English (e.g. "Herausgeber:" -> "Publisher:")
    if ($locale.labels -and $locale.labels.PSObject.Properties) {
        $locale.labels.PSObject.Properties | Sort-Object { $_.Name.Length } -Descending | ForEach-Object {
            $localized = $_.Name
            $english = $_.Value
            if ($localized -and $english -and $localized -ne $english) {
                $result = $result -replace ([regex]::Escape($localized) + ':'), ($english + ':')
            }
        }
    }

    return $result
}

function Invoke-WingetShowRaw {
    param([string]$WingetId, [string]$Architecture)
    $wingetArgs = @('show', '--id', $WingetId)
    if ($Architecture) { $wingetArgs += '--architecture', $Architecture }
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    try {
        $out = & winget @wingetArgs 2>&1 | Out-String
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
}

function ConvertFrom-WingetShowOutput {
    param([string]$NormalizedOutput)
    $result = @{ Obj = [ordered]@{ }; HasInstaller = $false }
    if ([string]::IsNullOrWhiteSpace($NormalizedOutput)) { return $result }

    $lines = $NormalizedOutput -split "`r?`n"
    $obj   = [ordered]@{ }
    $currentKey = $null
    $currentValue = [System.Collections.ArrayList]::new()
    $currentSection = $null
    $installersList = [System.Collections.ArrayList]::new()
    $normalizeKey = { param([string]$k) ($k -replace '\s+', '').Trim() }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($i -eq 0 -and $line -match 'Found\s+(.+?)\s+\[(.+?)\]') {
            $obj['Name'] = $Matches[1].Trim()
            $obj['Id']   = $Matches[2].Trim()
            continue
        }
        if ($line -match '^([A-Za-z][A-Za-z0-9\s\-]*):\s*(.*)$' -and $line -notmatch '^\s{2,}') {
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
                $currentSection = 'Installer'
                $singleInstaller = [ordered]@{ }
                if ($obj['Installer'] -is [System.Collections.Specialized.OrderedDictionary]) {
                    [void]$installersList.Add($obj['Installer'])
                    $obj.Remove('Installer')
                }
                [void]$installersList.Add($singleInstaller)
                $obj['Installer'] = $singleInstaller
            } else {
                $currentSection = $null
                $normKey = & $normalizeKey $key
                if ($normKey -and ($val -or $val -eq '')) { $obj[$normKey] = $val }
            }
            continue
        }
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
        if ($line -match '^\s{2,}(.+)$' -and $currentSection -in 'ReleaseNotes','Tags') {
            [void]$currentValue.Add($Matches[1].Trim())
        }
    }

    if ($currentKey -and $currentValue.Count -gt 0) {
        $val = if ($currentValue.Count -eq 1) { $currentValue[0] } else { $currentValue.ToArray() }
        $obj[$currentKey] = $val
    }
    if ($installersList.Count -gt 1) {
        $obj['Installers'] = @($installersList.ToArray())
        $obj['Installer'] = $installersList[0]
    }
    $hasInstaller = ($obj['Installer'] -and $obj['Installer'].PSObject.Properties.Count -gt 0) -or
                    ($obj['Installers'] -and $obj['Installers'].Count -gt 0)
    return @{ Obj = $obj; HasInstaller = $hasInstaller }
}

function Export-WingetShowToJson {
    <#
    .SYNOPSIS
        Probes winget show for x86, x64, arm64; collects supported architectures; saves info.json for deploy.
    .DESCRIPTION
        Runs winget show -a x86, -a x64, -a arm64. If an Installer block is present, that arch is supported.
        Outputs Architectures: ["x86","x64"] etc. Metadata from first successful show.
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

    $architecturesToProbe = @('x86', 'x64', 'arm64')
    $supportedArches = [System.Collections.ArrayList]::new()
    $metadata = $null

    foreach ($arch in $architecturesToProbe) {
        $run = Invoke-WingetShowRaw -WingetId $wingetId -Architecture $arch
        if ($run.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($run.Output)) {
            Write-Log "winget show -a $arch returned no output (exit: $($run.ExitCode))" -Tag "Debug"
            continue
        }
        $normalized = ConvertFrom-WingetLocalizedOutput -RawOutput $run.Output
        if ($null -eq $normalized) { continue }
        if ($normalized -match 'No package found|No applicable package|No applicable installer') { continue }

        $parsed = ConvertFrom-WingetShowOutput -NormalizedOutput $normalized
        $parsed.Obj['Id'] = $wingetId

        if ($parsed.HasInstaller) {
            [void]$supportedArches.Add($arch)
            Write-Log "  $arch : has installer" -Tag "Debug"
        } else {
            Write-Log "  $arch : no installer" -Tag "Debug"
        }
        if (-not $metadata) { $metadata = $parsed.Obj }
    }

    if ($supportedArches.Count -eq 0) {
        Write-Log "winget: no installer for any architecture (x86, x64, arm64) for '$wingetId'" -Tag "Debug"
        return
    }
    if (-not $metadata) {
        Write-Log "winget: could not parse metadata for '$wingetId'" -Tag "Debug"
        return
    }

    $obj = $metadata

    # Build simplified info.json for deploy.ps1: Name, Description, Publisher, InformationUrl (Homepage), PrivacyUrl, Architectures
    $infoOut = [ordered]@{ }
    $infoOut['Name']         = $applicationName
    $infoOut['Description']  = if ($obj['Description']) { $obj['Description'] } else { '' }
    $infoOut['Publisher']    = if ($obj['Publisher']) { $obj['Publisher'] } else { '' }
    $infoOut['PublisherUrl'] = if ($obj['PublisherUrl']) { $obj['PublisherUrl'] } else { $null }
    $infoOut['InformationUrl'] = if ($obj['PackageUrl']) { $obj['PackageUrl'] } elseif ($obj['Homepage']) { $obj['Homepage'] } else { $null }
    $infoOut['PrivacyUrl']   = if ($obj['PrivacyUrl']) { $obj['PrivacyUrl'] } else { $null }
    $infoOut['Architectures'] = @($supportedArches.ToArray())
    $infoOut['WingetId']     = $wingetId
    $infoOut['FetchedAt']    = (Get-Date -Format 'o')

    $jsonContent = $infoOut | ConvertTo-Json -Depth 5 -Compress:$false
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
