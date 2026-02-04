# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName   = "deploy"
$logFileName = "$($scriptName).log"

# ---------------------------[ Configuration ]---------------------------
$ErrorActionPreference = 'Stop'

$enableGroupCreation   = $true
$groupNamingAppSuffix  = $true
$groupCreationBlacklist = @('Microsoft Visual C++*', 
                            'Microsoft ODBC Driver*',
                            'Microsoft .NET Runtime*'
                            'Microsoft .NET Windows Desktop Runtime*',
                            'Microsoft ASP.NET Core Hosting Bundle',
                            'Microsoft ASP.NET Core Runtime',
                            '7-Zip')

$graphBaseUrl          = "https://graph.microsoft.com/beta"
$graphScopes           = @('DeviceManagementApps.ReadWrite.All', 'Group.ReadWrite.All')
$minWindowsRelease     = "21H1"
$installCommandLine    = "%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\install.ps1"
$uninstallCommandLine  = "%WINDIR%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass .\uninstall.ps1"
$chunkSizeBytes        = 1024l * 1024l * 6l
$sasRenewAfterMs       = 420000
$sleepAfterCommitSec   = 30

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

# ---------------------------[ Files and Folders ]---------------------------
$rootDir   = Split-Path -Parent $PSCommandPath
$appsRoot  = Join-Path $rootDir 'apps'
$iconsRoot = Join-Path $rootDir 'icons'

# ---------------------------[ Auth ]---------------------------
function Test-GraphModulesInstalled {
    $authModule   = Get-Module -ListAvailable 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue | Select-Object -First 1
    $graphModule  = Get-Module -ListAvailable 'Microsoft.Graph' -ErrorAction SilentlyContinue | Select-Object -First 1
    $graphBeta    = Get-Module -ListAvailable 'Microsoft.Graph.Beta' -ErrorAction SilentlyContinue | Select-Object -First 1
    $missing = @()
    if (-not $authModule -and -not $graphModule) { $missing += 'Microsoft.Graph' }
    if (-not $graphBeta) { $missing += 'Microsoft.Graph.Beta' }
    if ($missing.Count -gt 0) {
        throw "Missing Graph module(s): $($missing -join ', '). Install with: Install-Module -Name Microsoft.Graph,Microsoft.Graph.Beta -Scope CurrentUser"
    }
    return $true
}

function Test-GraphScopes {
    param([object]$GraphContext)
    if (-not $GraphContext) { return $false }
    $currentScopes = @()
    if ($GraphContext.Scopes) {
        if ($GraphContext.Scopes -is [array]) {
            $currentScopes = $GraphContext.Scopes
        } else {
            $currentScopes = @($GraphContext.Scopes -split '\s+')
        }
    }
    foreach ($required in $graphScopes) {
        if ($currentScopes -notcontains $required) {
            Write-Log "Scope missing: $required (re-auth required)" -Tag "Debug"
            return $false
        }
    }
    return $true
}

function Initialize-GraphConnection {
    Test-GraphModulesInstalled | Out-Null
    if (-not (Get-Module 'Microsoft.Graph.Authentication' -ErrorAction SilentlyContinue)) {
        Import-Module 'Microsoft.Graph.Authentication' -ErrorAction Stop
        Write-Log "Loaded Microsoft.Graph.Authentication" -Tag "Debug"
    }
    $graphContext = $null
    try {
        $graphContext = Get-MgContext -ErrorAction Stop
    } catch {
        Write-Log "No existing Graph context." -Tag "Debug"
    }
    if ($graphContext -and $graphContext.Account -and (Test-GraphScopes -GraphContext $graphContext)) {
        $tenantInfo = if ($graphContext.TenantId) { " | TenantId: $($graphContext.TenantId)" } else { '' }
        Write-Log "Graph already connected: $($graphContext.Account)$tenantInfo" -Tag "Success"
        return
    }
    if ($graphContext -and -not (Test-GraphScopes -GraphContext $graphContext)) {
        Write-Log "Re-authenticating to grant required scopes..." -Tag "Run"
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log "Connecting to Graph..." -Tag "Run"
    Connect-MgGraph -Scopes $graphScopes -NoWelcome -ErrorAction Stop
    $graphContext = Get-MgContext -ErrorAction SilentlyContinue
    $tenantInfo = if ($graphContext -and $graphContext.TenantId) { " | TenantId: $($graphContext.TenantId)" } else { '' }
    Write-Log "Connected: $($graphContext.Account)$tenantInfo" -Tag "Success"
}

# ---------------------------[ Graph Request ]---------------------------
function Invoke-GraphApi {
    param([string]$Method, [string]$Resource, [object]$Body = $null)
    $requestUri = if ($Resource -match '^https?://') { $Resource } else { "$graphBaseUrl/$($Resource.TrimStart('/'))" }
    Write-Log "Graph $Method $requestUri" -Tag "Debug"
    $invokeParams = @{ Uri = $requestUri; Method = $Method }
    if ($Body -ne $null) {
        $invokeParams.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 15 -Compress:$false }
        $invokeParams.ContentType = 'application/json'
    }
    return Invoke-MgGraphRequest @invokeParams
}

