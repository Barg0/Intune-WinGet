# ---------------------------[ Script Start Timestamp ]---------------------------
$scriptStartTime = Get-Date

# ---------------------------[ Script Name ]---------------------------
$scriptName  = "Winget"
$logFileName = "install.log"

# ---------------------------[ Configuration ]---------------------------
$githubApiUrl   = "https://api.github.com/repos/microsoft/winget-cli/releases/latest"
$tempDirectory  = "$env:ProgramData\IntuneFiles\Temp\WingetUpdate"
$changesApplied = $false
$rebootRequired = $false

$ProgressPreference = 'SilentlyContinue'

# ---------------------------[ Logging Setup ]---------------------------
$log           = $true
$logDebug      = $false
$logGet        = $true
$logRun        = $true
$enableLogFile = $true

$logFileDirectory = "$env:ProgramData\IntuneLogs\Scripts\$scriptName"
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

# ---------------------------[ Script Start ]---------------------------
Write-Log "======== Script Started ========" -Tag "Start"
Write-Log "ComputerName: $env:COMPUTERNAME | User: $env:USERNAME | Script: $scriptName" -Tag "Info"

# ---------------------------[ Winget Path Resolver ]---------------------------
function Get-WingetPath {
    $wingetBase = "$env:ProgramW6432\WindowsApps"
    Write-Log "Resolving winget path from: $wingetBase" -Tag "Debug"

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
            Write-Log "No matching winget installation folders found (x64 or arm64)" -Tag "Debug"
            return $null
        }

        $latestWingetFolder = $wingetFolders |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1
        Write-Log "Selected folder: $($latestWingetFolder.FullName)" -Tag "Debug"

        $resolvedPath = Join-Path $latestWingetFolder.FullName 'winget.exe'

        if (-not (Test-Path $resolvedPath)) {
            Write-Log "winget.exe not found at expected location: $resolvedPath" -Tag "Debug"
            return $null
        }

        Write-Log "Winget executable path: $resolvedPath" -Tag "Debug"
        return $resolvedPath
    }
    catch {
        Write-Log "Failed to resolve winget path: $_" -Tag "Error"
        Write-Log "Exception type: $($_.Exception.GetType().FullName)" -Tag "Debug"
        return $null
    }
}

# ---------------------------[ Winget Version Check ]---------------------------
function Test-WingetVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WingetPath)

    Write-Log "Testing winget version at: $WingetPath" -Tag "Debug"

    $versionOutput = & $WingetPath --version 2>&1
    $exitCode      = $LASTEXITCODE
    $versionString = ($versionOutput | Out-String).Trim()
    $isHealthy     = ($exitCode -eq 0)

    Write-Log "Winget --version exit code: $exitCode | output: '$versionString' | healthy: $isHealthy" -Tag "Debug"

    return @{
        IsHealthy = $isHealthy
        Version   = $versionString
        ExitCode  = $exitCode
    }
}

# ---------------------------[ GitHub API ]---------------------------
function Get-LatestWingetRelease {
    Write-Log "Querying GitHub API for latest winget release" -Tag "Get"
    Write-Log "URL: $githubApiUrl" -Tag "Debug"

    try {
        $release = Invoke-RestMethod -Uri $githubApiUrl -Method Get -ErrorAction Stop
        $tagName = $release.tag_name
        $version = [Version]($tagName -replace '^v', '')

        Write-Log "Latest release: $tagName (parsed: $version)" -Tag "Debug"

        $assets          = $release.assets
        $msixBundleAsset = $assets | Where-Object { $_.name -match '\.msixbundle$' }         | Select-Object -First 1
        $licenseAsset    = $assets | Where-Object { $_.name -match 'License.*\.xml$' }       | Select-Object -First 1
        $depsJsonAsset   = $assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.json' } | Select-Object -First 1
        $depsZipAsset    = $assets | Where-Object { $_.name -eq 'DesktopAppInstaller_Dependencies.zip' }  | Select-Object -First 1

        $result = [PSCustomObject]@{
            TagName             = $tagName
            Version             = $version
            MsixBundleUrl       = $msixBundleAsset.browser_download_url
            LicenseUrl          = $licenseAsset.browser_download_url
            DependenciesJsonUrl = $depsJsonAsset.browser_download_url
            DependenciesZipUrl  = $depsZipAsset.browser_download_url
        }

        Write-Log "MsixBundle URL:       $($result.MsixBundleUrl)" -Tag "Debug"
        Write-Log "License URL:          $($result.LicenseUrl)" -Tag "Debug"
        Write-Log "Dependencies JSON URL: $($result.DependenciesJsonUrl)" -Tag "Debug"
        Write-Log "Dependencies ZIP URL:  $($result.DependenciesZipUrl)" -Tag "Debug"

        if (-not $result.MsixBundleUrl) { throw "Could not find msixbundle asset in release" }
        if (-not $result.LicenseUrl)    { throw "Could not find License XML asset in release" }

        return $result
    }
    catch {
        Write-Log "Failed to query GitHub API: $_" -Tag "Error"
        throw
    }
}

