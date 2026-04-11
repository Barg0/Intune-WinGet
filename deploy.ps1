# ---------------------------[ Script Start Timestamp ]---------------------------
param(
    [switch]$OverwriteExisting
)
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName   = "deploy"
$logFileName = "$($scriptName).log"

# ---------------------------[ Configuration ]---------------------------
$ErrorActionPreference = 'Stop'

$enableGroupCreation   = $true
$groupNamingAppSuffix  = $true
$deployDependencies    = $true  # If $false, skip dependency auto-deploy entirely
$groupCreationBlacklist = @('Microsoft Visual C++*', 
                            'Microsoft ODBC Driver*',
                            'Microsoft .NET Runtime*',
                            'Microsoft .NET Windows Desktop Runtime*',
                            'Microsoft ASP.NET Core Hosting Bundle',
                            'Microsoft ASP.NET Core Runtime',
                            '7-Zip')

$graphBaseUrl          = "https://graph.microsoft.com/beta"
$graphScopes           = @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All')
$minWindowsRelease     = "21H1"
$installCommandLineSystem   = "%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\install.ps1"
$uninstallCommandLineSystem = "%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1"
# User context: -NoProfile -NonInteractive for silent run; -WindowStyle Hidden to reduce visible window
$installCommandLineUser     = "powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden .\install.ps1"
$uninstallCommandLineUser   = "powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -WindowStyle Hidden .\uninstall.ps1"
$chunkSizeBytes        = 1024l * 1024l * 6l
$sasRenewAfterMs       = 420000
$sleepAfterCommitSec   = 30
# POST .../contentVersions often returns 412 until a prior publish finishes (especially overwrite).
$contentVersionPostAttempts = 10
$contentVersionPostDelaySec = 15
# Azure blob PUT can fail with DNS / "unknown host" (transient); retry before failing the deploy.
$blobHttpRetryMax         = 6
$blobHttpRetryDelaySec    = 5

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
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

# ---------------------------[ Files and Folders ]---------------------------
$rootDir   = Split-Path -Parent $PSCommandPath
$appsRoot  = Join-Path $rootDir 'apps'
$iconsRoot = Join-Path $rootDir 'icons'
$csvPath   = Join-Path $rootDir 'apps.csv'

# ---------------------------[ Auth ]---------------------------
function Test-GraphSdkModulesPresent {
    $authModule  = Get-Module -ListAvailable 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue | Select-Object -First 1
    $graphModule = Get-Module -ListAvailable 'Microsoft.Graph' -ErrorAction SilentlyContinue | Select-Object -First 1
    $graphBeta   = Get-Module -ListAvailable 'Microsoft.Graph.Beta' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ((-not $authModule -and -not $graphModule) -or -not $graphBeta) { return $false }
    return $true
}

function Install-GraphSdkModules {
    if (Test-GraphSdkModulesPresent) { return }
    Write-Log "Graph: Install-Module" -Tag "Run"
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        }
        $installParams = @{
            Name            = @('Microsoft.Graph', 'Microsoft.Graph.Beta')
            Scope           = 'CurrentUser'
            Force           = $true
            AllowClobber    = $true
            Repository      = 'PSGallery'
            ErrorAction     = 'Stop'
        }
        $icm = Get-Command Install-Module -ErrorAction Stop
        if ($icm.Parameters.ContainsKey('AcceptLicense')) {
            $installParams.AcceptLicense = $true
        }
        Install-Module @installParams
    }
    catch {
        Write-Log "Graph: Install-Module failed — $($_.Exception.Message)" -Tag "Error"
        throw "Install Graph modules manually: Install-Module -Name Microsoft.Graph,Microsoft.Graph.Beta -Scope CurrentUser"
    }
    if (-not (Test-GraphSdkModulesPresent)) {
        Write-Log "Graph: modules still missing after Install-Module" -Tag "Error"
        throw "Microsoft.Graph / Microsoft.Graph.Beta not available after install."
    }
    Write-Log "Graph: modules ok" -Tag "Success"
}

function Test-GraphScopes {
    param([object]$graphContext)
    if (-not $graphContext) { return $false }
    $currentScopes = @()
    if ($graphContext.Scopes) {
        if ($graphContext.Scopes -is [array]) {
            $currentScopes = $graphContext.Scopes
        } else {
            $currentScopes = @($graphContext.Scopes -split '\s+')
        }
    }
    foreach ($required in $graphScopes) {
        if ($currentScopes -notcontains $required) {
            Write-Log "Scope missing: $required" -Tag "Debug"
            return $false
        }
    }
    return $true
}

