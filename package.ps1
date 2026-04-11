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

# ---------------------------[ File and Folder Config ]---------------------------
$rootDir               = Split-Path -Parent $PSCommandPath
$csvPath               = Join-Path $rootDir 'apps.csv'
$templatesPath         = Join-Path $rootDir 'templates'
$outputRoot            = Join-Path $rootDir 'apps'
$intuneWinAppUtilPath  = Join-Path $rootDir 'IntuneWinAppUtil.exe'
# Official binary (same as cloning https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool )
$intuneWinAppUtilDownloadUrl = 'https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/master/IntuneWinAppUtil.exe'

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"
Write-Log "rootDir: $rootDir" -Tag "Debug"
Write-Log "forceRepack: $forceRepack | fetchWinget: $fetchWingetShow" -Tag "Debug"

#region --- Helpers ---
function Install-IntuneWinAppUtil {
    param([Parameter(Mandatory)] [string]$DestinationPath)
    if (Test-Path -LiteralPath $DestinationPath) { return }
    Write-Log "IntuneWinAppUtil: download" -Tag "Run"
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        Invoke-WebRequest -Uri $intuneWinAppUtilDownloadUrl -OutFile $DestinationPath -UseBasicParsing
    }
    catch {
        Write-Log "IntuneWinAppUtil: download failed — $($_.Exception.Message)" -Tag "Error"
        Complete-Script -ExitCode 1
    }
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        Write-Log "IntuneWinAppUtil: missing after download" -Tag "Error"
        Complete-Script -ExitCode 1
    }
    Write-Log "IntuneWinAppUtil: saved" -Tag "Success"
}

function Assert-Path {
    [CmdletBinding()]
    param([string]$path, [string]$description = "Path")
    Write-Log "Check: $description" -Tag "Debug"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "Missing: $description" -Tag "Error"
        Complete-Script -ExitCode 1
    }
}

function Get-SafeName {
    [CmdletBinding()]
    param([string]$name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $regex   = "[" + [Regex]::Escape($invalid) + "]"
    $result  = ($name -replace $regex, '_').Trim()
    return $result
}

function Set-Placeholders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$templatePath,
        [Parameter(Mandatory)] [string]$outputPath,
        [Parameter(Mandatory)] [string]$applicationName,
        [Parameter(Mandatory)] [string]$wingetAppId,
        [string]$installContext = 'system',
        [string]$installOverride = ''
    )

    Write-Log "Template: $([IO.Path]::GetFileName($templatePath))" -Tag "Debug"

    $content = Get-Content -LiteralPath $templatePath -Raw

    $content = $content.Replace('__APPLICATION_NAME__', $applicationName)
    $content = $content.Replace('__WINGET_APP_ID__', $wingetAppId)
    $contextNormalized = $installContext.Trim().ToLowerInvariant()
    if ($contextNormalized -notmatch '^(system|user)$') { $contextNormalized = 'system' }
    $content = $content.Replace('__INSTALL_CONTEXT__', $contextNormalized)

    # Escape single quotes for PowerShell single-quoted strings: ' → ''
    $sq = @{ name = $applicationName.Replace("'", "''"); id = $wingetAppId.Replace("'", "''"); ctx = $contextNormalized.Replace("'", "''") }

    if (-not [string]::IsNullOrWhiteSpace($installOverride)) {
        $overrideEscaped = $installOverride.Trim().Replace("'", "''").Replace("`r", '').Replace("`n", ' ')
        $content = $content.Replace('__INSTALL_OVERRIDE__', $overrideEscaped)
        $content = $content -replace '(?m)^\s*\$installOverride\s*=\s*.*$', "`$installOverride = '$overrideEscaped'"
    } else {
        $content = $content.Replace('__INSTALL_OVERRIDE__', '')
    }

    $content = $content -replace '(?m)^\s*\$applicationName\s*=\s*.*$', "`$applicationName = '$($sq.name)'"
    $content = $content -replace '(?m)^\s*\$wingetAppId\s*=\s*.*$', "`$wingetAppId = '$($sq.id)'"
    $content = $content -replace '(?m)^\s*\$installContext\s*=\s*.*$', "`$installContext = '$($sq.ctx)'"

    Set-Content -LiteralPath $outputPath -Value $content -Encoding UTF8
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

    $process = Start-Process -FilePath $intuneWinAppUtilPath -ArgumentList $intuneArgs -Wait -PassThru -WindowStyle Hidden

    Write-Log "Exit: $($process.ExitCode)" -Tag "Debug"
    if ($process.ExitCode -ne 0) {
        Write-Log "IntuneWinAppUtil exit: $($process.ExitCode)" -Tag "Error"
        throw "Packaging failed."
    }
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
        Write-Log "language.json not found" -Tag "Debug"
        return $RawOutput
    }

    try {
        $lang = Get-Content -LiteralPath $langPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log "language.json load failed: $($_.Exception.Message)" -Tag "Debug"
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
        Write-Log "No locale map: $culture" -Tag "Debug"
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
    param([string]$wingetId, [string]$architecture)
    $wingetArgs = @('show', '--id', $wingetId)
    if ($architecture) { $wingetArgs += '--architecture', $architecture }
    $prevEnc = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    try {
        $out = & winget @wingetArgs 2>&1 | Out-String
        return @{ Output = $out; ExitCode = $LASTEXITCODE }
    } finally {
        [Console]::OutputEncoding = $prevEnc
    }
}