# ---------------------------[ Read Detection.xml from intunewin ]---------------------------
function Get-IntuneWinMetadata {
    param([Parameter(Mandatory)][string]$IntuneWinPath)
    if (-not (Test-Path -LiteralPath $IntuneWinPath)) { throw "File not found: $IntuneWinPath" }
    $tempRoot = Join-Path $appsRoot 'temp'
    $tempDir  = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
    if (-not (Test-Path $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zipFile = [System.IO.Compression.ZipFile]::OpenRead($IntuneWinPath)
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
    param([Parameter(Mandatory)][string]$ScriptPath)
    if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "detection.ps1 not found: $ScriptPath" }
    $scriptBytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    $scriptBase64 = [System.Convert]::ToBase64String($scriptBytes)
    return @{
        '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptRule'
        ruleType              = 'detection'
        scriptContent         = $scriptBase64
        enforceSignatureCheck = $false
        runAs32Bit            = $false
    }
}

# ---------------------------[ Icon base64 ]---------------------------
# Resolves icon by: 1) exact match (AppName.png), 2) prefix match (app starts with icon base name, longest wins)
function Get-IconBase64 {
    param([string]$AppName, [string]$IconsFolder)
    if (-not (Test-Path -LiteralPath $IconsFolder)) { return $null }
    $allIcons = Get-ChildItem -LiteralPath $IconsFolder -Filter '*.png' -File -ErrorAction SilentlyContinue
    if (-not $allIcons) { return $null }
    $exactMatch = $allIcons | Where-Object { $_.BaseName -eq $AppName } | Select-Object -First 1
    if ($exactMatch) {
        Write-Log "Icon: $($exactMatch.Name)" -Tag "Get"
        return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($exactMatch.FullName))
    }
    $prefixMatches = $allIcons | Where-Object { $AppName.StartsWith($_.BaseName, [StringComparison]::OrdinalIgnoreCase) }
    if (-not $prefixMatches) { return $null }
    $iconFile = $prefixMatches | Sort-Object { $_.BaseName.Length } -Descending | Select-Object -First 1
    Write-Log "Icon: $($iconFile.Name)" -Tag "Get"
    return [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($iconFile.FullName))
}

# ---------------------------[ Map Architectures from info.json ]---------------------------
# Maps to: ["x86"]->x86,x64 | ["x64"]->x64 | ["arm64"]->arm64 | ["x86","x64"]->x86,x64 | ["x86","x64","arm64"]->x86,x64,arm64
# Fallback when no valid archs: x64
function Get-ApplicableArchitectures {
    param([object]$AppInfo)
    $archs = @()
    if ($AppInfo.Architectures -is [array]) {
        $archs = @($AppInfo.Architectures | ForEach-Object { $_.ToString().ToLowerInvariant() } | Where-Object { $_ -match '^(x86|x64|arm64)$' })
    }
    if ($archs.Count -eq 0) { return 'x64' }
    if ($archs.Count -eq 1 -and $archs[0] -eq 'x86') { return 'x86,x64' }
    return ($archs -join ',')
}