# ---------------------------[ Dependency Functions ]---------------------------
function Get-RequiredDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Url)

    Write-Log "Downloading dependencies manifest" -Tag "Get"
    Write-Log "URL: $Url" -Tag "Debug"

    try {
        $response     = Invoke-RestMethod -Uri $Url -Method Get -ErrorAction Stop
        $dependencies = $response.Dependencies

        Write-Log "Found $($dependencies.Count) required dependencies:" -Tag "Info"
        foreach ($dep in $dependencies) {
            Write-Log "  - $($dep.Name) v$($dep.Version)" -Tag "Debug"
        }

        return $dependencies
    }
    catch {
        Write-Log "Failed to download dependencies manifest: $_" -Tag "Error"
        throw
    }
}

function Test-DependencyInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RequiredVersion
    )

    Write-Log "Checking dependency: $Name (required: v$RequiredVersion)" -Tag "Debug"

    try {
        $package = Get-AppxPackage -Name $Name -AllUsers -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1

        if ($null -eq $package) {
            Write-Log "  $Name -- not installed" -Tag "Debug"
            return $false
        }

        $installedVersion = [Version]$package.Version
        $required         = [Version]$RequiredVersion
        $isSufficient     = $installedVersion -ge $required

        Write-Log "  $Name -- installed: v$installedVersion | required: v$required | sufficient: $isSufficient" -Tag "Debug"

        return $isSufficient
    }
    catch {
        Write-Log "  Error checking $Name -- $_" -Tag "Error"
        return $false
    }
}

function Install-WingetDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ZipUrl,
        [Parameter(Mandatory)][string]$TempPath
    )

    $zipPath     = Join-Path $TempPath "DesktopAppInstaller_Dependencies.zip"
    $extractPath = Join-Path $TempPath "Dependencies"

    Write-Log "Downloading dependencies ZIP" -Tag "Run"
    Write-Log "URL: $ZipUrl" -Tag "Debug"

    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -ErrorAction Stop
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Log "Downloaded dependencies ZIP: $zipSize MB" -Tag "Debug"

        Write-Log "Extracting to: $extractPath" -Tag "Debug"
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            "AMD64" { "x64" }
            "ARM64" { "arm64" }
            "x86"   { "x86" }
            default { "x64" }
        }
        Write-Log "System architecture: $env:PROCESSOR_ARCHITECTURE -> targeting: $arch" -Tag "Debug"

        $dependencyFiles = Get-ChildItem -Path $extractPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.appx', '.msix') } |
            Where-Object { $_.FullName -match "\\$arch\\" -or $_.Name -match "_${arch}_" }

        if (-not $dependencyFiles -or $dependencyFiles.Count -eq 0) {
            Write-Log "No architecture-specific files found for '$arch', using all available packages" -Tag "Debug"
            $dependencyFiles = Get-ChildItem -Path $extractPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.appx', '.msix') }
        }

        Write-Log "Found $($dependencyFiles.Count) dependency packages to install" -Tag "Info"

        foreach ($file in $dependencyFiles) {
            Write-Log "Installing dependency: $($file.Name)" -Tag "Run"
            try {
                Add-AppxPackage -Path $file.FullName -ErrorAction Stop
                Write-Log "Successfully installed: $($file.Name)" -Tag "Success"
            }
            catch {
                Write-Log "Add-AppxPackage for $($file.Name): $($_.Exception.Message)" -Tag "Debug"
            }
        }

        $script:changesApplied = $true

        $dependencyPaths = @($dependencyFiles | Select-Object -ExpandProperty FullName)
        Write-Log "Returning $($dependencyPaths.Count) dependency paths for provisioning" -Tag "Debug"

        return $dependencyPaths
    }
    catch {
        Write-Log "Failed to install dependencies: $_" -Tag "Error"
        throw
    }
}