function Get-WingetDependencyBlocks {
    <#
    .SYNOPSIS
        Parses the Dependencies section from normalized (English) winget show output.
        Returns winget package IDs and other dependency lines for info.json only.
    #>
    param([Parameter(Mandatory)] [string]$NormalizedOutput)
    $packageIds = [System.Collections.ArrayList]::new()
    $other = [ordered]@{ }
    if ([string]::IsNullOrWhiteSpace($NormalizedOutput)) {
        return @{ PackageIds = @(); Other = $other }
    }
    $lines = $NormalizedOutput -split "`r?`n"
    $start = -1
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match '^\s*Dependencies:\s*$') {
            $start = $k
            break
        }
    }
    if ($start -lt 0) {
        return @{ PackageIds = @(); Other = $other }
    }
    $currentSubsection = $null
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\S') {
            Write-Log "Deps: break @ $($line.Substring(0, [Math]::Min(40, $line.Length)))" -Tag "Debug"
            break
        }
        if ($line -match '^\s+-\s+(Package Dependencies|Windows Features|Windows Libraries|External Dependencies):\s*$') {
            $currentSubsection = $Matches[1]
            Write-Log "Deps: $currentSubsection" -Tag "Debug"
            continue
        }
        if ($line -match '^\s{8,}(\S+)\s*$') {
            $token = $Matches[1]
            if ($token -match ':') { continue }
            if ($currentSubsection -eq 'Package Dependencies') {
                [void]$packageIds.Add($token)
                Write-Log "Deps: $token" -Tag "Debug"
            }
            elseif ($currentSubsection) {
                if (-not $other[$currentSubsection]) {
                    $other[$currentSubsection] = [System.Collections.ArrayList]::new()
                }
                [void]$other[$currentSubsection].Add($token)
            }
            continue
        }
    }
    $otherOut = [ordered]@{ }
    foreach ($key in $other.Keys) {
        $arr = @($other[$key].ToArray())
        if ($arr.Count -gt 0) { $otherOut[$key] = $arr }
    }
    return @{ PackageIds = @($packageIds.ToArray()); Other = $otherOut }
}

function Get-AppOutputFolderByWingetId {
    param(
        [Parameter(Mandatory)] [string]$OutputRoot,
        [Parameter(Mandatory)] [string]$WingetId
    )
    if (-not (Test-Path -LiteralPath $OutputRoot)) { return $null }
    $want = $WingetId.Trim()
    foreach ($d in Get-ChildItem -LiteralPath $OutputRoot -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -eq 'temp') { continue }
        $jsonPath = Join-Path $d.FullName 'info.json'
        if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
        try {
            $info = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $wid = if ($info.WingetId) { [string]$info.WingetId } else { '' }
            if ($wid.Trim() -eq $want) {
                return @{ Folder = $d.FullName; Info = $info }
            }
        }
        catch {
            Write-Log "Read failed: $jsonPath — $($_.Exception.Message)" -Tag "Debug"
        }
    }
    return $null
}