function Initialize-GraphConnection {
    Install-GraphSdkModules
    if (-not (Get-Module 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue)) {
        Import-Module 'Microsoft.Graph.Authentication' -ErrorAction Stop
        Write-Log "Module: Graph.Authentication" -Tag "Debug"
    }
    $graphContext = $null
    try {
        $graphContext = Get-MgContext -ErrorAction Stop
    } catch {
        Write-Log "No Graph context" -Tag "Debug"
    }
    if ($graphContext -and $graphContext.Account -and (Test-GraphScopes -graphContext $graphContext)) {
        Write-Log "Graph: $($graphContext.Account)" -Tag "Success"
        return
    }
    if ($graphContext -and -not (Test-GraphScopes -graphContext $graphContext)) {
        Write-Log "Graph: re-auth (missing scopes)" -Tag "Run"
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log "Graph: connecting" -Tag "Run"
    Connect-MgGraph -Scopes $graphScopes -NoWelcome -ErrorAction Stop
    $graphContext = Get-MgContext -ErrorAction SilentlyContinue
    Write-Log "Graph: $($graphContext.Account)" -Tag "Success"
}

# ---------------------------[ Graph Request ]---------------------------
function Invoke-GraphApi {
    param([string]$method, [string]$resource, [object]$body = $null)
    $requestUri = if ($resource -match '^https?://') { $resource } else { "$graphBaseUrl/$($resource.TrimStart('/'))" }
    Write-Log "Graph $method $requestUri" -Tag "Debug"
    $invokeParams = @{ Uri = $requestUri; Method = $method }
    if ($null -ne $body) {
        $invokeParams.Body = if ($body -is [string]) { $body } else { $body | ConvertTo-Json -Depth 15 -Compress:$false }
        $invokeParams.ContentType = 'application/json'
    }
    return Invoke-MgGraphRequest @invokeParams
}

# ---------------------------[ Read Detection.xml from intunewin ]---------------------------
function Get-IntuneWinMetadata {
    param([Parameter(Mandatory)][string]$intuneWinPath)
    if (-not (Test-Path -LiteralPath $intuneWinPath)) { throw "File not found: $intuneWinPath" }
    $tempRoot = Join-Path $appsRoot 'temp'
    $tempDir  = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
    if (-not (Test-Path $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipFile = [System.IO.Compression.ZipFile]::OpenRead($intuneWinPath)
        try {
            $detEntry = $zipFile.Entries | Where-Object { $_.Name -eq 'Detection.xml' } | Select-Object -First 1
            if (-not $detEntry) { throw "Detection.xml missing in intunewin" }
            $detPath = Join-Path $tempDir 'Detection.xml'
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($detEntry, $detPath, $true)
            [xml]$detectionXml = Get-Content -LiteralPath $detPath -Encoding UTF8
            $appInfo = $detectionXml.ApplicationInfo
            $encInfo = $appInfo.EncryptionInfo
            $fileName = $appInfo.FileName
            $contentEntry = $zipFile.Entries | Where-Object { $_.Name -eq $fileName } | Select-Object -First 1
            if (-not $contentEntry) { $contentEntry = $zipFile.Entries | Where-Object { $_.FullName -like "*$fileName" } | Select-Object -First 1 }
            if (-not $contentEntry) { throw "Content file missing in intunewin" }
            $contentPath = Join-Path $tempDir $fileName
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($contentEntry, $contentPath, $true)
            $encryptedSize = (Get-Item -LiteralPath $contentPath).Length
            $zipFile.Dispose()
            return @{
                FileName          = $fileName
                SetupFile         = $appInfo.SetupFile
                UnencryptedSize   = [long]$appInfo.UnencryptedContentSize
                EncryptedSize     = $encryptedSize
                EncryptedFilePath = $contentPath
                EncryptionInfo    = @{
                    encryptionKey        = $encInfo.EncryptionKey
                    macKey               = $encInfo.MacKey
                    initializationVector = $encInfo.InitializationVector
                    mac                  = $encInfo.Mac
                    profileIdentifier    = $encInfo.ProfileIdentifier
                    fileDigest           = $encInfo.FileDigest
                    fileDigestAlgorithm  = $encInfo.FileDigestAlgorithm
                }
                TempDir           = $tempDir
            }
        } catch {
            $zipFile.Dispose()
            throw
        }
    } catch {
        if (Test-Path $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

# ---------------------------[ Detection rule from detection.ps1 ]---------------------------
function Get-DetectionRuleFromScript {
    param([Parameter(Mandatory)][string]$scriptPath)
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing: detection.ps1" }
    $scriptBytes = [System.IO.File]::ReadAllBytes($scriptPath)
    $scriptBase64 = [System.Convert]::ToBase64String($scriptBytes)
    return @{
        '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptRule'
        ruleType              = 'detection'
        scriptContent         = $scriptBase64
        enforceSignatureCheck = $false
        runAs32Bit            = $false
    }
}

# ---------------------------[ Safe folder / file names ]---------------------------
function Get-SafeName {
    param([string]$name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $regex = "[" + [Regex]::Escape($invalid) + "]"
    return ($name -replace $regex, '_').Trim()
}

function Get-AppFolderPathForWingetId {
    param(
        [Parameter(Mandatory)] [string]$AppsRoot,
        [Parameter(Mandatory)] [string]$WingetId
    )
    if (-not (Test-Path -LiteralPath $AppsRoot)) { return $null }
    $want = $WingetId.Trim()
    foreach ($d in Get-ChildItem -LiteralPath $AppsRoot -Directory -ErrorAction SilentlyContinue) {
        if ($d.Name -eq 'temp') { continue }
        $jsonPath = Join-Path $d.FullName 'info.json'
        if (-not (Test-Path -LiteralPath $jsonPath)) { continue }
        try {
            $info = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $wid = if ($info.WingetId) { [string]$info.WingetId } else { '' }
            if ($wid.Trim() -eq $want) {
                return $d.FullName
            }
        }
        catch {
            Write-Log "Read failed: $jsonPath — $($_.Exception.Message)" -Tag "Debug"
        }
    }
    return $null
}

function Add-MobileAppDependencyRelationships {
    param(
        [Parameter(Mandatory)] [string]$MainAppId,
        [Parameter(Mandatory)] [string[]]$TargetAppIds
    )
    $MainAppId = $MainAppId.Trim()
    $ids = @($TargetAppIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return }
    Write-Log "Dependencies: $($ids.Count) → $MainAppId" -Tag "Info"
    # AppLifecycle: POST .../mobileApps/{id}/relationships is not routed ("No OData route exists").
    # Use updateRelationships (see https://learn.microsoft.com/en-us/graph/api/intune-shared-mobileapp-updaterelationships):
    # one POST replaces the app's direct relationship set — include all dependencies in one relationships[] array.
    $relationships = [System.Collections.ArrayList]::new()
    try {
        $relsResponse = Invoke-GraphApi -method Get -resource "/deviceAppManagement/mobileApps/$MainAppId/relationships"
        $relList = if ($null -ne $relsResponse.value) { @($relsResponse.value) } else { @($relsResponse) }
        foreach ($r in $relList) {
            if ([string]$r.'@odata.type' -eq '#microsoft.graph.mobileAppSupersedence') {
                [void]$relationships.Add($r)
            }
        }
    }
    catch {
        Write-Log "Dependencies: GET relationships failed (supersedence merge skipped) — $_" -Tag "Debug"
    }
    foreach ($tid in $ids) {
        [void]$relationships.Add(@{
                '@odata.type'    = '#microsoft.graph.mobileAppDependency'
                targetId         = $tid
                dependencyType   = 'autoInstall'
            })
    }
    $body = @{ relationships = @($relationships.ToArray()) }
    $null = Invoke-GraphApi -method Post -resource "/deviceAppManagement/mobileApps/$MainAppId/updateRelationships" -body $body
    foreach ($tid in $ids) {
        Write-Log "Dep: $tid" -Tag "Debug"
    }
    Write-Log "Dependencies: ok ($MainAppId)" -Tag "Success"
}

# ---------------------------[ Icon base64 ]---------------------------
# Tries each candidate in order: exact match (Name.png), then prefix match (longest base name wins).
# Candidates should include WinGet catalog name (displayName), WingetId, and package folder safe name — they often differ.
function Get-IconBase64 {
    param(
        [Parameter(Mandatory)][string[]]$CandidateAppNames,
        [Parameter(Mandatory)][string]$iconsFolder
    )
    if (-not (Test-Path -LiteralPath $iconsFolder)) { return $null }
    $allIcons = Get-ChildItem -LiteralPath $iconsFolder -Filter '*.png' -File -ErrorAction SilentlyContinue
    if (-not $allIcons) { return $null }

    $orderedUnique = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($raw in $CandidateAppNames) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $t = $raw.Trim()
        $key = $t.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$orderedUnique.Add($t)
    }

    foreach ($appName in $orderedUnique) {
        $exactMatch = $allIcons | Where-Object { $_.BaseName -eq $appName } | Select-Object -First 1
        if ($exactMatch) {
            Write-Log "Icon: $($exactMatch.Name)" -Tag "Get"
            return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($exactMatch.FullName))
        }
    }
    foreach ($appName in $orderedUnique) {
        $prefixMatches = $allIcons | Where-Object { $appName.StartsWith($_.BaseName, [StringComparison]::OrdinalIgnoreCase) }
        if (-not $prefixMatches) { continue }
        $iconFile = $prefixMatches | Sort-Object { $_.BaseName.Length } -Descending | Select-Object -First 1
        Write-Log "Icon: $($iconFile.Name)" -Tag "Get"
        return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($iconFile.FullName))
    }
    return $null
}

# mimeContent shape required by Graph for mobileApp.largeIcon (see win32LobApp update docs).
function New-LargeIconMimeObject {
    param([Parameter(Mandatory)][string]$IconBase64)
    return @{
        '@odata.type' = 'microsoft.graph.mimeContent'
        type          = 'image/png'
        value         = $IconBase64
    }
}

# ---------------------------[ Map Architectures from info.json ]---------------------------
# Maps to: ["x86"]->x86,x64 | ["x64"]->x64 | ["arm64"]->arm64 | ["x86","x64"]->x86,x64 | ["x86","x64","arm64"]->x86,x64,arm64
# Fallback when no valid archs: x64
function Get-ApplicableArchitectures {
    param([object]$appInfo)
    $archs = @()
    if ($appInfo.Architectures -is [array]) {
        $archs = @($appInfo.Architectures | ForEach-Object { $_.ToString().ToLowerInvariant() } | Where-Object { $_ -match '^(x86|x64|arm64)$' })
    }
    if ($archs.Count -eq 0) { return 'x64' }
    if ($archs.Count -eq 1 -and $archs[0] -eq 'x86') { return 'x86,x64' }
    return ($archs -join ',')
}

# ---------------------------[ Win32 app body ]---------------------------
function New-Win32LobAppBody {
    param(
        [Parameter(Mandatory)][string]$displayName,
        [string]$description = '',
        [string]$publisher = '',
        [string]$informationUrl = '',
        [string]$privacyUrl = '',
        [string]$fileName,
        [string]$setupFile,
        [array]$rules,
        [string]$iconBase64 = $null,
        [Parameter(Mandatory)][string]$applicableArchitectures,
        [string]$displayVersion = 'WinGet',
        [string]$runAsAccount = 'system',
        [string]$installCommandLine,
        [string]$uninstallCommandLine
    )
    $body = @{
        '@odata.type'                   = '#microsoft.graph.win32LobApp'
        displayName                    = $displayName
        displayVersion                 = $displayVersion
        description                    = $description
        publisher                      = $publisher
        developer                      = if ($publisher -eq 'Microsoft Corporation') { 'Microsoft' } else { $publisher }
        owner                          = ''
        notes                          = ''
        informationUrl                 = $informationUrl
        privacyInformationUrl          = $privacyUrl
        isFeatured                     = $false
        applicableArchitectures        = 'none'
        allowedArchitectures           = $applicableArchitectures
        allowAvailableUninstall        = $true
        fileName                       = $fileName
        setupFilePath                  = $setupFile
        installCommandLine             = $installCommandLine
        uninstallCommandLine           = $uninstallCommandLine
        installExperience              = @{
            deviceRestartBehavior  = 'basedOnReturnCode'
            runAsAccount           = $runAsAccount
            maxRunTimeInMinutes    = 60
        }
        returnCodes                    = @(
            @{ returnCode = 0; type = 'success' }
            @{ returnCode = 1; type = 'failed' }
        )
        rules                          = $rules
        msiInformation                 = $null
        minimumSupportedWindowsRelease = $minWindowsRelease
        runAs32Bit                     = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($iconBase64)) {
        $body.largeIcon = New-LargeIconMimeObject -IconBase64 $iconBase64
    }
    return $body
}

# ---------------------------[ Group creation ]---------------------------
function Get-ResolvedGroupNames {
    param([string]$appName)
    if ($groupNamingAppSuffix) {
        return @{ RQ = "Win - SW - RQ - $appName"; AV = "Win - SW - AV - $appName" }
    }
    return @{ RQ = "Win - SW - $appName - RQ"; AV = "Win - SW - $appName - AV" }
}

function Test-AppGroupBlacklisted {
    param([string]$displayName)
    foreach ($pattern in $groupCreationBlacklist) {
        if ($displayName -like $pattern) { return $true }
    }
    return $false
}

function Get-SafeMailNickname {
    param([string]$displayName)
    $safe = ($displayName -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Group' }
    return $safe.Substring(0, [Math]::Min(56, $safe.Length))
}

function Get-OrCreateGroup {
    param([string]$displayName)
    $escaped = $displayName -replace "'", "''"
    $filter = [uri]::EscapeDataString("displayName eq '$escaped'")
    $existing = Invoke-GraphApi -method Get -resource "/groups?`$filter=$filter&`$top=1&`$select=id,displayName"
    if ($existing.value -and $existing.value.Count -gt 0) {
        Write-Log "Group: exists ($displayName)" -Tag "Get"
        return $existing.value[0].id
    }
    $mailNick = (Get-SafeMailNickname -displayName $displayName) + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $groupBody = @{
        displayName     = $displayName
        description     = "Intune app assignment group: $displayName"
        mailEnabled     = $false
        mailNickname    = $mailNick
        securityEnabled = $true
        groupTypes      = @()
    }
    Write-Log "Group: $displayName" -Tag "Run"
    $created = Invoke-GraphApi -method Post -resource '/groups' -body $groupBody
    Write-Log "Group id: $($created.id)" -Tag "Debug"
    return $created.id
}

function Set-AppGroupAssignments {
    param([string]$appId, [string]$displayName)
    $groupNames = Get-ResolvedGroupNames -appName $displayName
    $rqGroupId = Get-OrCreateGroup -displayName $groupNames.RQ
    $avGroupId = Get-OrCreateGroup -displayName $groupNames.AV
    $assignments = @(
        @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            target        = @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId       = $rqGroupId
            }
            intent        = 'required'
            settings      = @{
                '@odata.type'  = '#microsoft.graph.win32LobAppAssignmentSettings'
                notifications  = 'hideAll'
            }
        }
        @{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            target        = @{
                '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                groupId       = $avGroupId
            }
            intent        = 'available'
            settings      = @{ '@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings' }
        }
    )
    $assignBody = @{ mobileAppAssignments = $assignments }
    $null = Invoke-GraphApi -method Post -resource "/deviceAppManagement/mobileApps/$appId/assign" -body $assignBody
    Write-Log "Assign: RQ=$($groupNames.RQ); AV=$($groupNames.AV)" -Tag "Debug"
    Write-Log "Groups assigned" -Tag "Success"
}

# ---------------------------[ Check if app exists ]---------------------------
function Test-AppExists {
    param([string]$displayName)
    try {
        $escapedName = $displayName -replace "'", "''"
        $odataFilter = [uri]::EscapeDataString("displayName eq '$escapedName'")
        $response = Invoke-GraphApi -method Get -resource "/deviceAppManagement/mobileApps?`$filter=$odataFilter&`$top=1&`$select=id,displayName"
        return ($response.value -and $response.value.Count -gt 0)
    } catch { return $false }
}

function Get-ExistingAppId {
    param([string]$displayName)
    try {
        $escapedName = $displayName -replace "'", "''"
        $odataFilter = [uri]::EscapeDataString("displayName eq '$escapedName'")
        $response = Invoke-GraphApi -method Get -resource "/deviceAppManagement/mobileApps?`$filter=$odataFilter&`$top=1&`$select=id,displayName"
        if ($response.value -and $response.value.Count -gt 0) { return $response.value[0].id }
    } catch { }
    return $null
}

# ---------------------------[ Chunked Azure upload ]---------------------------
function Invoke-RestMethodWithRetry {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [ValidateSet('Put')][string]$Method,
        [hashtable]$Headers = @{},
        $Body = $null,
        [string]$ContentType = $null,
        [int]$MaxAttempts = $blobHttpRetryMax,
        [int]$DelaySec = $blobHttpRetryDelaySec
    )
    for ($a = 1; $a -le $MaxAttempts; $a++) {
        try {
            $p = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true }
            if ($Headers.Count -gt 0) { $p.Headers = $Headers }
            if ($null -ne $Body) { $p.Body = $Body }
            if ($ContentType) { $p.ContentType = $ContentType }
            return Invoke-RestMethod @p
        }
        catch {
            if ($a -ge $MaxAttempts) { throw }
            Write-Log "Blob: retry $a/$MaxAttempts ($($_.Exception.Message))" -Tag "Get"
            Start-Sleep -Seconds $DelaySec
        }
    }
}