# ---------------------------[ Win32 app body ]---------------------------
function New-Win32LobAppBody {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$Description = '',
        [string]$Publisher = '',
        [string]$InformationUrl = '',
        [string]$PrivacyUrl = '',
        [string]$FileName,
        [string]$SetupFile,
        [array]$Rules,
        [string]$IconBase64 = $null,
        [Parameter(Mandatory)][string]$ApplicableArchitectures,
        [string]$DisplayVersion = 'Winget'
    )
    $body = @{
        '@odata.type'                   = '#microsoft.graph.win32LobApp'
        displayName                    = $DisplayName
        displayVersion                 = $DisplayVersion
        description                    = $Description
        publisher                      = $Publisher
        developer                      = if ($Publisher -eq 'Microsoft Corporation') { 'Microsoft' } else { $Publisher }
        owner                          = ''
        notes                          = ''
        informationUrl                 = $InformationUrl
        privacyInformationUrl          = $PrivacyUrl
        isFeatured                     = $false
        applicableArchitectures        = 'none'
        allowedArchitectures           = $ApplicableArchitectures
        allowAvailableUninstall        = $true
        fileName                       = $FileName
        setupFilePath                  = $SetupFile
        installCommandLine             = $installCommandLine
        uninstallCommandLine           = $uninstallCommandLine
        installExperience              = @{
            deviceRestartBehavior  = 'basedOnReturnCode'
            runAsAccount           = 'system'
            maxRunTimeInMinutes    = 60
        }
        returnCodes                    = @(
            @{ returnCode = 0; type = 'success' }
            @{ returnCode = 1; type = 'failed' }
        )
        rules                          = $Rules
        msiInformation                 = $null
        minimumSupportedWindowsRelease = $minWindowsRelease
        runAs32Bit                     = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($IconBase64)) {
        $body.largeIcon = @{ type = 'image/png'; value = $IconBase64 }
    }
    return $body
}

# ---------------------------[ Group creation ]---------------------------
function Get-ResolvedGroupNames {
    param([string]$AppName)
    if ($groupNamingAppSuffix) {
        return @{ RQ = "Win - SW - RQ - $AppName"; AV = "Win - SW - AV - $AppName" }
    }
    return @{ RQ = "Win - SW - $AppName - RQ"; AV = "Win - SW - $AppName - AV" }
}

function Test-AppGroupBlacklisted {
    param([string]$DisplayName)
    foreach ($pattern in $groupCreationBlacklist) {
        if ($DisplayName -like $pattern) { return $true }
    }
    return $false
}

function Get-SafeMailNickname {
    param([string]$DisplayName)
    $safe = ($DisplayName -replace '[^a-zA-Z0-9]', '')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'Group' }
    return $safe.Substring(0, [Math]::Min(56, $safe.Length))
}

function Get-OrCreateGroup {
    param([string]$DisplayName)
    $escaped = $DisplayName -replace "'", "''"
    $filter = [uri]::EscapeDataString("displayName eq '$escaped'")
    $existing = Invoke-GraphApi -Method Get -Resource "/groups?`$filter=$filter&`$top=1&`$select=id,displayName"
    if ($existing.value -and $existing.value.Count -gt 0) {
        Write-Log "Group exists: $DisplayName" -Tag "Get"
        return $existing.value[0].id
    }
    $mailNick = (Get-SafeMailNickname -DisplayName $DisplayName) + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $groupBody = @{
        displayName     = $DisplayName
        description     = "Intune app assignment group: $DisplayName"
        mailEnabled     = $false
        mailNickname    = $mailNick
        securityEnabled = $true
        groupTypes      = @()
    }
    Write-Log "Creating group: $DisplayName" -Tag "Run"
    $created = Invoke-GraphApi -Method Post -Resource '/groups' -Body $groupBody
    Write-Log "Created group: $DisplayName (id: $($created.id))" -Tag "Debug"
    return $created.id
}

