<#
.SYNOPSIS
    Installs required dependencies as defined in alm-config.psd1 with optional lock file.
.DESCRIPTION
    This script reads the alm-config.psd1 file to determine which PowerShell modules
    and PAC CLI version are needed for the scripts to run.

    It supports version pinning via a scriptDependencies.lock.json file which is used
    for consistent dependency versions in the version that goes into artifacts.

    The versions can be specified as:
    - '' (empty string): installs the latest version
    - 'prerelease': installs the latest prerelease version
    - specific version number (e.g. '1.2.3' or '1.2.3-beta.1'): installs that specific version
#>

. $PSScriptRoot/common.ps1

Write-Host "##[group] Installing Dependencies"

$config = Get-AlmConfig

$lockFile = 'scriptDependencies.lock.json'
if (Test-Path $lockFile) {
    $lockData = Get-Content $lockFile -Raw | ConvertFrom-Json -AsHashtable
    $config.scriptDependencies = $lockData.scriptDependencies
    if ($lockData.ContainsKey('pacCliVersion')) {
        $config.pacCliVersion = $lockData.pacCliVersion
    }
    Write-Host "Using pinned versions from lock file"
}

foreach ($module in $config.scriptDependencies.Keys) {

    $version = $config.scriptDependencies[$module]

    Write-Host "Installing $module module with version specifier: '$version'"
    if ($version -eq '') {
        $installedModule = Install-Module -Name $module -Scope CurrentUser -Force -PassThru
    }
    elseif ($version -eq 'prerelease') {
        $installedModule = Install-Module -Name $module -Scope CurrentUser -Force -AllowPrerelease -PassThru
    }
    else {
        $installedModule = Install-Module -Name $module -Scope CurrentUser -Force -RequiredVersion $version -AllowPrerelease:($version.Contains("-")) -PassThru
    }
    Write-Host "Installed $module version $($installedModule.Version)"
    
    if ($config._defaults.scriptDependencies.ContainsKey($module)) {
        $defaultVersion = $config._defaults.scriptDependencies[$module]
        if (([version] $version) -lt ([version]$defaultVersion)) {
            throw "Installed version $($installedModule.Version) of $module is less than the default minimum required version $defaultVersion. Please update the version in alm-config.psd1."
        }
    }

    # Manually load the installed module to ensure the correct version is used
    # This is complex because Import-Module does not support version ranges or prerelease directly

    # This ensures that we load the exact installed version even when running locally
    # where multiple versions may be present

    $moduletoload = get-installedmodule -Name $module -RequiredVersion $installedModule.Version -AllowPrerelease:($installedModule.Version.Contains("-"))

    if (-not $moduletoload) {
        Write-Host "##[error]Failed to find installed module $module version $($installedModule.Version)"
        
        throw "Failed to find installed module $module version $($installedModule.Version)"
    }
    Import-Module "$($moduletoload.InstalledLocation)/*.psd1"
  
    $loadedModule = Get-Module -Name $module
    Write-Host "Loaded $module version $($loadedModule.Version) $($loadedModule.Prerelease)"
}

$pacCliVersion = ''
if ($config.ContainsKey('pacCliVersion') -and $null -ne $config.pacCliVersion) {
    $pacCliVersion = [string]$config.pacCliVersion
}

$pacToolPath = Join-Path $HOME '.alm4dataverse\tools'
if (-not (Test-Path $pacToolPath)) {
    New-Item -ItemType Directory -Path $pacToolPath -Force | Out-Null
}

$installArgs = @('tool', 'install', 'Microsoft.PowerApps.CLI.Tool', '--tool-path', $pacToolPath)
$updateArgs = @('tool', 'update', 'Microsoft.PowerApps.CLI.Tool', '--tool-path', $pacToolPath)

if ($pacCliVersion -eq 'prerelease') {
    $installArgs += '--prerelease'
    $updateArgs += '--prerelease'
}
elseif (-not [string]::IsNullOrWhiteSpace($pacCliVersion)) {
    $installArgs += @('--version', $pacCliVersion)
    $updateArgs += @('--version', $pacCliVersion)
}

Write-Host "Installing PAC CLI with version specifier: '$pacCliVersion'"

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    throw "dotnet command not found in PATH. dotnet is required to install PAC CLI."
}

$pacExePath = Join-Path $pacToolPath 'pac.exe'
if (Test-Path $pacExePath) {
    & dotnet @updateArgs
    if (-not $?) {
        Write-Host "PAC CLI update failed. Reinstalling..."
        & dotnet tool uninstall Microsoft.PowerApps.CLI.Tool --tool-path $pacToolPath | Out-Null
        & dotnet @installArgs
    }
}
else {
    & dotnet @installArgs
}

if (-not $?) {
    throw "Failed to install PAC CLI."
}

if (-not (($env:PATH -split ';') -contains $pacToolPath)) {
    $env:PATH = "$pacToolPath;$env:PATH"
}

if ($env:GITHUB_PATH) {
    $pacToolPath | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
}

if ($env:TF_BUILD -eq 'True') {
    Write-Host "##vso[task.prependpath]$pacToolPath"
}

if (-not (Test-Path $pacExePath)) {
    throw "PAC CLI installation completed but pac.exe was not found at $pacExePath"
}

$pacVersion = (& $pacExePath --version | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($pacVersion)) {
    throw "PAC CLI installation completed but failed to read installed version."
}
Write-Host "Installed PAC CLI version $pacVersion"

Write-Host "Dependencies Installed"
Write-Host "##[endgroup]"