function Get-WingetShowPackageMetadata {
    <#
    .SYNOPSIS
        Probes winget show per architecture and returns parsed metadata plus dependency lists.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$wingetId)

    $architecturesToProbe = @('x86', 'x64', 'arm64')
    $supportedArches = [System.Collections.ArrayList]::new()
    $metadata = $null
    $normalizedForDeps = $null

    foreach ($arch in $architecturesToProbe) {
        $run = Invoke-WingetShowRaw -wingetId $wingetId -architecture $arch
        if ($run.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($run.Output)) {
            Write-Log "No output: $arch (exit $($run.ExitCode))" -Tag "Debug"
            continue
        }
        $normalized = ConvertFrom-WingetLocalizedOutput -RawOutput $run.Output
        if ($null -eq $normalized) { continue }
        if ($normalized -match 'No package found|No applicable package|No applicable installer') { continue }

        $parsed = ConvertFrom-WingetShowOutput -normalizedOutput $normalized
        $parsed.Obj['Id'] = $wingetId

        if ($parsed.HasInstaller) {
            [void]$supportedArches.Add($arch)
            Write-Log "  $arch : has installer" -Tag "Debug"
        }
        else {
            Write-Log "  $arch : no installer" -Tag "Debug"
        }
        if (-not $metadata) {
            $metadata = $parsed.Obj
            $normalizedForDeps = $normalized
        }
    }

    if ($supportedArches.Count -eq 0 -or -not $metadata) {
        return $null
    }

    $depBlocks = Get-WingetDependencyBlocks -NormalizedOutput $normalizedForDeps
    return @{
        Metadata         = $metadata
        SupportedArches  = @($supportedArches.ToArray())
        Dependencies     = $depBlocks.PackageIds
        DependenciesOther = $depBlocks.Other
    }
}