function Set-AppGroupAssignments {
    param([string]$AppId, [string]$DisplayName)
    $groupNames = Get-ResolvedGroupNames -AppName $DisplayName
    $rqGroupId = Get-OrCreateGroup -DisplayName $groupNames.RQ
    $avGroupId = Get-OrCreateGroup -DisplayName $groupNames.AV
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
    Invoke-GraphApi -Method Post -Resource "/deviceAppManagement/mobileApps/$AppId/assign" -Body $assignBody
    Write-Log "Assigned app to groups: RQ=$($groupNames.RQ), AV=$($groupNames.AV)" -Tag "Debug"
    Write-Log "Assigned groups to app" -Tag "Success"
}

# ---------------------------[ Check if app exists ]---------------------------
function Test-AppExists {
    param([string]$DisplayName)
    try {
        $escapedName = $DisplayName -replace "'", "''"
        $odataFilter = [uri]::EscapeDataString("displayName eq '$escapedName'")
        $response = Invoke-GraphApi -Method Get -Resource "/deviceAppManagement/mobileApps?`$filter=$odataFilter&`$top=1&`$select=id,displayName"
        return ($response.value -and $response.value.Count -gt 0)
    } catch { return $false }
}

# ---------------------------[ Chunked Azure upload ]---------------------------
function Send-ChunkedUpload {
    param([string]$SasUri, [string]$FilePath, [string]$FileUri = $null)
    $fileSizeBytes = (Get-Item -LiteralPath $FilePath).Length
    $chunkCount = [Math]::Ceiling($fileSizeBytes / $chunkSizeBytes)
    $fileReader = [System.IO.File]::OpenRead($FilePath)
    $renewTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $currentSasUri = $SasUri
    $blockIds = @()
    try {
        for ($chunkIndex = 0; $chunkIndex -lt $chunkCount; $chunkIndex++) {
            $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($chunkIndex.ToString("0000")))
            $blockIds += $blockId
            $chunkLength = [Math]::Min($chunkSizeBytes, $fileSizeBytes - ($chunkIndex * $chunkSizeBytes))
            $chunkBuffer = New-Object byte[] $chunkLength
            $null = $fileReader.Read($chunkBuffer, 0, $chunkLength)
            $blockUri = "$currentSasUri&comp=block&blockid=$blockId"
            Invoke-RestMethod -Uri $blockUri -Method Put -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body $chunkBuffer -ContentType 'application/octet-stream' -UseBasicParsing
            if ($FileUri -and $chunkIndex -lt ($chunkCount - 1) -and $renewTimer.ElapsedMilliseconds -ge $sasRenewAfterMs) {
                $null = Invoke-GraphApi -Method Post -Resource "$FileUri/renewUpload" -Body '{}'
                $fileResource = Invoke-GraphApi -Method Get -Resource $FileUri
                while ($fileResource.uploadState -eq 'azureStorageUriRenewalPending') {
                    Start-Sleep -Seconds 5
                    $fileResource = Invoke-GraphApi -Method Get -Resource $FileUri
                }
                $currentSasUri = $fileResource.azureStorageUri
                $renewTimer.Restart()
            }
        }
        $blockListUri = "$currentSasUri&comp=blocklist"
        $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
        foreach ($id in $blockIds) { $blockListXml += "<Latest>$id</Latest>" }
        $blockListXml += '</BlockList>'
        Invoke-RestMethod -Uri $blockListUri -Method Put -Body $blockListXml -ContentType 'application/xml' -UseBasicParsing
    } finally { $fileReader.Dispose() }
}