function Send-ChunkedUpload {
    param([string]$sasUri, [string]$filePath, [string]$fileUri = $null)
    $fileSizeBytes = (Get-Item -LiteralPath $filePath).Length
    $chunkCount = [Math]::Ceiling($fileSizeBytes / $chunkSizeBytes)
    $fileReader = [System.IO.File]::OpenRead($filePath)
    $renewTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $currentSasUri = $sasUri
    $blockIds = @()
    try {
        for ($chunkIndex = 0; $chunkIndex -lt $chunkCount; $chunkIndex++) {
            $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($chunkIndex.ToString("0000")))
            $blockIds += $blockId
            $chunkLength = [Math]::Min($chunkSizeBytes, $fileSizeBytes - ($chunkIndex * $chunkSizeBytes))
            $chunkBuffer = New-Object byte[] $chunkLength
            $null = $fileReader.Read($chunkBuffer, 0, $chunkLength)
            $blockUri = "$currentSasUri&comp=block&blockid=$blockId"
            $null = Invoke-RestMethodWithRetry -Uri $blockUri -Method Put -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body $chunkBuffer -ContentType 'application/octet-stream'
            Write-Log "Chunk: $($chunkIndex + 1)/$chunkCount" -Tag "Debug"
            if ($fileUri -and $chunkIndex -lt ($chunkCount - 1) -and $renewTimer.ElapsedMilliseconds -ge $sasRenewAfterMs) {
                $null = Invoke-GraphApi -method Post -resource "$fileUri/renewUpload" -body '{}'
                $fileResource = Invoke-GraphApi -method Get -resource $fileUri
                while ($fileResource.uploadState -eq 'azureStorageUriRenewalPending') {
                    Start-Sleep -Seconds 5
                    $fileResource = Invoke-GraphApi -method Get -resource $fileUri
                }
                $currentSasUri = $fileResource.azureStorageUri
                $renewTimer.Restart()
                Write-Log "SAS: renewed" -Tag "Debug"
            }
        }
        $blockListUri = "$currentSasUri&comp=blocklist"
        $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
        foreach ($id in $blockIds) { $blockListXml += "<Latest>$id</Latest>" }
        $blockListXml += '</BlockList>'
        $null = Invoke-RestMethodWithRetry -Uri $blockListUri -Method Put -Body $blockListXml -ContentType 'application/xml'
    } finally { $fileReader.Dispose() }
}