# ---------------------------[ Winget Installation ]---------------------------
function Install-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MsixBundleUrl,
        [Parameter(Mandatory)][string]$LicenseUrl,
        [Parameter(Mandatory)][string]$TempPath,
        [string[]]$DependencyPaths = @()
    )

    $msixBundlePath = Join-Path $TempPath "Microsoft.DesktopAppInstaller.msixbundle"
    $licensePath    = Join-Path $TempPath "License1.xml"

    Write-Log "Downloading winget msixbundle" -Tag "Run"
    Write-Log "URL: $MsixBundleUrl" -Tag "Debug"
    try {
        Invoke-WebRequest -Uri $MsixBundleUrl -OutFile $msixBundlePath -ErrorAction Stop
        $bundleSize = [math]::Round((Get-Item $msixBundlePath).Length / 1MB, 2)
        Write-Log "Downloaded msixbundle: $bundleSize MB" -Tag "Debug"
    }
    catch {
        Write-Log "Failed to download msixbundle: $_" -Tag "Error"
        throw
    }

    Write-Log "Downloading license XML" -Tag "Run"
    Write-Log "URL: $LicenseUrl" -Tag "Debug"
    try {
        Invoke-WebRequest -Uri $LicenseUrl -OutFile $licensePath -ErrorAction Stop
        Write-Log "Downloaded license file" -Tag "Debug"
    }
    catch {
        Write-Log "Failed to download license: $_" -Tag "Error"
        throw
    }

    Write-Log "Installing winget via Add-AppxProvisionedPackage" -Tag "Run"
    Write-Log "  PackagePath:       $msixBundlePath" -Tag "Debug"
    Write-Log "  LicensePath:       $licensePath" -Tag "Debug"
    Write-Log "  DependencyPaths:   $($DependencyPaths.Count) file(s)" -Tag "Debug"
    foreach ($depPath in $DependencyPaths) {
        Write-Log "    -> $depPath" -Tag "Debug"
    }

    try {
        $provisionParams = @{
            Online      = $true
            PackagePath = $msixBundlePath
            LicensePath = $licensePath
        }

        if ($DependencyPaths.Count -gt 0) {
            $provisionParams['DependencyPackagePath'] = $DependencyPaths
        }

        Add-AppxProvisionedPackage @provisionParams -ErrorAction Stop
        Write-Log "Winget provisioned successfully" -Tag "Success"
    }
    catch {
        Write-Log "Primary provisioning attempt: $($_.Exception.Message)" -Tag "Debug"
        Write-Log "Retrying without explicit dependency paths" -Tag "Run"

        try {
            Add-AppxProvisionedPackage -Online -PackagePath $msixBundlePath -LicensePath $licensePath -ErrorAction SilentlyContinue
            Write-Log "Winget provisioned via fallback" -Tag "Success"
        }
        catch {
            Write-Log "Fallback provisioning: $($_.Exception.Message)" -Tag "Debug"
        }
    }

    $script:changesApplied = $true
}

# ---------------------------[ SYSTEM PATH Registration ]---------------------------
function Register-WingetDependencyPaths {
    [CmdletBinding()]
    param([string[]]$DependencyNames = @())

    Write-Log "Registering dependency paths in SYSTEM Machine PATH" -Tag "Run"

    $windowsApps = "$env:ProgramW6432\WindowsApps"
    if (-not (Test-Path $windowsApps)) {
        Write-Log "WindowsApps folder not found: $windowsApps" -Tag "Error"
        return
    }

    $searchPatterns = @()
    if ($DependencyNames.Count -gt 0) {
        Write-Log "Using $($DependencyNames.Count) dependency names from manifest" -Tag "Debug"
        $searchPatterns = $DependencyNames
    }
    else {
        Write-Log "No dependency names provided, using common fallback patterns" -Tag "Debug"
        $searchPatterns = @(
            'Microsoft.VCLibs.140.00.UWPDesktop',
            'Microsoft.WindowsAppRuntime',
            'Microsoft.UI.Xaml'
        )
    }

    $pathsToAdd = @()

    foreach ($pattern in $searchPatterns) {
        $folder = Get-ChildItem -Path $windowsApps -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$pattern*_x64__*" } |
            Sort-Object CreationTime -Descending |
            Select-Object -First 1

        if (-not $folder) {
            $folder = Get-ChildItem -Path $windowsApps -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$pattern*_arm64__*" } |
                Sort-Object CreationTime -Descending |
                Select-Object -First 1
        }

        if ($folder) {
            Write-Log "Found: $pattern -> $($folder.FullName)" -Tag "Debug"
            $pathsToAdd += $folder.FullName
        }
        else {
            Write-Log "Not found in WindowsApps: $pattern (checked x64 and arm64)" -Tag "Debug"
        }
    }

    $wingetPath = Get-WingetPath
    if ($wingetPath) {
        $wingetDir = Split-Path $wingetPath -Parent
        Write-Log "Including winget directory: $wingetDir" -Tag "Debug"
        $pathsToAdd += $wingetDir
    }

    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($null -eq $currentPath) { $currentPath = '' }

    $pathModified = $false
    foreach ($entry in $pathsToAdd | Select-Object -Unique) {
        if ($currentPath -notlike "*$entry*") {
            Write-Log "Adding to Machine PATH: $entry" -Tag "Run"
            $currentPath = $currentPath.TrimEnd(';') + ";$entry"
            $pathModified = $true
        }
        else {
            Write-Log "Already in Machine PATH: $entry" -Tag "Debug"
        }
    }

    if ($pathModified) {
        [Environment]::SetEnvironmentVariable('Path', $currentPath, 'Machine')
        Write-Log "Machine PATH updated successfully" -Tag "Success"
        $script:changesApplied = $true
        $script:rebootRequired = $true
    }
    else {
        Write-Log "No PATH changes needed" -Tag "Info"
    }
}