# ---------------------------[ Main deploy ]---------------------------
function Deploy-Win32App {
    param([string]$AppFolderPath, [string]$AppName)
    $infoPath = Join-Path $AppFolderPath 'info.json'
    if (-not (Test-Path -LiteralPath $infoPath)) {
        Write-Log "info.json missing: $AppFolderPath" -Tag "Error"
        return $false
    }
    $appInfo = Get-Content -LiteralPath $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $displayName = if ($appInfo.Name) { $appInfo.Name } else { $AppName }
    $description = if ($appInfo.Description) { $appInfo.Description } else { '' }
    $publisher = if ($appInfo.Publisher) { $appInfo.Publisher } else { '' }
    $informationUrl = if ($appInfo.InformationUrl) { $appInfo.InformationUrl } elseif ($appInfo.PublisherUrl) { $appInfo.PublisherUrl } else { '' }
    $privacyUrl = if ($appInfo.PrivacyUrl) { $appInfo.PrivacyUrl } else { '' }
    $applicableArchitectures = Get-ApplicableArchitectures -AppInfo $appInfo

    if (Test-AppExists -DisplayName $displayName) {
        Write-Log "Skipped (already in Intune): $displayName" -Tag "Info"
        return 'Skipped'
    }

    $intunewinPath = Join-Path $AppFolderPath "$AppName.intunewin"
    if (-not (Test-Path -LiteralPath $intunewinPath)) {
        $intunewinCandidates = Get-ChildItem -LiteralPath $AppFolderPath -Filter '*.intunewin' -File -ErrorAction SilentlyContinue
        $intunewinPath = ($intunewinCandidates | Select-Object -First 1).FullName
    }
    if (-not $intunewinPath -or -not (Test-Path -LiteralPath $intunewinPath)) {
        Write-Log "No .intunewin in $AppFolderPath" -Tag "Error"
        return $false
    }

    $detectionPath = Join-Path $AppFolderPath 'detection.ps1'
    if (-not (Test-Path -LiteralPath $detectionPath)) {
        Write-Log "detection.ps1 missing: $AppFolderPath" -Tag "Error"
        return $false
    }

    Write-Log "Processing: $displayName" -Tag "Info"
    $iconBase64 = Get-IconBase64 -AppName $AppName -IconsFolder $iconsRoot
    if (-not $iconBase64) {
        Write-Log "No icon file retrieved for: $displayName" -Tag "Info"
    }
    $detectionRule = Get-DetectionRuleFromScript -ScriptPath $detectionPath
    $winMetadata = Get-IntuneWinMetadata -IntuneWinPath $intunewinPath

    try {
        # 1. Create Win32 app (no file - Rozemuller style)
        $appBody = New-Win32LobAppBody -DisplayName $displayName -Description $description -Publisher $publisher `
            -InformationUrl $informationUrl -PrivacyUrl $privacyUrl `
            -FileName $winMetadata.FileName -SetupFile $winMetadata.SetupFile -Rules @($detectionRule) `
            -IconBase64 $iconBase64 -ApplicableArchitectures $applicableArchitectures -DisplayVersion 'Winget'

        if ($logDebug) {
            $dumpPath = Join-Path $logFileDirectory 'deploy-request-body.json'
            $appBody | ConvertTo-Json -Depth 15 -Compress:$false | Set-Content -Path $dumpPath -Encoding UTF8
            Write-Log "Request body saved: $dumpPath" -Tag "Debug"
        }

        Write-Log "Creating Win32 app: $displayName" -Tag "Run"
        $createdApp = Invoke-GraphApi -Method Post -Resource '/deviceAppManagement/mobileApps' -Body $appBody
        $appId = $createdApp.id
        Write-Log "Created app id: $appId" -Tag "Success"

        # 2. Request content version
        $versionResource = "/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions"
        $contentVersion = Invoke-GraphApi -Method Post -Resource $versionResource -Body '{}'
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
        $fileResource = Invoke-GraphApi -Method Post -Resource $filesResource -Body $fileBody
        $fileId = $fileResource.id
        $fileUri = "/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$versionId/files/$fileId"

        # 4. Wait for azureStorageUri
        Write-Log "Waiting for Azure Storage URI..." -Tag "Get"
        $fileStatus = Invoke-GraphApi -Method Get -Resource $fileUri
        while ($fileStatus.uploadState -eq 'azureStorageUriRequestPending') {
            Start-Sleep -Seconds 5
            $fileStatus = Invoke-GraphApi -Method Get -Resource $fileUri
        }
        if ($fileStatus.uploadState -ne 'azureStorageUriRequestSuccess') {
            throw "Unexpected upload state: $($fileStatus.uploadState)"
        }
        $sasUri = $fileStatus.azureStorageUri

        # 5. Upload chunked to Azure
        Write-Log "Uploading to Azure Storage..." -Tag "Run"
        Send-ChunkedUpload -SasUri $sasUri -FilePath $winMetadata.EncryptedFilePath -FileUri $fileUri

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
        Invoke-GraphApi -Method Post -Resource "$fileUri/commit" -Body $commitBody
        Write-Log "Waiting for commit..." -Tag "Get"
        $fileStatus = Invoke-GraphApi -Method Get -Resource $fileUri
        while ($fileStatus.uploadState -eq 'commitFilePending') {
            Start-Sleep -Seconds 5
            $fileStatus = Invoke-GraphApi -Method Get -Resource $fileUri
        }
        if ($fileStatus.uploadState -ne 'commitFileSuccess') {
            throw "Commit failed: $($fileStatus.uploadState)"
        }

        # 7. Update app with committed version
        $patchBody = @{
            '@odata.type'             = '#microsoft.graph.win32LobApp'
            committedContentVersion   = $versionId
        }
        Invoke-GraphApi -Method Patch -Resource "/deviceAppManagement/mobileApps/$appId" -Body $patchBody
        Start-Sleep -Seconds $sleepAfterCommitSec

        # 8. Set architectures via enableApplicableArchitectures (Requirements tab)
        $enableArchBody = @{ applicableArchitectures = $applicableArchitectures }
        try {
            Invoke-GraphApi -Method Post -Resource "/deviceAppManagement/mobileApps/$appId/enableApplicableArchitectures" -Body $enableArchBody
            Write-Log "Set architectures: $applicableArchitectures" -Tag "Debug"
        } catch {
            Write-Log "enableApplicableArchitectures failed (non-fatal): $_" -Tag "Debug"
        }

        Write-Log "Deployed: $displayName (id: $appId)" -Tag "Success"

        if ($enableGroupCreation -and -not (Test-AppGroupBlacklisted -DisplayName $displayName)) {
            try {
                Set-AppGroupAssignments -AppId $appId -DisplayName $displayName
            } catch {
                Write-Log "Group creation/assignment failed (non-fatal): $_" -Tag "Error"
            }
        } elseif ($enableGroupCreation -and (Test-AppGroupBlacklisted -DisplayName $displayName)) {
            Write-Log "Skipping group creation (app on blacklist): $displayName" -Tag "Info"
        }

        return $true
    } catch {
        Write-Log "Deploy failed for $displayName : $_" -Tag "Error"
        return $false
    } finally {
        if ($winMetadata.TempDir -and (Test-Path -LiteralPath $winMetadata.TempDir)) {
            Remove-Item -LiteralPath $winMetadata.TempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"
Write-Log "Config: graphBaseUrl=$graphBaseUrl | appsRoot=$appsRoot | enableGroupCreation=$enableGroupCreation | groupNamingAppSuffix=$groupNamingAppSuffix" -Tag "Debug"

if (-not (Test-Path -LiteralPath $appsRoot)) {
    Write-Log "Apps folder not found. Run package.ps1 first." -Tag "Error"
    Complete-Script -ExitCode 1
}

try { Initialize-GraphConnection } catch {
    Write-Log "Graph connection failed: $_" -Tag "Error"
    Complete-Script -ExitCode 1
}

$appDirs = Get-ChildItem -LiteralPath $appsRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'temp' }
$totalFolders = ($appDirs | Measure-Object).Count
if ($totalFolders -eq 0) {
    Write-Log "No app folders found." -Tag "Info"
    Complete-Script -ExitCode 0
}

$deployedCount = 0
$failedCount   = 0
$skippedCount  = 0
foreach ($appDir in $appDirs) {
    $result = Deploy-Win32App -AppFolderPath $appDir.FullName -AppName $appDir.Name
    if ($result -eq $true)        { $deployedCount++ }
    elseif ($result -eq 'Skipped') { $skippedCount++ }
    else                          { $failedCount++ }
}

Write-Log "Deploy summary: $deployedCount succeeded, $skippedCount skipped, $failedCount failed (total folders: $totalFolders)" -Tag "Info"
Complete-Script -ExitCode $(if ($failedCount -gt 0) { 1 } else { 0 })