function ConvertFrom-WingetShowOutput {
    param([string]$normalizedOutput)
    $result = @{ Obj = [ordered]@{ }; HasInstaller = $false }
    if ([string]::IsNullOrWhiteSpace($normalizedOutput)) { return $result }

    $lines = $normalizedOutput -split "`r?`n"
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
            } elseif ($key -eq 'Description') {
                $currentKey = 'Description'
                $currentSection = 'Description'
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
            } elseif ($currentSection -eq 'Description') {
                [void]$currentValue.Add($line.Trim())
            }
            continue
        }
        if ($line -match '^\s{2,}(.+)$' -and $currentSection -in 'ReleaseNotes','Tags','Description') {
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
        [string]$installContext = 'system',
        $precomputedPackageMetadata = $null
    )

    $jsonFileName = 'info.json'
    $jsonPath     = Join-Path $appFolder $jsonFileName

    $pkg = $precomputedPackageMetadata
    if (-not $pkg) {
        Write-Log "winget show: $wingetId" -Tag "Get"
        $pkg = Get-WingetShowPackageMetadata -wingetId $wingetId
    }
    else {
        Write-Log "Precomputed: $wingetId" -Tag "Debug"
    }

    if (-not $pkg) {
        Write-Log "No installer: $wingetId" -Tag "Debug"
        return $false
    }

    $obj = $pkg.Metadata
    $resolvedName = if ($obj['Name']) { [string]$obj['Name'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($resolvedName)) {
        $resolvedName = $wingetId
    }
    # Build simplified info.json for deploy.ps1: Name, Description, Publisher, InformationUrl (Homepage), PrivacyUrl, Architectures
    $infoOut = [ordered]@{ }
    $infoOut['Name']         = $resolvedName.Trim()
    $desc = $obj['Description']
    if ($desc -is [Array]) { $desc = ($desc -join "`n").Trim() }
    $infoOut['Description']  = if ($desc) { $desc } else { '' }
    $infoOut['Publisher']    = if ($obj['Publisher']) { $obj['Publisher'] } else { '' }
    $infoOut['PublisherUrl'] = if ($obj['PublisherUrl']) { $obj['PublisherUrl'] } else { $null }
    $infoOut['InformationUrl'] = if ($obj['PackageUrl']) { $obj['PackageUrl'] } elseif ($obj['Homepage']) { $obj['Homepage'] } else { $null }
    $infoOut['PrivacyUrl']   = if ($obj['PrivacyUrl']) { $obj['PrivacyUrl'] } else { $null }
    $infoOut['Architectures'] = @($pkg.SupportedArches)
    $infoOut['WingetId']     = $wingetId
    $infoOut['InstallContext'] = if ($installContext -match '^(system|user)$') { $installContext } else { 'system' }
    $infoOut['FetchedAt']    = (Get-Date -Format 'o')

    $deps = @($pkg.Dependencies | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($deps.Count -gt 0) {
        $infoOut['Dependencies'] = $deps
    }
    $other = $pkg.DependenciesOther
    if ($other -and $other.Count -gt 0) {
        $otherProps = @{ }
        foreach ($ok in $other.Keys) {
            $otherProps[$ok] = @($other[$ok])
        }
        $infoOut['DependenciesOther'] = [pscustomobject]$otherProps
    }

    $jsonContent = $infoOut | ConvertTo-Json -Depth 8 -Compress:$false
    try {
        Set-Content -LiteralPath $jsonPath -Value $jsonContent -Encoding UTF8
    }
    catch {
        Write-Log "Write failed: info.json — $($_.Exception.Message)" -Tag "Error"
        return $false
    }
    return $true
}

function Get-CsvInstallSettingsForWingetId {
    param(
        [Parameter(Mandatory)] $csvRows,
        [Parameter(Mandatory)] [string]$WingetId
    )
    $want = $WingetId.Trim()
    foreach ($r in $csvRows) {
        $id = if ($r.PSObject.Properties['WingetAppId']) { ([string]$r.WingetAppId).Trim() } else { '' }
        if ($id -eq $want) {
            $ctx = if ($r.PSObject.Properties['InstallContext']) {
                $c = ([string]$r.InstallContext).Trim()
                if ([string]::IsNullOrWhiteSpace($c)) { 'system' } else { $c }
            }
            else { 'system' }
            if ($ctx -notmatch '^(system|user)$') { $ctx = 'system' }
            $ov = if ($r.PSObject.Properties['InstallOverride']) { ([string]$r.InstallOverride).Trim() } else { '' }
            return @{ InstallContext = $ctx; InstallOverride = $ov; Matched = $true }
        }
    }
    return @{ InstallContext = 'system'; InstallOverride = ''; Matched = $false }
}

function Invoke-PackageSingleWingetApp {
    <#
    .SYNOPSIS
        Writes info.json (optional), generates scripts from templates, builds .intunewin for one winget package folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$AppFolder,
        [Parameter(Mandatory)] [string]$AppDisplayName,
        [Parameter(Mandatory)] [string]$WingetId,
        [Parameter(Mandatory)] [string]$InstallContext,
        [string]$InstallOverride = '',
        [Parameter(Mandatory)] [string]$TplInstall,
        [Parameter(Mandatory)] [string]$TplUninstall,
        [Parameter(Mandatory)] [string]$TplDetect,
        [Parameter(Mandatory)] [string]$TempRoot,
        [bool]$FetchWingetShow = $true,
        $precomputedPackageMetadata = $null
    )

    $safeName = Get-SafeName $AppDisplayName
    if (-not (Test-Path -LiteralPath $AppFolder)) {
        New-Item -ItemType Directory -Path $AppFolder -Force | Out-Null
        Write-Log "Folder: $AppFolder" -Tag "Debug"
    }

    if ($FetchWingetShow) {
        $ok = Export-WingetShowToJson -wingetId $WingetId -appFolder $AppFolder -installContext $InstallContext -precomputedPackageMetadata $precomputedPackageMetadata
        if (-not $ok) {
            return $false
        }
    }
    else {
        $infoPath = Join-Path $AppFolder 'info.json'
        if (-not (Test-Path -LiteralPath $infoPath)) {
            Write-Log "Missing: info.json ($AppFolder)" -Tag "Error"
            return $false
        }
        $info = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $info.PSObject.Properties['InstallContext']) {
            $info | Add-Member -NotePropertyName 'InstallContext' -NotePropertyValue $InstallContext -Force
            $info | ConvertTo-Json -Depth 8 -Compress:$false | Set-Content -LiteralPath $infoPath -Encoding UTF8
            Write-Log "Patched: InstallContext=$InstallContext" -Tag "Debug"
        }
    }

    if ($script:keepPlainScripts) {
        $scriptsDir = Join-Path $AppFolder 'scripts'
        if (-not (Test-Path -LiteralPath $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
        $genInstall   = Join-Path $scriptsDir 'install.ps1'
        $genUninstall = Join-Path $scriptsDir 'uninstall.ps1'
    }
    else {
        $genInstall   = Join-Path $AppFolder 'install.ps1'
        $genUninstall = Join-Path $AppFolder 'uninstall.ps1'
    }
    $genDetect = Join-Path $AppFolder 'detection.ps1'

    Set-Placeholders -templatePath $TplInstall   -outputPath $genInstall   -applicationName $AppDisplayName -wingetAppId $WingetId -installContext $InstallContext -installOverride $InstallOverride
    Set-Placeholders -templatePath $TplUninstall -outputPath $genUninstall -applicationName $AppDisplayName -wingetAppId $WingetId -installContext $InstallContext
    Set-Placeholders -templatePath $TplDetect    -outputPath $genDetect    -applicationName $AppDisplayName -wingetAppId $WingetId -installContext $InstallContext

    $packTemp = Join-Path $TempRoot ([guid]::NewGuid().ToString('N'))
    if (-not (Test-Path -LiteralPath $TempRoot)) { New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null }
    $targetIntuneWin = Join-Path $AppFolder ("{0}.intunewin" -f $safeName)
    try {
        New-Item -ItemType Directory -Path $packTemp -Force | Out-Null
        Copy-Item -LiteralPath $genInstall -Destination (Join-Path $packTemp 'install.ps1') -Force
        Copy-Item -LiteralPath $genUninstall -Destination (Join-Path $packTemp 'uninstall.ps1') -Force
        try {
            Write-Log "IntuneWinAppUtil: $safeName" -Tag "Run"
            New-IntuneWinPackage -sourceFolder $packTemp -setupFile 'install.ps1' -outputFolder $packTemp
        }
        catch {
            Write-Log "Failed: $AppDisplayName — $($_.Exception.Message)" -Tag "Error"
            return $false
        }
        $defaultIntuneWin = Join-Path $packTemp 'install.intunewin'
        if (Test-Path -LiteralPath $defaultIntuneWin) {
            if (Test-Path -LiteralPath $targetIntuneWin) { Remove-Item -LiteralPath $targetIntuneWin -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $defaultIntuneWin -Destination $targetIntuneWin -Force
        }
        else {
            Write-Log "Missing: install.intunewin" -Tag "Error"
            return $false
        }
    }
    finally {
        if (Test-Path -LiteralPath $packTemp) {
            Remove-Item -LiteralPath $packTemp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $script:keepPlainScripts) {
        foreach ($filePath in @($genInstall, $genUninstall)) {
            try {
                Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
            }
            catch {
                Write-Log "Cleanup failed: $($_.Exception.Message)" -Tag "Debug"
            }
        }
    }
    return $true
}

#endregion

#region --- Validate inputs & setup ---
Install-IntuneWinAppUtil -DestinationPath $intuneWinAppUtilPath
Assert-Path -path $intuneWinAppUtilPath -description 'IntuneWinAppUtil.exe'
Assert-Path -path $csvPath -description 'CSV'

$tplInstall   = Join-Path $templatesPath 'install.ps1'
$tplUninstall = Join-Path $templatesPath 'uninstall.ps1'
$tplDetect    = Join-Path $templatesPath 'detection.ps1'

Write-Log "Templates: install | uninstall | detect" -Tag "Debug"
Assert-Path -path $tplInstall   -description 'install.ps1 template'
Assert-Path -path $tplUninstall -description 'uninstall.ps1 template'
Assert-Path -path $tplDetect    -description 'detection.ps1 template'

if (-not (Test-Path $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    Write-Log "outputRoot: $outputRoot (created)" -Tag "Debug"
} else {
    Write-Log "outputRoot: $outputRoot" -Tag "Debug"
}
#endregion

#region --- Load CSV ---
Write-Log "CSV: $csvPath" -Tag "Get"
try {
    $rows = Import-Csv -LiteralPath $csvPath -Delimiter ','
    Write-Log "Rows: $($rows.Count)" -Tag "Debug"
} catch {
    Write-Log "CSV read failed: $($_.Exception.Message)" -Tag "Error"
    Complete-Script -ExitCode 1
}
if (-not $rows -or $rows.Count -eq 0) {
    Write-Log 'CSV: empty' -Tag 'Error'
    Complete-Script -ExitCode 1
}
Write-Log "Apps: $($rows.Count)" -Tag "Info"
#endregion

#region --- Main ---
$tempRoot = Join-Path $outputRoot 'temp'
$rowIndex = 0
foreach ($row in $rows) {
    $rowIndex++
    $wingetId = if ($row.PSObject.Properties['WingetAppId']) { ([string]$row.WingetAppId).Trim() } else { '' }
    $installContext = if ($row.PSObject.Properties['InstallContext']) {
        $ctx = ([string]$row.InstallContext).Trim()
        if ([string]::IsNullOrWhiteSpace($ctx)) { 'system' } else { $ctx }
    }
    else { 'system' }
    $installOverride = if ($row.PSObject.Properties['InstallOverride']) {
        ([string]$row.InstallOverride).Trim()
    }
    else { '' }
    if ($installContext -notmatch '^(system|user)$') { $installContext = 'system' }

    if ([string]::IsNullOrWhiteSpace($wingetId)) {
        Write-Log 'Skipped: missing AppId or Name' -Tag 'Error'
        continue
    }

    $precomputedMain = $null
    if ($fetchWingetShow) {
        $precomputedMain = Get-WingetShowPackageMetadata -wingetId $wingetId
        if (-not $precomputedMain) {
            Write-Log "No installer: $wingetId" -Tag 'Error'
            continue
        }
        $appName = [string]$precomputedMain.Metadata['Name']
        if ([string]::IsNullOrWhiteSpace($appName)) { $appName = $wingetId }
        $appName = $appName.Trim()
        $safeName = Get-SafeName $appName
        $appFolder = Join-Path $outputRoot $safeName
    }
    else {
        $resolved = Get-AppOutputFolderByWingetId -OutputRoot $outputRoot -WingetId $wingetId
        if (-not $resolved) {
            Write-Log "Not packaged: $wingetId" -Tag 'Error'
            continue
        }
        $appFolder = $resolved.Folder
        $safeName = Split-Path -Leaf $appFolder
        $appName = if ($resolved.Info.Name) { ([string]$resolved.Info.Name).Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($appName)) {
            Write-Log "Skipped: no Name in info.json ($safeName)" -Tag 'Error'
            continue
        }
        $infoPathProbe = Join-Path $appFolder 'info.json'
        if (-not (Test-Path -LiteralPath $infoPathProbe)) {
            Write-Log "Missing: info.json ($safeName)" -Tag 'Error'
            continue
        }
    }

    Write-Log "Row $($rowIndex): $appName ($wingetId)" -Tag "Debug"
    Write-Log "$appName ($wingetId)" -Tag "Info"

    if ($forceRepack -and (Test-Path -LiteralPath $appFolder)) {
        Write-Log "Force repack: $safeName" -Tag "Info"
        Get-ChildItem -LiteralPath $appFolder -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $appFolder)) {
        New-Item -ItemType Directory -Path $appFolder -Force | Out-Null
    }

    $targetIntuneWin = Join-Path $appFolder ("{0}.intunewin" -f $safeName)
    if (-not $forceRepack -and (Test-Path -LiteralPath $targetIntuneWin)) {
        Write-Log "Skipped: $safeName" -Tag "Info"
        continue
    }

    $packOk = Invoke-PackageSingleWingetApp -AppFolder $appFolder -AppDisplayName $appName -WingetId $wingetId `
        -InstallContext $installContext -InstallOverride $installOverride `
        -TplInstall $tplInstall -TplUninstall $tplUninstall -TplDetect $tplDetect `
        -TempRoot $tempRoot `
        -FetchWingetShow:$fetchWingetShow -precomputedPackageMetadata $precomputedMain

    if (-not $packOk) {
        Write-Log "Failed: row $rowIndex ($wingetId)" -Tag 'Error'
        continue
    }

    Write-Log "Packaged: $appName" -Tag 'Success'

    $infoPathMain = Join-Path $appFolder 'info.json'
    if (-not (Test-Path -LiteralPath $infoPathMain)) { continue }
    try {
        $infoMain = Get-Content -LiteralPath $infoPathMain -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Log "info.json read failed: $($_.Exception.Message)" -Tag 'Debug'
        continue
    }
    $depList = @()
    if ($infoMain.PSObject.Properties['Dependencies'] -and $infoMain.Dependencies) {
        $depList = @($infoMain.Dependencies | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }
    if ($depList.Count -eq 0) { continue }

    $depsRoot = Join-Path $appFolder 'dependencies'
    if (-not (Test-Path -LiteralPath $depsRoot)) {
        New-Item -ItemType Directory -Path $depsRoot -Force | Out-Null
        Write-Log "deps/: $safeName" -Tag "Debug"
    }

    $depTotal = $depList.Count
    $depIdx = 0
    foreach ($depWingetId in $depList) {
        $depIdx++
        Write-Log "Dep $depIdx/${depTotal}: $depWingetId ($appName)" -Tag "Info"
        $depMeta = Get-WingetShowPackageMetadata -wingetId $depWingetId
        if (-not $depMeta) {
            Write-Log "Dep skipped: $depWingetId (no metadata)" -Tag 'Error'
            continue
        }
        $depDisplayName = [string]$depMeta.Metadata['Name']
        if ([string]::IsNullOrWhiteSpace($depDisplayName)) { $depDisplayName = $depWingetId }
        $depDisplayName = $depDisplayName.Trim()
        $depSafe = Get-SafeName $depDisplayName
        $depFolder = Join-Path $depsRoot $depSafe

        $csvDep = Get-CsvInstallSettingsForWingetId -csvRows $rows -WingetId $depWingetId
        $depCtx = $csvDep.InstallContext
        $depOv = $csvDep.InstallOverride
        if ($csvDep.Matched) {
            Write-Log "Dep CSV: $depWingetId | ctx=$depCtx" -Tag "Debug"
        }

        if ($forceRepack -and (Test-Path -LiteralPath $depFolder)) {
            Write-Log "Force repack: dep $depSafe" -Tag "Info"
            Remove-Item -LiteralPath $depFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        $depTargetWin = Join-Path $depFolder ("{0}.intunewin" -f $depSafe)
        if (-not $forceRepack -and (Test-Path -LiteralPath $depTargetWin)) {
            Write-Log "Skipped: dep $depSafe" -Tag "Info"
            continue
        }

        $depPackOk = Invoke-PackageSingleWingetApp -AppFolder $depFolder -AppDisplayName $depDisplayName -WingetId $depWingetId `
            -InstallContext $depCtx -InstallOverride $depOv `
            -TplInstall $tplInstall -TplUninstall $tplUninstall -TplDetect $tplDetect `
            -TempRoot $tempRoot `
            -FetchWingetShow:$true -precomputedPackageMetadata $depMeta
        if ($depPackOk) {
            Write-Log "Packaged dep: $depDisplayName" -Tag 'Success'
        }
        else {
            Write-Log "Failed dep: $depWingetId" -Tag 'Error'
        }
    }
}
#endregion

Complete-Script -ExitCode 0