# ---------------------------[ Cleanup ]---------------------------
function Remove-TempFiles {
    if (Test-Path $tempDirectory) {
        Write-Log "Cleaning up temp directory: $tempDirectory" -Tag "Debug"
        try {
            Remove-Item -Path $tempDirectory -Recurse -Force -ErrorAction Stop
            Write-Log "Temp directory removed" -Tag "Debug"
        }
        catch {
            Write-Log "Failed to remove temp directory: $_" -Tag "Debug"
        }
    }
}

# ---------------------------[ Main Logic ]---------------------------
try {
    # Step 1: Query GitHub for latest release
    $latestRelease = Get-LatestWingetRelease
    Write-Log "Latest winget version available: $($latestRelease.Version)" -Tag "Info"

    # Step 2: Create temp directory
    if (-not (Test-Path $tempDirectory)) {
        New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
        Write-Log "Created temp directory: $tempDirectory" -Tag "Debug"
    }

    # Step 3: Check dependencies via JSON manifest
    $dependencyPaths = @()

    if ($latestRelease.DependenciesJsonUrl) {
        $requiredDeps = Get-RequiredDependencies -Url $latestRelease.DependenciesJsonUrl
        $missingDeps  = @()

        foreach ($dep in $requiredDeps) {
            if (-not (Test-DependencyInstalled -Name $dep.Name -RequiredVersion $dep.Version)) {
                $missingDeps += $dep
            }
        }

        Write-Log "Missing dependencies: $($missingDeps.Count) of $($requiredDeps.Count)" -Tag "Info"

        # Step 4: Install missing dependencies (downloads ZIP only if needed)
        if ($missingDeps.Count -gt 0 -and $latestRelease.DependenciesZipUrl) {
            $dependencyPaths = Install-WingetDependencies `
                -ZipUrl $latestRelease.DependenciesZipUrl `
                -TempPath $tempDirectory
        }
        else {
            Write-Log "All dependencies are satisfied" -Tag "Success"
        }
    }
    else {
        Write-Log "Dependencies JSON not available in release, skipping dependency check" -Tag "Info"
    }

    # Step 5: Install winget package
    Install-WingetPackage `
        -MsixBundleUrl $latestRelease.MsixBundleUrl `
        -LicenseUrl $latestRelease.LicenseUrl `
        -TempPath $tempDirectory `
        -DependencyPaths $dependencyPaths

    # Step 6: Register dependency paths in SYSTEM Machine PATH
    $dependencyNames = @()
    if ($requiredDeps) {
        $dependencyNames = @($requiredDeps | ForEach-Object { $_.Name })
    }
    Register-WingetDependencyPaths -DependencyNames $dependencyNames

    # Step 7: Cleanup
    Remove-TempFiles

    # Step 8: Exit with appropriate code
    if ($rebootRequired) {
        Write-Log "SYSTEM PATH was modified, returning exit code 3010 (reboot required)" -Tag "Info"
        Complete-Script -ExitCode 3010
    }
    elseif ($changesApplied) {
        Write-Log "Packages were installed but no PATH changes needed, no reboot required" -Tag "Info"
        Complete-Script -ExitCode 0
    }
    else {
        Write-Log "No changes were applied" -Tag "Info"
        Complete-Script -ExitCode 0
    }
}
catch {
    Write-Log "Fatal error: $_" -Tag "Error"
    Write-Log "Exception type: $($_.Exception.GetType().FullName)" -Tag "Debug"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Tag "Debug"

    Remove-TempFiles
    Complete-Script -ExitCode 1
}