# ---------------------------[ Main deploy ]---------------------------
function Invoke-Win32AppDeployment {
    param(
        [string]$appFolderPath,
        [string]$folderSafeName,
        [switch]$SkipGroupAssignment
    )
    $infoPath = Join-Path $appFolderPath 'info.json'
    if (-not (Test-Path -LiteralPath $infoPath)) {
        Write-Log "Missing: info.json" -Tag "Error"
        return $false
    }
    $appInfo = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $displayName = if ($appInfo.Name) { [string]$appInfo.Name } else { $folderSafeName }
    $description = if ($appInfo.Description) { $appInfo.Description } else { '' }
    $publisher = if ($appInfo.Publisher) { $appInfo.Publisher } else { '' }
    $informationUrl = if ($appInfo.InformationUrl) { $appInfo.InformationUrl } elseif ($appInfo.PublisherUrl) { $appInfo.PublisherUrl } else { '' }
    $privacyUrl = if ($appInfo.PrivacyUrl) { $appInfo.PrivacyUrl } else { '' }
    $applicableArchitectures = Get-ApplicableArchitectures -appInfo $appInfo
    $installContext = if ($appInfo.InstallContext) { ($appInfo.InstallContext).ToString().ToLowerInvariant() } else { 'system' }
    $runAsAccount = if ($installContext -eq 'user') { 'user' } else { 'system' }
    $installCmd = if ($runAsAccount -eq 'user') { $installCommandLineUser } else { $installCommandLineSystem }
    $uninstallCmd = if ($runAsAccount -eq 'user') { $uninstallCommandLineUser } else { $uninstallCommandLineSystem }

    $existingAppId = Get-ExistingAppId -displayName $displayName
    if ($null -ne $existingAppId -and -not $OverwriteExisting) {
        Write-Log "Skipped: $displayName" -Tag "Info"
        return 'Skipped'
    }

    $intunewinPath = Join-Path $appFolderPath "$folderSafeName.intunewin"
    if (-not (Test-Path -LiteralPath $intunewinPath)) {
        $intunewinCandidates = Get-ChildItem -LiteralPath $appFolderPath -Filter '*.intunewin' -File -ErrorAction SilentlyContinue
        $intunewinPath = ($intunewinCandidates | Select-Object -First 1).FullName
    }
    if (-not $intunewinPath -or -not (Test-Path -LiteralPath $intunewinPath)) {
        Write-Log "Missing: .intunewin" -Tag "Error"
        return $false
    }

    $detectionPath = Join-Path $appFolderPath 'detection.ps1'
    if (-not (Test-Path -LiteralPath $detectionPath)) {
        Write-Log "Missing: detection.ps1" -Tag "Error"
        return $false
    }

    Write-Log "$displayName" -Tag "Info"
    $iconCandidates = @(
        $displayName
        (Get-SafeName -name $displayName)
        $folderSafeName
    )
    $wingetIdForIcon = if ($null -ne $appInfo.WingetId) { [string]$appInfo.WingetId } elseif ($null -ne $appInfo.Id) { [string]$appInfo.Id } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($wingetIdForIcon)) {
        $wingetIdForIcon = $wingetIdForIcon.Trim()
        $iconCandidates += @($wingetIdForIcon, (Get-SafeName -name $wingetIdForIcon))
    }
    $iconBase64 = Get-IconBase64 -iconsFolder $iconsRoot -CandidateAppNames $iconCandidates
    if (-not $iconBase64) {
        $tried = $iconCandidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique
        Write-Log "Icon: none ($($tried -join ', '))" -Tag "Info"
    }
    $detectionRule = Get-DetectionRuleFromScript -scriptPath $detectionPath
    $winMetadata = Get-IntuneWinMetadata -intuneWinPath $intunewinPath

    try {
        $appId = $existingAppId
        $isOverwrite = ($null -ne $appId)

        if (-not $isOverwrite) {
            $appBody = New-Win32LobAppBody -displayName $displayName -description $description -publisher $publisher `
                -informationUrl $informationUrl -privacyUrl $privacyUrl `
                -fileName $winMetadata.FileName -setupFile $winMetadata.SetupFile -rules @($detectionRule) `
                -iconBase64 $iconBase64 -applicableArchitectures $applicableArchitectures -displayVersion 'WinGet' -runAsAccount $runAsAccount `
                -installCommandLine $installCmd -uninstallCommandLine $uninstallCmd

            if ($logDebug) {
                $dumpPath = Join-Path $logFileDirectory 'deploy-request-body.json'
                $appBody | ConvertTo-Json -Depth 15 -Compress:$false | Set-Content -Path $dumpPath -Encoding UTF8
                Write-Log "Body: $dumpPath" -Tag "Debug"
            }

            Write-Log "Creating: $displayName" -Tag "Run"
            $createdApp = Invoke-GraphApi -method Post -resource '/deviceAppManagement/mobileApps' -body $appBody
            $appId = $createdApp.id
            Write-Log "App id: $appId" -Tag "Info"
        } else {
            Write-Log "Overwrite: $displayName ($appId)" -Tag "Run"
            $fullBody = New-Win32LobAppBody -displayName $displayName -description $description -publisher $publisher `
                -informationUrl $informationUrl -privacyUrl $privacyUrl `
                -fileName $winMetadata.FileName -setupFile $winMetadata.SetupFile -rules @($detectionRule) `
                -iconBase64 $iconBase64 -applicableArchitectures $applicableArchitectures -displayVersion 'WinGet' -runAsAccount $runAsAccount `
                -installCommandLine $installCmd -uninstallCommandLine $uninstallCmd
            if ([string]::IsNullOrWhiteSpace($iconBase64)) {
                $null = $fullBody.Remove('largeIcon')
                try {
                    $existingApp = Invoke-GraphApi -method Get -resource "/deviceAppManagement/mobileApps/$($appId)?`$select=id,largeIcon"
                    if ($existingApp.largeIcon -and $existingApp.largeIcon.value) {
                        $fullBody.largeIcon = @{
                            '@odata.type' = 'microsoft.graph.mimeContent'
                            type          = if ($existingApp.largeIcon.type) { $existingApp.largeIcon.type } else { 'image/png' }
                            value         = $existingApp.largeIcon.value
                        }
                        Write-Log "largeIcon: preserve from Intune" -Tag "Debug"
                    } else {
                        Write-Log "largeIcon: none" -Tag "Debug"
                    }
                } catch {
                    Write-Log "largeIcon: read failed — $_" -Tag "Debug"
                }
            }
            $null = Invoke-GraphApi -method Patch -resource "/deviceAppManagement/mobileApps/$appId" -body $fullBody
            Write-Log "Metadata: patched" -Tag "Debug"
        }

        # 2. Request content version (412/ConditionNotMet until Intune finishes a prior revision — retry)
        $versionResource = "/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions"
        $contentVersion = $null
        for ($cvAttempt = 1; $cvAttempt -le $contentVersionPostAttempts; $cvAttempt++) {
            try {
                $contentVersion = Invoke-GraphApi -method Post -resource $versionResource -body '{}'
                break
            }
            catch {
                $errText = "$($_.Exception.Message) $($_ | Out-String)"
                $is412 = $errText -match '412|Precondition Failed|ConditionNotMet'
                if (-not $is412 -or $cvAttempt -ge $contentVersionPostAttempts) { throw }
                Write-Log "contentVersions: wait/retry $cvAttempt/$contentVersionPostAttempts (412)" -Tag "Get"
                Start-Sleep -Seconds $contentVersionPostDelaySec
            }
        }
        if (-not $contentVersion -or -not $contentVersion.id) {
            throw "contentVersions: no version id after $contentVersionPostAttempts attempts"
        }
        $versionId = $contentVersion.id

        # 3. Create file placeholder (Rozemuller: name, size, sizeEncrypted from Detection.xml)
        $fileBody = @{
            '@odata.type'  = '#microsoft.graph.mobileAppContentFile'
            name           = $winMetadata.FileName
            size           = $winMetadata.UnencryptedSize
            sizeEncrypted  = $winMetadata.EncryptedSize
            manifest       = $null
            isDependency   = $false
        }
        $filesResource = "$versionResource/$versionId/files"
        $fileResource = Invoke-GraphApi -method Post -resource $filesResource -body $fileBody
        $fileId = $fileResource.id
        $fileUri = "/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$versionId/files/$fileId"

        # 4. Wait for azureStorageUri
        Write-Log "Storage URI: waiting" -Tag "Get"
        $fileStatus = Invoke-GraphApi -method Get -resource $fileUri
        while ($fileStatus.uploadState -eq 'azureStorageUriRequestPending') {
            Start-Sleep -Seconds 5
            $fileStatus = Invoke-GraphApi -method Get -resource $fileUri
        }
        if ($fileStatus.uploadState -ne 'azureStorageUriRequestSuccess') {
            throw "Unexpected upload state: $($fileStatus.uploadState)"
        }
        $sasUri = $fileStatus.azureStorageUri

        # 5. Upload chunked to Azure
        Write-Log "Uploading: $displayName" -Tag "Run"
        Send-ChunkedUpload -sasUri $sasUri -filePath $winMetadata.EncryptedFilePath -fileUri $fileUri

        # 6. Commit with encryption info (profileIdentifier must be "ProfileVersion1" per Microsoft sample)
        $commitBody = @{
            fileEncryptionInfo = @{
                '@odata.type'        = '#microsoft.graph.fileEncryptionInfo'
                encryptionKey        = $winMetadata.EncryptionInfo.encryptionKey
                macKey               = $winMetadata.EncryptionInfo.macKey
                initializationVector = $winMetadata.EncryptionInfo.initializationVector
                mac                  = $winMetadata.EncryptionInfo.mac
                profileIdentifier    = 'ProfileVersion1'
                fileDigest           = $winMetadata.EncryptionInfo.fileDigest
                fileDigestAlgorithm  = $winMetadata.EncryptionInfo.fileDigestAlgorithm
            }
        }
        $null = Invoke-GraphApi -method Post -resource "$fileUri/commit" -body $commitBody
        Write-Log "Commit: waiting" -Tag "Get"
        $fileStatus = Invoke-GraphApi -method Get -resource $fileUri
        while ($fileStatus.uploadState -eq 'commitFilePending') {
            Start-Sleep -Seconds 5
            $fileStatus = Invoke-GraphApi -method Get -resource $fileUri
        }
        if ($fileStatus.uploadState -ne 'commitFileSuccess') {
            throw "Commit failed: $($fileStatus.uploadState)"
        }

        # 7. Update app with committed version
        $patchBody = @{
            '@odata.type'             = '#microsoft.graph.win32LobApp'
            committedContentVersion   = $versionId
        }
        $null = Invoke-GraphApi -method Patch -resource "/deviceAppManagement/mobileApps/$appId" -body $patchBody
        Start-Sleep -Seconds $sleepAfterCommitSec

        # Intune often clears largeIcon after the Win32 upload/commit pipeline; re-apply when we have a local PNG.
        if (-not [string]::IsNullOrWhiteSpace($iconBase64)) {
            $iconReapply = @{
                '@odata.type' = '#microsoft.graph.win32LobApp'
                largeIcon     = (New-LargeIconMimeObject -IconBase64 $iconBase64)
            }
            try {
                $null = Invoke-GraphApi -method Patch -resource "/deviceAppManagement/mobileApps/$appId" -body $iconReapply
                Write-Log "largeIcon: reapplied" -Tag "Get"
            } catch {
                Write-Log "largeIcon: patch failed — $_" -Tag "Error"
            }
        }

        # 8. Set architectures via enableApplicableArchitectures (Requirements tab)
        $enableArchBody = @{ applicableArchitectures = $applicableArchitectures }
        try {
            $null = Invoke-GraphApi -method Post -resource "/deviceAppManagement/mobileApps/$appId/enableApplicableArchitectures" -body $enableArchBody
            Write-Log "Arch: $applicableArchitectures" -Tag "Debug"
        } catch {
            Write-Log "Arch: failed — $_" -Tag "Debug"
        }

        Write-Log "Deployed: $displayName" -Tag "Success"

        if (-not $SkipGroupAssignment) {
            if (-not $isOverwrite -and $enableGroupCreation -and -not (Test-AppGroupBlacklisted -displayName $displayName)) {
                try {
                    Set-AppGroupAssignments -appId $appId -displayName $displayName
                }
                catch {
                    Write-Log "Groups: failed — $_" -Tag "Error"
                }
            }
            elseif ($isOverwrite) {
                Write-Log "Skip groups: overwrite ($displayName)" -Tag "Info"
            }
            elseif ($enableGroupCreation -and (Test-AppGroupBlacklisted -displayName $displayName)) {
                Write-Log "Skip groups: blacklist ($displayName)" -Tag "Info"
            }
        }
        else {
            Write-Log "Skip groups: deferred ($displayName)" -Tag "Debug"
        }

        return [string]$appId.Trim()
    } catch {
        Write-Log "Failed: $displayName — $_" -Tag "Error"
        return $false
    } finally {
        if ($winMetadata.TempDir -and (Test-Path -LiteralPath $winMetadata.TempDir)) {
            Remove-Item -LiteralPath $winMetadata.TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "==================== Start ====================" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"
Write-Log "appsRoot: $appsRoot" -Tag "Debug"

if (-not (Test-Path -LiteralPath $appsRoot)) {
    Write-Log "Missing folder: apps" -Tag "Error"
    Complete-Script -ExitCode 1
}
if (-not (Test-Path -LiteralPath $csvPath)) {
    Write-Log "Missing: apps.csv" -Tag "Error"
    Complete-Script -ExitCode 1
}

try { Initialize-GraphConnection } catch {
    Write-Log "Graph: failed — $_" -Tag "Error"
    Complete-Script -ExitCode 1
}

$rows = Import-Csv -LiteralPath $csvPath -Delimiter ','
$totalRows = ($rows | Measure-Object).Count
if ($totalRows -eq 0) {
    Write-Log "CSV: empty" -Tag "Info"
    Complete-Script -ExitCode 0
}

$deployedCount = 0
$failedCount   = 0
$skippedCount  = 0
$notPackagedCount = 0
$depsDeployed = 0

foreach ($row in $rows) {
    $wingetId = if ($row.PSObject.Properties['WingetAppId']) { ([string]$row.WingetAppId).Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($wingetId)) { continue }

    $appFolderPath = Get-AppFolderPathForWingetId -AppsRoot $appsRoot -WingetId $wingetId
    $folderSafeName = if ($appFolderPath) { Split-Path -Leaf $appFolderPath } else { '' }
    if (-not $appFolderPath -or $folderSafeName -eq 'temp') {
        Write-Log "Not packaged: $wingetId" -Tag "Info"
        $notPackagedCount++
        continue
    }

    $infoMainPath = Join-Path $appFolderPath 'info.json'
    if (-not (Test-Path -LiteralPath $infoMainPath)) {
        Write-Log "Missing: info.json ($wingetId)" -Tag "Error"
        $failedCount++
        continue
    }
    try {
        $mainAppInfo = Get-Content -LiteralPath $infoMainPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Write-Log "Read failed: info.json ($wingetId) — $($_.Exception.Message)" -Tag "Error"
        $failedCount++
        continue
    }
    $mainDisplayName = if ($mainAppInfo.Name) { [string]$mainAppInfo.Name } else { $folderSafeName }

    $depsDir = Join-Path $appFolderPath 'dependencies'
    $depSubdirs = @()
    if ($deployDependencies -and (Test-Path -LiteralPath $depsDir)) {
        $depSubdirs = @(Get-ChildItem -LiteralPath $depsDir -Directory -ErrorAction SilentlyContinue)
    }
    $deferMainGroups = $depSubdirs.Count -gt 0

    $depTargetIds = [System.Collections.Generic.List[string]]::new()
    foreach ($depDir in $depSubdirs) {
        $depInfoPath = Join-Path $depDir.FullName 'info.json'
        if (-not (Test-Path -LiteralPath $depInfoPath)) {
            Write-Log "Missing: info.json (dep $($depDir.Name))" -Tag "Error"
            $failedCount++
            continue
        }
        try {
            $depInfo = Get-Content -LiteralPath $depInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Log "Read failed: dep info.json ($($depDir.Name)) — $($_.Exception.Message)" -Tag "Error"
            $failedCount++
            continue
        }
        $depDisplayName = if ($depInfo.Name) { [string]$depInfo.Name } else { $depDir.Name }
        Write-Log "Dependency: $depDisplayName ($mainDisplayName)" -Tag "Info"
        $depSafe = $depDir.Name
        $depResult = Invoke-Win32AppDeployment -appFolderPath $depDir.FullName -folderSafeName $depSafe -SkipGroupAssignment
        if ($depResult -and $depResult -ne 'Skipped') {
            [void]$depTargetIds.Add([string]$depResult)
            $depsDeployed++
            Write-Log "Deployed dep: $depDisplayName" -Tag "Success"
        }
        elseif ($depResult -eq 'Skipped') {
            $existingDepId = Get-ExistingAppId -displayName $depDisplayName
            if ($existingDepId) {
                [void]$depTargetIds.Add([string]$existingDepId)
                Write-Log "Dep exists: $depDisplayName ($existingDepId)" -Tag "Info"
            }
        }
        else {
            Write-Log "Failed dep: $depDisplayName" -Tag "Error"
            $failedCount++
        }
    }

    $mainExistingBefore = Get-ExistingAppId -displayName $mainDisplayName

    if ($deferMainGroups) {
        $mainResult = Invoke-Win32AppDeployment -appFolderPath $appFolderPath -folderSafeName $folderSafeName -SkipGroupAssignment
    }
    else {
        $mainResult = Invoke-Win32AppDeployment -appFolderPath $appFolderPath -folderSafeName $folderSafeName
    }

    if ($mainResult -and $mainResult -ne 'Skipped') {
        if ($depTargetIds.Count -gt 0) {
            try {
                Add-MobileAppDependencyRelationships -MainAppId ([string]$mainResult) -TargetAppIds @($depTargetIds)
            }
            catch {
                Write-Log "Dependencies: failed — $_" -Tag "Error"
            }
        }
        if ($deferMainGroups) {
            if (-not $mainExistingBefore -and $enableGroupCreation -and -not (Test-AppGroupBlacklisted -displayName $mainDisplayName)) {
                try {
                    Set-AppGroupAssignments -appId ([string]$mainResult) -displayName $mainDisplayName
                }
                catch {
                    Write-Log "Deferred groups: failed — $_" -Tag "Error"
                }
            }
            elseif ($mainExistingBefore) {
                Write-Log "Skip groups: exists ($mainDisplayName)" -Tag "Info"
            }
            elseif ($enableGroupCreation -and (Test-AppGroupBlacklisted -displayName $mainDisplayName)) {
                Write-Log "Skip groups: blacklist ($mainDisplayName)" -Tag "Info"
            }
        }
        $deployedCount++
    }
    elseif ($mainResult -eq 'Skipped') {
        $skippedCount++
    }
    else {
        $failedCount++
    }
}

Write-Log "Summary: $deployedCount ok · $skippedCount skipped · $failedCount failed" -Tag "Info"
Complete-Script -ExitCode $(if ($failedCount -gt 0) { 1 } else { 0 })
