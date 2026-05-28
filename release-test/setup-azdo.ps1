
[CmdletBinding()]
param(
    [Parameter()]
    [string]$TenantId,

    [Parameter()]
    [switch]$UseDeviceAuthentication,

    [Parameter()]
    [string]$ALM4DataverseRef
)

$resolveDevRefAfterGitIsAvailable = $false

# ALM4DataverseRef default handling - injected during release, fallback for development
if (-not $ALM4DataverseRef) {
    $injectedRef = 'vtest'
    # Check if placeholder was replaced by comparing if it starts with double underscore
    if ($injectedRef -like '__*') {
        # Placeholders not replaced - development mode.
        # We resolve this after Git is available to support local branch/commit selection.
        $resolveDevRefAfterGitIsAvailable = $true
        Write-Host "Development mode: Will resolve ALM4DataverseRef from current branch/commit after Git is available (fallback: 'stable')." -ForegroundColor Yellow
        $ALM4DataverseRef = 'stable'
    } else {
        # Placeholder was replaced during release - use the injected value
        $ALM4DataverseRef = $injectedRef
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # Suppress progress bars

# This script is designed to be downloadable and self-contained.
# It's therefore quite long, as it includes all necessary functions and logic.
# Version numbers and ALM4Dataverse ref are injected during the release process.

# Any changes must be also reflected in the docs/manual-setup.md file.

# Shared helper functions are loaded from setup-common.ps1 during development
# and embedded during release preparation for the downloadable one-file script.
$setupCommonPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'setup-common.ps1' } else { $null }
if ($setupCommonPath -and (Test-Path -LiteralPath $setupCommonPath)) {
    . $setupCommonPath
}
else {
        function Write-Section {
        param([Parameter(Mandatory)][string]$Message)
    
        Write-Progress -Completed -Activity "Done"
        Clear-Host
        Write-Host "==== $Message ====" -ForegroundColor Cyan
        Write-Host ""
    }
    
    function New-DirectoryIfMissing {
        param([Parameter(Mandatory)][string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
    
    function Select-FromMenu {
        <#
        .SYNOPSIS
            Simple interactive console menu selection using PSMenu.
    
        .DESCRIPTION
            Arrow keys to move, Enter to select, Esc to cancel.
    
            This function wraps the PSMenu module's Show-Menu function.
        #>
    
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Title,
            [Parameter(Mandatory)][string[]]$Items
        )
    
        if ($Items.Count -eq 0) { return $null }
    
        Write-Host $Title -ForegroundColor Green
        Write-Host ""
    
        $selectedIndex = Show-Menu -MenuItems $Items -ReturnIndex
        return $selectedIndex
    }
    
    function Read-YesNo {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Prompt,
            [Parameter()][switch]$DefaultNo
        )
    
        $suffix = if ($DefaultNo) { ' [y/N]' } else { ' [Y/n]' }
        $answer = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return (-not $DefaultNo)
        }
        return ($answer.Trim().ToLowerInvariant() -in @('y', 'yes'))
    }
    
    function ConvertFrom-GitRefToBranchName {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Ref
        )
    
        if ($Ref -match '^refs/heads/(.+)$') {
            return $Matches[1]
        }
        return $Ref
    }
    
    function ConvertTo-UrlSafeName {
        <#
        .SYNOPSIS
            Converts a name to a URL-safe format for use in federated identity credential names.
    
        .DESCRIPTION
            Replaces characters that are not safe in URL segments with hyphens.
            Allowed characters are: A-Z, a-z, 0-9, and hyphens.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Name
        )
    
        $safeName = $Name -replace '[^a-zA-Z0-9-]', '-'
        $safeName = $safeName -replace '-+', '-'
        $safeName = $safeName.Trim('-')
    
        return $safeName
    }
    
    function ConvertTo-NormalizedEnvironmentUrl {
        [CmdletBinding()]
        param(
            [Parameter()][string]$Url
        )
    
        if ([string]::IsNullOrWhiteSpace($Url)) {
            return $null
        }
    
        $trimmedUrl = $Url.Trim()
        $uri = $null
        if (-not [System.Uri]::TryCreate($trimmedUrl, [System.UriKind]::Absolute, [ref]$uri)) {
            return $trimmedUrl.TrimEnd('/')
        }
    
        if ($uri.Scheme -notin @('http', 'https')) {
            return $trimmedUrl.TrimEnd('/')
        }
    
        return $uri.GetLeftPart([System.UriPartial]::Authority)
    }
    
    function Test-IsValidTenantIdentifier {
        <#
        .SYNOPSIS
            Validates an Entra tenant identifier.
    
        .DESCRIPTION
            Accepts either a tenant GUID or a tenant domain name
            (for example contoso.onmicrosoft.com).
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$TenantIdentifier
        )
    
        $value = $TenantIdentifier.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $false
        }
    
        $isGuid = $value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
        $isDns = $value -match '^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$'
    
        return ($isGuid -or $isDns)
    }
    
    function Assert-ValidTenantIdentifier {
        <#
        .SYNOPSIS
            Throws when an Entra tenant identifier is invalid.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$TenantIdentifier,
            [Parameter()][string]$Source = 'TenantId'
        )
    
        if (-not (Test-IsValidTenantIdentifier -TenantIdentifier $TenantIdentifier)) {
            throw "$Source value '$TenantIdentifier' is invalid. Use a tenant GUID or tenant domain (for example, contoso.onmicrosoft.com)."
        }
    }
    
    function Get-Alm4DataverseRefForDocs {
        [CmdletBinding()]
        param(
            [Parameter()][string]$Ref
        )
    
        if (-not [string]::IsNullOrWhiteSpace($Ref)) {
            return $Ref
        }
    
        $resolvedRef = $null
        try {
            $resolvedRef = Get-Variable -Name 'ALM4DataverseRef' -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
        }
        catch {
            $resolvedRef = $null
        }
    
        if ([string]::IsNullOrWhiteSpace($resolvedRef)) {
            return 'stable'
        }
    
        return $resolvedRef
    }
    
    function Get-Alm4DataverseDocUrl {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$RelativePath,
            [Parameter()][string]$Ref
        )
    
        $effectiveRef = Get-Alm4DataverseRefForDocs -Ref $Ref
        $normalizedPath = $RelativePath.TrimStart('/').Replace('\', '/')
        return "https://github.com/ALM4Dataverse/ALM4Dataverse/tree/$effectiveRef/$normalizedPath"
    }
    
    function Write-SetupGuidance {
        [CmdletBinding()]
        param(
            [Parameter()][string[]]$Lines,
            [Parameter()][string]$DocRelativePath,
            [Parameter()][string]$Ref,
            [Parameter()][string]$LinkLabel = 'Full docs'
        )
    
        foreach ($line in @($Lines)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host $line -ForegroundColor Green
            }
        }
    
        if (-not [string]::IsNullOrWhiteSpace($DocRelativePath)) {
            $docUrl = Get-Alm4DataverseDocUrl -RelativePath $DocRelativePath -Ref $Ref
            Write-Host "${LinkLabel}: $docUrl" -ForegroundColor Green
        }
    
        Write-Host ""
    }
    
    function Read-TextWithDefault {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Prompt,
            [Parameter()][string]$DefaultValue,
            [Parameter()][switch]$AllowEmpty
        )
    
        while ($true) {
            $displayPrompt = $Prompt
            if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
                $displayPrompt = "$Prompt [$DefaultValue]"
            }
    
            $value = Read-Host $displayPrompt
            if ([string]::IsNullOrWhiteSpace($value)) {
                if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
                    return $DefaultValue
                }
                if ($AllowEmpty) {
                    return ''
                }
    
                Write-Warning "A value is required. Please try again."
                continue
            }
    
            return $value.Trim()
        }
    }
    
    function Get-DefaultSetupBranchName {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$BaseBranch,
            [Parameter()][string]$Context = 'setup'
        )
    
        $safeContext = ConvertTo-UrlSafeName -Name $Context
        if ([string]::IsNullOrWhiteSpace($safeContext)) {
            $safeContext = 'setup'
        }
    
        $safeBaseBranch = ConvertTo-UrlSafeName -Name $BaseBranch
        if ([string]::IsNullOrWhiteSpace($safeBaseBranch)) {
            $safeBaseBranch = 'main'
        }
    
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')
        return "alm4dataverse/$safeContext-$safeBaseBranch-$timestamp"
    }
    
    function Get-RepoChangePublishPlan {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$ProviderName,
            [Parameter(Mandatory)][string]$RepositoryName,
            [Parameter(Mandatory)][string]$BaseBranch,
            [Parameter(Mandatory)][string]$DefaultCommitMessage,
            [Parameter(Mandatory)][string]$DefaultPullRequestTitle,
            [Parameter()][string]$DefaultPullRequestDescription,
            [Parameter()][string[]]$GuidanceLines,
            [Parameter()][string]$DocRelativePath,
            [Parameter()][string]$Ref
        )
    
        $defaultGuidance = @(
            "Choose how the generated pipeline/workflow/config changes should be published to '$RepositoryName'.",
            "Direct commit is fastest when you want the automation live immediately on the chosen branch.",
            "Branch + pull request is the safer option when branch protection, mandatory reviews, or change-control checks apply."
        )
    
        Write-Host ""
        Write-SetupGuidance -Lines @($defaultGuidance + @($GuidanceLines)) -DocRelativePath $DocRelativePath -Ref $Ref
    
        $menuItems = @(
            "Commit directly to '$BaseBranch'",
            'Commit directly to another branch',
            "Push a branch and open a pull request into '$BaseBranch'"
        )
    
        $selection = Select-FromMenu -Title "How should the $ProviderName repository changes be published?" -Items $menuItems
        if ($null -eq $selection) {
            throw "No repository publish option selected."
        }
    
        switch ($selection) {
            0 {
                return [pscustomobject]@{
                    Mode                   = 'Direct'
                    BranchName             = $BaseBranch
                    TargetBranch           = $BaseBranch
                    CommitMessage          = $DefaultCommitMessage
                    PullRequestTitle       = $null
                    PullRequestDescription = $null
                }
            }
            1 {
                $directBranch = Read-TextWithDefault -Prompt 'Branch to commit to' -DefaultValue $BaseBranch
                return [pscustomobject]@{
                    Mode                   = 'Direct'
                    BranchName             = $directBranch
                    TargetBranch           = $directBranch
                    CommitMessage          = $DefaultCommitMessage
                    PullRequestTitle       = $null
                    PullRequestDescription = $null
                }
            }
            2 {
                $defaultBranchName = Get-DefaultSetupBranchName -BaseBranch $BaseBranch -Context $RepositoryName
                $sourceBranch = Read-TextWithDefault -Prompt 'Branch to push for the pull request' -DefaultValue $defaultBranchName
                $prTitle = Read-TextWithDefault -Prompt 'Pull request title' -DefaultValue $DefaultPullRequestTitle
    
                return [pscustomobject]@{
                    Mode                   = 'PullRequest'
                    BranchName             = $sourceBranch
                    TargetBranch           = $BaseBranch
                    CommitMessage          = $DefaultCommitMessage
                    PullRequestTitle       = $prTitle
                    PullRequestDescription = $DefaultPullRequestDescription
                }
            }
        }
    }
    
    function Get-CredentialSummaryText {
        [CmdletBinding()]
        param(
            [Parameter()]$Credentials
        )
    
        if ($null -eq $Credentials) {
            return ''
        }
    
        $name = ''
        if ($Credentials.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace($Credentials.Name)) {
            $name = [string]$Credentials.Name
        }
        elseif ($Credentials.PSObject.Properties.Name -contains 'ApplicationId' -and -not [string]::IsNullOrWhiteSpace($Credentials.ApplicationId)) {
            $name = [string]$Credentials.ApplicationId
        }
    
        if ($Credentials.PSObject.Properties.Name -contains 'IsExistingServiceConnection' -and $Credentials.IsExistingServiceConnection) {
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                return "Existing service connection • $name"
            }
            return 'Existing service connection'
        }
    
        $authType = 'Credential'
        if ($Credentials.PSObject.Properties.Name -contains 'AuthType' -and -not [string]::IsNullOrWhiteSpace($Credentials.AuthType)) {
            $authType = [string]$Credentials.AuthType
        }
    
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return "$authType • $name"
        }
    
        return $authType
    }
    
    function Show-EnvironmentConfigurationTable {
        [CmdletBinding()]
        param(
            [Parameter()][array]$EnvironmentConfigurations
        )
    
        $items = @($EnvironmentConfigurations)
        if ($items.Count -eq 0) {
            Write-Host 'No environments selected.' -ForegroundColor DarkGray
            return
        }
    
        $rows = foreach ($env in $items) {
            $serviceAccountUPN = ''
            if ($env.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($env.ServiceAccountUPN)) {
                $serviceAccountUPN = [string]$env.ServiceAccountUPN
            }
    
            [pscustomobject]@{
                ShortName      = [string]$env.ShortName
                FriendlyName   = [string]$env.FriendlyName
                Url            = [string]$env.Url
                Credential     = Get-CredentialSummaryText -Credentials $env.Credentials
                ServiceAccount = $serviceAccountUPN
            }
        }
    
        $rows | Format-Table -Property ShortName, FriendlyName, Url, Credential, ServiceAccount -Wrap -AutoSize | Out-Host
    }
    
    function Select-OrderedSolutions {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][array]$AvailableSolutions,
            [Parameter()][array]$InitiallySelectedSolutions
        )
    
        $selectedSolutions = @()
        if ($InitiallySelectedSolutions) {
            $selectedSolutions += @($InitiallySelectedSolutions)
        }
    
        while ($true) {
            Clear-Host
            Write-Host 'Solutions Configuration' -ForegroundColor Cyan
            Write-Host '=======================' -ForegroundColor Cyan
            Write-Host ''
    
            if ($selectedSolutions.Count -eq 0) {
                Write-Host 'No solutions selected.' -ForegroundColor DarkGray
            }
            else {
                Write-Host 'Selected solutions (in dependency order):' -ForegroundColor Green
                $selectedSolutions | Select-Object @{ N = 'Friendly Name'; E = { $_.friendlyname } }, @{ N = 'Unique Name'; E = { $_.uniquename } }, Version | Format-Table -AutoSize | Out-Host
            }
            Write-Host ''
    
            $menuItems = @('Add a solution', 'Clear list')
            if ($selectedSolutions.Count -gt 0) {
                $menuItems += 'Done'
            }
    
            $selection = Select-FromMenu -Title 'Manage solutions' -Items $menuItems
    
            if ($null -eq $selection) {
                return @($selectedSolutions)
            }
    
            switch ($menuItems[$selection]) {
                'Add a solution' {
                    $available = @($AvailableSolutions | Where-Object {
                        $uniqueName = $_.uniquename
                        -not ($selectedSolutions | Where-Object { $_.uniquename -eq $uniqueName })
                    })
    
                    if ($available.Count -eq 0) {
                        Write-Host 'All solutions already selected.' -ForegroundColor Yellow
                        Start-Sleep -Seconds 2
                        continue
                    }
    
                    $solMenu = @($available | ForEach-Object { "$($_.friendlyname) ($($_.uniquename))" })
                    $solMenu += '--- Cancel ---'
    
                    $solIndex = Select-FromMenu -Title 'Select a solution to add' -Items $solMenu
                    if ($null -ne $solIndex -and $solIndex -lt $available.Count) {
                        $selectedSolutions += $available[$solIndex]
                    }
                }
                'Clear list' {
                    $selectedSolutions = @()
                    Write-Host 'List cleared.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
                'Done' {
                    return @($selectedSolutions)
                }
            }
        }
    }
    
    function Set-AlmConfigSolutionsInFile {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$ConfigPath,
            [Parameter(Mandatory)][array]$Solutions,
            [Parameter()][switch]$CreateIfMissing,
            [Parameter()][string]$TemplatePath
        )
    
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            if (-not $CreateIfMissing) {
                throw "alm-config.psd1 not found: $ConfigPath"
            }
    
            if (-not [string]::IsNullOrWhiteSpace($TemplatePath) -and (Test-Path -LiteralPath $TemplatePath)) {
                Copy-Item -LiteralPath $TemplatePath -Destination $ConfigPath -Force
            }
            else {
                $initialContent = "@{`n    solutions = @(`n    )`n}`n"
                Set-Content -LiteralPath $ConfigPath -Value $initialContent -NoNewline
            }
        }
    
        $configContent = Get-Content -LiteralPath $ConfigPath -Raw
    
        $solutionsArray = "@("
        if ($Solutions.Count -gt 0) {
            $solutionsArray += "`n"
            foreach ($solution in $Solutions) {
                $escapedSolutionName = ([string]$solution.name).Replace("'", "''")
                $solutionsArray += "        @{`n"
                $solutionsArray += "            name = '$escapedSolutionName'`n"
                if ($solution.deployUnmanaged) {
                    $solutionsArray += "            deployUnmanaged = `$true`n"
                }
                $solutionsArray += "        }`n"
            }
            $solutionsArray += "    )"
        }
        else {
            $solutionsArray += "`n    )"
        }
    
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($configContent, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors -and $parseErrors.Count -gt 0) {
            throw "Could not parse existing alm-config.psd1 '$ConfigPath': $($parseErrors[0].Message)"
        }
    
        $rootHashtable = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.HashtableAst]
        }, $false)
    
        if (-not $rootHashtable) {
            throw "Could not find the root hashtable in '$ConfigPath'."
        }
    
        $solutionsEntry = $rootHashtable.KeyValuePairs | Where-Object {
            $keyText = $_.Item1.Extent.Text.Trim()
            $keyText -in @('solutions', "'solutions'", '"solutions"')
        } | Select-Object -First 1
    
        if ($solutionsEntry) {
            $valueExtent = $solutionsEntry.Item2.Extent
            $updatedContent = $configContent.Substring(0, $valueExtent.StartOffset) + $solutionsArray + $configContent.Substring($valueExtent.EndOffset)
        }
        else {
            $insertOffset = $rootHashtable.Extent.EndOffset - 1
            $lineEnding = if ($configContent -match "`r`n") { "`r`n" } else { "`n" }
            $insertText = "$lineEnding    solutions = $solutionsArray$lineEnding"
            $updatedContent = $configContent.Substring(0, $insertOffset) + $insertText + $configContent.Substring($insertOffset)
        }
    
        $hasChanges = ($updatedContent -ne $configContent)
        if ($hasChanges) {
            Set-Content -LiteralPath $ConfigPath -Value $updatedContent -NoNewline
        }
    
        return $hasChanges
    }
    
    function Select-ConfiguredDeploymentEnvironments {
        [CmdletBinding()]
        param(
            [Parameter()][array]$InitialEnvironments,
            [Parameter(Mandatory)][scriptblock]$AddEnvironmentScriptBlock,
            [Parameter()][scriptblock]$EditEnvironmentScriptBlock,
            [Parameter()][string]$Heading = 'Target Deployment Environments',
            [Parameter()][string]$Title = 'Manage deployment environments',
            [Parameter()][string[]]$GuidanceLines,
            [Parameter()][string]$DocRelativePath,
            [Parameter()][string]$Ref
        )
    
        $selectedEnvironments = @()
        if ($InitialEnvironments) {
            $selectedEnvironments += @($InitialEnvironments)
        }
    
        while ($true) {
            Clear-Host
            Write-Host $Heading -ForegroundColor Cyan
            Write-Host ('=' * $Heading.Length) -ForegroundColor Cyan
            Write-Host ''
    
            if ($GuidanceLines -or $DocRelativePath) {
                Write-SetupGuidance -Lines $GuidanceLines -DocRelativePath $DocRelativePath -Ref $Ref
            }
    
            Show-EnvironmentConfigurationTable -EnvironmentConfigurations $selectedEnvironments
            Write-Host ''
    
            $menuItems = @('Add an environment', 'Clear list')
            if ($selectedEnvironments.Count -gt 0) {
                if ($EditEnvironmentScriptBlock) {
                    $menuItems += 'Edit an environment'
                }
                $menuItems += 'Done'
            }
    
            $selection = Select-FromMenu -Title $Title -Items $menuItems
            if ($null -eq $selection) {
                return @($selectedEnvironments)
            }
    
            switch ($menuItems[$selection]) {
                'Add an environment' {
                    $newEnvironment = & $AddEnvironmentScriptBlock @($selectedEnvironments)
                    if ($null -ne $newEnvironment) {
                        $selectedEnvironments += $newEnvironment
                    }
                }
                'Clear list' {
                    $selectedEnvironments = @()
                    Write-Host 'List cleared.' -ForegroundColor Yellow
                    Start-Sleep -Seconds 1
                }
                'Edit an environment' {
                    $environmentMenuItems = @()
                    for ($i = 0; $i -lt $selectedEnvironments.Count; $i++) {
                        $environment = $selectedEnvironments[$i]
                        $shortName = [string]$environment.ShortName
                        $friendlyName = if ([string]::IsNullOrWhiteSpace($environment.FriendlyName)) { $shortName } else { [string]$environment.FriendlyName }
                        $url = if ([string]::IsNullOrWhiteSpace($environment.Url)) { '<not set>' } else { [string]$environment.Url }
                        $environmentMenuItems += "$shortName - $friendlyName ($url)"
                    }
    
                    $editSelection = Select-FromMenu -Title 'Select the environment to edit' -Items $environmentMenuItems
                    if ($null -eq $editSelection) {
                        continue
                    }
    
                    $updatedEnvironment = & $EditEnvironmentScriptBlock @($selectedEnvironments) $selectedEnvironments[$editSelection] $editSelection
                    if ($null -ne $updatedEnvironment) {
                        $selectedEnvironments[$editSelection] = $updatedEnvironment
                    }
                }
                'Done' {
                    return @($selectedEnvironments)
                }
            }
        }
    }
    
    function Get-ModulePathDelimiter {
        return [System.IO.Path]::PathSeparator
    }
    
    function Install-NuGetProviderIfMissing {
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuget) {
            Write-Host "Installing NuGet package provider (required for Save-Module)..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        }
    }
    
    function Get-ModuleAvailableExact {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$RequiredVersion
        )
    
        $mods = Get-Module -Name $Name -ListAvailable -ErrorAction SilentlyContinue
        if (-not $mods) { return $null }
    
        return $mods | Where-Object { $_.Version -eq [version]$RequiredVersion } | Select-Object -First 1
    }
    
    function Save-ModuleExact {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$RequiredVersion,
            [Parameter(Mandatory)][string]$Destination
        )
    
        Install-NuGetProviderIfMissing
    
        Write-Host "Downloading $Name $RequiredVersion to $Destination" -ForegroundColor Yellow
        Save-Module -Name $Name -RequiredVersion $RequiredVersion -Path $Destination -Force
    }
    
    function Import-RequiredModuleVersion {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$RequiredVersion,
            [Parameter(Mandatory)][string]$Destination
        )
    
        $targetVersion = $RequiredVersion
    
        $available = Get-ModuleAvailableExact -Name $Name -RequiredVersion $targetVersion
        if (-not $available) {
            Save-ModuleExact -Name $Name -RequiredVersion $targetVersion -Destination $Destination
            $available = Get-ModuleAvailableExact -Name $Name -RequiredVersion $targetVersion
            if (-not $available) {
                throw "Module $Name $targetVersion was downloaded but is still not discoverable on PSModulePath."
            }
        }
    
        Import-Module -Name $Name -RequiredVersion $targetVersion -Force -ErrorAction Stop
        $loaded = Get-Module -Name $Name | Where-Object { $_.Version -eq [version]$targetVersion } | Select-Object -First 1
        if (-not $loaded) {
            throw "Failed to import $Name version $targetVersion. Loaded version: $((Get-Module -Name $Name | Select-Object -First 1).Version)"
        }
    
        Write-Host "Loaded $Name $($loaded.Version)"
    }
    
    function Resolve-DevelopmentDefaultAlm4DataverseRef {
        [CmdletBinding()]
        param(
            [Parameter()][string]$PrimaryRepositoryPath,
            [Parameter()][string]$FallbackRef = 'stable'
        )
    
        $candidateRepos = @()
        foreach ($candidate in @($PrimaryRepositoryPath, $PSScriptRoot)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $candidateRepos += $candidate
            }
        }
        $candidateRepos = @($candidateRepos | Select-Object -Unique)
    
        foreach ($repoPath in $candidateRepos) {
            $gitDir = Join-Path $repoPath '.git'
            if (-not (Test-Path -LiteralPath $gitDir)) {
                continue
            }
    
            try {
                $branch = (& git -C $repoPath branch --show-current 2>$null).Trim()
                if (-not [string]::IsNullOrWhiteSpace($branch)) {
                    Write-Host "Development mode: Using current local branch '$branch' as ALM4DataverseRef" -ForegroundColor Yellow
                    return $branch
                }
    
                $commit = (& git -C $repoPath rev-parse HEAD 2>$null).Trim()
                if ($commit -match '^[0-9a-f]{40}$') {
                    Write-Host "Development mode: Repository is in detached HEAD; using commit '$commit' as ALM4DataverseRef" -ForegroundColor Yellow
                    return $commit
                }
            }
            catch {
                throw "Could not resolve development ALM4DataverseRef from '$repoPath': $($_.Exception.Message)"
            }
        }
    
        Write-Host "Development mode: Could not resolve current branch/commit. Using '$FallbackRef' as ALM4DataverseRef" -ForegroundColor Yellow
        return $FallbackRef
    }
    
    function Invoke-WithErrorHandling {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][scriptblock]$ScriptBlock,
            [Parameter(Mandatory)][string]$OperationName,
            [Parameter()][switch]$AllowSkip
        )
    
        while ($true) {
            try {
                return & $ScriptBlock
            }
            catch {
                Write-Host "`n" -NoNewline
                Write-Host "ERROR in $OperationName" -ForegroundColor Red -BackgroundColor Black
                Write-Host "="*80 -ForegroundColor Red
                Write-Host "Error Type: $($_.Exception.GetType().Name)" -ForegroundColor Yellow
                Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Yellow
    
                if ($_.ScriptStackTrace) {
                    Write-Host "`nStack Trace:" -ForegroundColor DarkGray
                    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
                }
    
                if ($_.InvocationInfo.PositionMessage) {
                    Write-Host "`nLocation:" -ForegroundColor DarkGray
                    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
                }
    
                Write-Host "="*80 -ForegroundColor Red
                Write-Host ""
    
                $options = @('Retry')
                if ($AllowSkip) {
                    $options += 'Skip (Not Recommended)'
                }
                $options += 'Abort Setup'
    
                $choice = Select-FromMenu -Title "How would you like to proceed?" -Items $options
    
                if ($null -eq $choice) {
                    Write-Host "Setup aborted by user." -ForegroundColor Yellow
                    throw "Setup aborted by user."
                }
    
                switch ($options[$choice]) {
                    'Retry' {
                        Write-Host "Retrying $OperationName..." -ForegroundColor Cyan
                        continue
                    }
                    'Skip (Not Recommended)' {
                        Write-Host "Skipping $OperationName. This may cause issues later." -ForegroundColor Yellow
                        return $null
                    }
                    'Abort Setup' {
                        Write-Host "Setup aborted by user." -ForegroundColor Yellow
                        throw "Setup aborted by user after error in $OperationName"
                    }
                }
            }
        }
    }
    
    function Get-AuthToken {
        param(
            [Parameter(Mandatory)][string]$ResourceUrl,
            [Parameter()][string]$TenantId,
            [Parameter()][string]$ClientId = '1950a258-227b-4e31-a9cf-717495945fc2',
            [Parameter()][switch]$ForceInteractive,
            [Parameter()][string]$PreferredUsername,
            [Parameter()][switch]$ListAccountsOnly
        )
    
        [void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.Identity.Client")
    
        try {
            [void][Microsoft.Identity.Client.PublicClientApplicationBuilder]
        }
        catch {
            Write-Host "Type not found, attempting to load from module..." -ForegroundColor Yellow
            $module = Get-Module -Name "Rnwood.Dataverse.Data.PowerShell"
            if ($module) {
                $base = $module.ModuleBase
                $dllPath = $null
    
                if ($PSVersionTable.PSEdition -eq 'Core') {
                    $dllPath = Join-Path $base "cmdlets\net8.0\Microsoft.Identity.Client.dll"
                    if (-not (Test-Path $dllPath)) {
                        $dllPath = Join-Path $base "cmdlets\netcoreapp3.1\Microsoft.Identity.Client.dll"
                    }
                }
                else {
                    $dllPath = Join-Path $base "cmdlets\net462\Microsoft.Identity.Client.dll"
                }
    
                if ($dllPath -and (Test-Path $dllPath)) {
                    Write-Host "Loading MSAL from: $dllPath" -ForegroundColor DarkGray
                    Add-Type -Path $dllPath
                }
                else {
                    $allDlls = Get-ChildItem $base -Recurse -Filter "Microsoft.Identity.Client.dll"
                    $found = $null
                    if ($PSVersionTable.PSEdition -eq 'Core') {
                        $found = $allDlls | Where-Object { $_.FullName -match 'netcore|netstandard|net\d\.\d' } | Select-Object -First 1
                    }
                    else {
                        $found = $allDlls | Where-Object { $_.FullName -match 'net4' } | Select-Object -First 1
                    }
    
                    if ($found) {
                        Write-Host "DLL found recursively at: $($found.FullName)" -ForegroundColor Yellow
                        Add-Type -Path $found.FullName
                    }
                }
            }
        }
    
        $ResourceUrl = $ResourceUrl.TrimEnd('/')
        $scopes = [string[]]@("$ResourceUrl/.default")
    
        $app = $null
        try {
            $app = Get-Variable -Name "MsalApp" -Scope Script -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Value
        }
        catch {
            $app = $null
        }
    
        if (-not $app) {
            $builder = [Microsoft.Identity.Client.PublicClientApplicationBuilder]::Create($ClientId)
    
            $authority = "https://login.microsoftonline.com/common"
            if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
                $authority = "https://login.microsoftonline.com/$TenantId"
            }
    
            $builder = $builder.WithAuthority($authority)
            $builder = $builder.WithRedirectUri("http://localhost")
            $app = $builder.Build()
    
            Set-Variable -Name "MsalApp" -Value $app -Scope Script
        }
    
        $msalCacheDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ALM4Dataverse'
        New-DirectoryIfMissing -Path $msalCacheDir
        $msalCachePath = Join-Path $msalCacheDir 'msal-token-cache.bin'
    
        try {
            if (Test-Path -LiteralPath $msalCachePath) {
                $cacheBytes = [System.IO.File]::ReadAllBytes($msalCachePath)
                if ($cacheBytes -and $cacheBytes.Length -gt 0) {
                    $app.UserTokenCache.DeserializeMsalV3($cacheBytes, $true)
                }
            }
        }
        catch {
            Write-Warning "Failed to load MSAL token cache from '$msalCachePath': $($_.Exception.Message)"
        }
    
        $accounts = @($app.GetAccountsAsync().GetAwaiter().GetResult())
    
        if ($ListAccountsOnly) {
            return @($accounts | ForEach-Object { $_.Username } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        }
    
        $account = $null
        if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
            $account = $accounts | Where-Object { $_.Username -ieq $PreferredUsername } | Select-Object -First 1
            if (-not $account) {
                Write-Host "Preferred cached Azure login '$PreferredUsername' was not found; using the default cached account selection." -ForegroundColor Yellow
            }
        }
    
        if (-not $account) {
            $account = $accounts | Select-Object -First 1
        }
    
        $authResult = $null
    
        try {
            if (-not $ForceInteractive -and $account) {
                $authResult = $app.AcquireTokenSilent($scopes, $account).ExecuteAsync().GetAwaiter().GetResult()
            }
        }
        catch {
            # Silent acquisition failed, try interactive.
        }
    
        if (-not $authResult) {
            try {
                $interactiveBuilder = $app.AcquireTokenInteractive($scopes)
    
                if ($ForceInteractive) {
                    $interactiveBuilder = $interactiveBuilder.WithPrompt([Microsoft.Identity.Client.Prompt]::SelectAccount)
                }
    
                if (-not [string]::IsNullOrWhiteSpace($PreferredUsername)) {
                    $interactiveBuilder = $interactiveBuilder.WithLoginHint($PreferredUsername)
                }
    
                $authResult = $interactiveBuilder.ExecuteAsync().GetAwaiter().GetResult()
            }
            catch {
                Write-Error "Failed to acquire token interactively: $_"
                throw
            }
        }
    
        try {
            $updatedCacheBytes = $app.UserTokenCache.SerializeMsalV3()
            if ($updatedCacheBytes -and $updatedCacheBytes.Length -gt 0) {
                [System.IO.File]::WriteAllBytes($msalCachePath, $updatedCacheBytes)
            }
        }
        catch {
            Write-Warning "Failed to save MSAL token cache to '$msalCachePath': $($_.Exception.Message)"
        }
    
        return $authResult
    }
    
    function New-EntraIdApplicationSecret {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$ApplicationObjectId,
            [Parameter(Mandatory)][string]$TenantId,
            [Parameter()][string]$DisplayName = 'ALM4Dataverse Setup'
        )
    
        $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
        $headers = @{
            Authorization  = "Bearer $($graphToken.AccessToken)"
            'Content-Type' = 'application/json'
        }
    
        $secretBody = @{
            passwordCredential = @{
                displayName = $DisplayName
            }
        }
    
        $secretUri = "https://graph.microsoft.com/v1.0/applications/$ApplicationObjectId/addPassword"
        $secretResponse = Invoke-RestMethod -Uri $secretUri -Headers $headers -Method Post -Body ($secretBody | ConvertTo-Json)
        return $secretResponse.secretText
    }
    
}

#region Initialization

function Install-PortableGit {
    param(
        [Parameter(Mandatory)][string]$Destination
    )

    $gitDir = Join-Path $Destination "Git"
    $gitExe = Join-Path $gitDir "bin\git.exe"
    
    if (Test-Path $gitExe) {
        Write-Host "Git already available at: $gitExe"
        return $gitDir
    }

    Write-Host "Downloading portable Git..." -ForegroundColor Yellow
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v2.52.0.windows.1/PortableGit-2.52.0-64-bit.7z.exe"
    $gitInstaller = Join-Path $Destination "PortableGit.exe"
    
    try {
        # PowerShell 5.1 sometimes needs TLS 1.2 explicitly.
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            }
        }
        catch {
            # Non-fatal; continue.
        }

        Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing
        
        if (-not (Test-Path $gitInstaller)) {
            throw "Failed to download Git installer"
        }

        Write-Host "Extracting portable Git to $gitDir..." -ForegroundColor Yellow
        New-DirectoryIfMissing -Path $gitDir
        
        # The .7z.exe is a self-extracting archive
        $extractArgs = @('-o"' + $gitDir + '"', '-y')
        $process = Start-Process -FilePath $gitInstaller -ArgumentList $extractArgs -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -ne 0) {
            throw "Git extraction failed with exit code $($process.ExitCode)"
        }

        # Clean up installer
        Remove-Item $gitInstaller -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path $gitExe)) {
            throw "Git extraction completed but git.exe not found at expected location"
        }

        Write-Host "Git extracted successfully to: $gitDir"
        return $gitDir
    }
    catch {
        Write-Host "Failed to install portable Git: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

Write-Section "Initialising setup"

$TempModuleRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ALM4Dataverse\Modules"
New-DirectoryIfMissing -Path $TempModuleRoot

$delim = Get-ModulePathDelimiter
if (-not ($env:PSModulePath -split [Regex]::Escape($delim) | Where-Object { $_ -eq $TempModuleRoot })) {
    $env:PSModulePath = "$TempModuleRoot$delim$env:PSModulePath"
}

Write-Host "Using temp module root: $TempModuleRoot"

# Version numbers are injected during release process
# For development/testing, fall back to reading from config file if placeholders are present
$rnwoodDataverseVersion = '3.0.3'
# Check if placeholder was replaced by comparing if it starts with double underscore
if ($rnwoodDataverseVersion -like '__*') {
    # Placeholders not replaced - must be running from repository for development
    $configPath = Join-Path $PSScriptRoot 'alm-config-defaults.psd1'
    if (Test-Path $configPath) {
        Write-Host "Development mode: Reading version from $configPath" -ForegroundColor Yellow
        $config = Import-PowerShellDataFile -Path $configPath
        $rnwoodDataverseVersion = $config.scriptDependencies.'Rnwood.Dataverse.Data.PowerShell'
    } else {
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-azdo.ps1"
    }
}

# Upstream repository URL is injected during release process
# For development/testing, use local workspace path or fallback to GitHub
$upstreamRepo = 'https://github.com/ALM4Dataverse/ALM4Dataverse.git'
# Check if placeholder was replaced by comparing if it starts with double-underscore
if ($upstreamRepo -like '__*') {
    # Placeholders not replaced - must be running from repository for development
    if ($PSScriptRoot) {
        Write-Host "Development mode: Using local workspace path as upstream repo" -ForegroundColor Yellow
        $upstreamRepo = $PSScriptRoot
    } else {
        Write-Host "Development mode: Using default GitHub URL as upstream repo" -ForegroundColor Yellow
        $upstreamRepo = 'https://github.com/ALM4Dataverse/ALM4Dataverse.git'
    }
}

$requiredModules = @{
    'VSTeam'                           = '7.15.2'
    'PSMenu'                           = '0.2.0'
    'Rnwood.Dataverse.Data.PowerShell' = $rnwoodDataverseVersion
}

# Ensure modules are downloaded before loading so we can patch them
foreach ($modName in $requiredModules.Keys) {
    $version = $requiredModules[$modName]
    if (-not (Get-ModuleAvailableExact -Name $modName -RequiredVersion $version)) {
        Save-ModuleExact -Name $modName -RequiredVersion $version -Destination $TempModuleRoot
    }
}

foreach ($modName in $requiredModules.Keys) {
    $version = $requiredModules[$modName]
    Import-RequiredModuleVersion -Name $modName -RequiredVersion $version -Destination $TempModuleRoot
}

# Download and install portable Git
$gitInstallDir = Install-PortableGit -Destination $TempModuleRoot
$gitBinDir = Join-Path $gitInstallDir "bin"

# Add Git to PATH for this session
if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $gitBinDir })) {
    $env:PATH = "$gitBinDir;$env:PATH"
}

# Verify Git is now available
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "Git was installed but is still not available in PATH"
}

Write-Host "Git is now available: $($git.Source)"
Write-Host "Version: $(git --version)"

if ($resolveDevRefAfterGitIsAvailable) {
    $ALM4DataverseRef = Resolve-DevelopmentDefaultAlm4DataverseRef -PrimaryRepositoryPath $upstreamRepo -FallbackRef $ALM4DataverseRef
    Write-Host "Development mode: Resolved ALM4DataverseRef to '$ALM4DataverseRef'" -ForegroundColor Yellow
}

Write-Section "Authenticating"

Write-Host "To enable automated setup setup, we need to authenticate with the necessary services." -ForegroundColor Green
Write-Host ""
Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
Write-Host "- Your Azure DevOps organization/project (PROJECT administrator role for existing project, ORGANISATION OWNER role if you want to create a new project)" -ForegroundColor Green
Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
Write-Host ""

# Azure DevOps resource for AAD token acquisition.
$adoResourceUrl = '499b84ac-1321-427f-aa17-267ca6975798'

$cachedAzureAccounts = @(Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -ListAccountsOnly)
$preferredAzureUsername = $null
$forceAzureInteractive = $false

if ($cachedAzureAccounts.Count -gt 0) {
    $azureAuthMenuItems = @($cachedAzureAccounts | ForEach-Object { "Use existing Azure login: $_" })
    $azureAuthMenuItems += "Sign in with a different Azure account"

    $azureAuthChoice = Select-FromMenu -Title "Azure authentication" -Items $azureAuthMenuItems
    if ($null -eq $azureAuthChoice) {
        throw "No Azure authentication option selected."
    }

    if ($azureAuthChoice -lt $cachedAzureAccounts.Count) {
        $preferredAzureUsername = $cachedAzureAccounts[$azureAuthChoice]
        Write-Host "Using cached Azure login: $preferredAzureUsername" -ForegroundColor Green
    }
    else {
        $forceAzureInteractive = $true
        Read-Host "Press Enter to open browser for authentication..."
    }
}
else {
    Write-Host "No cached Azure login detected. Browser sign-in is required." -ForegroundColor Yellow
    Read-Host "Press Enter to open browser for authentication..."
}

$authResult = Invoke-WithErrorHandling -OperationName "Authentication" -ScriptBlock {
    $result = Get-AuthToken -ResourceUrl $adoResourceUrl -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive
    
    if (-not $result -or -not $result.AccessToken) {
        throw "Failed to acquire an Azure DevOps access token."
    }
    
    return $result
}

$adoAuthResult = $authResult
$adoAccessToken = [pscustomobject]@{ Token = $adoAuthResult.AccessToken }
$secureToken = ConvertTo-SecureString -String $adoAccessToken.Token -AsPlainText -Force

#endregion

#region Azure DevOps Setup

function ConvertTo-AzDoOrganizationName {
    param([Parameter(Mandatory)][string]$InputText)

    $text = $InputText.Trim()

    # Accept:
    # - myorg
    # - https://dev.azure.com/myorg
    # - https://dev.azure.com/myorg/
    # - dev.azure.com/myorg
    if ($text -match 'dev\.azure\.com/([^/]+)') {
        return $Matches[1]
    }

    # Also accept legacy Visual Studio URLs like https://myorg.visualstudio.com
    if ($text -match '^https?://([^\.]+)\.visualstudio\.com/?$') {
        return $Matches[1]
    }

    return $text
}

function New-AzDoProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$Visibility = 'private'
    )

    $ProjectName = $ProjectName.Trim()
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw "Project name cannot be empty."
    }

    Write-Section "Creating new Azure DevOps project"
    Write-Host "Project: $ProjectName" -ForegroundColor Cyan

    $processes = @(Get-VSTeamProcess)
    if ($processes.Count -eq 0) {
        throw "Unable to list Azure DevOps processes to create a project. Verify permissions in the organization."
    }

    # Prefer Agile if present, otherwise first.
    $defaultProcess = $processes | Where-Object { $_.name -eq 'Agile' } | Select-Object -First 1
    if (-not $defaultProcess) {
        $defaultProcess = $processes | Select-Object -First 1
    }

    $processNames = @($processes | Sort-Object -Property name | ForEach-Object { $_.name })
    $selectedProcessName = $defaultProcess.name

    # Let user choose the process template.
    $procIndex = Select-FromMenu -Title "Select a process (template) for the new project" -Items $processNames
    if ($null -ne $procIndex) {
        $selectedProcessName = $processNames[$procIndex]
    }

    $selectedProcess = $processes | Where-Object { $_.name -eq $selectedProcessName } | Select-Object -First 1
    if (-not $selectedProcess -or -not $selectedProcess.id) {
        throw "Unable to resolve selected process '$selectedProcessName'."
    }

    # Use VSTeam command to create project - it handles async operation polling automatically
    Write-Host "Creating project using process template: $selectedProcessName" -ForegroundColor Yellow
    
    try {
        # Note: Add-VSTeamProject uses -ProjectName instead of -Name and doesn't have VersionControlSource
        $addParams = @{
            ProjectName     = $ProjectName
            ProcessTemplate = $selectedProcessName
            Visibility      = $Visibility
        }
        
        
        $created = Add-VSTeamProject @addParams
        
        if ($created -and $created.name) {
            Write-Host "Project '$ProjectName' created successfully."
            return $created
        }
        else {
            throw "Project creation returned no result."
        }
    }
    catch {
        Write-Host "Failed to create project '$ProjectName': $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Test-AzDoGitRepositoryHasCommits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    # Use VSTeam command to get commits - if repo is empty, no commits are returned
    try {
        $commits = @(Get-VSTeamGitCommit -ProjectName $Project -RepositoryId $RepositoryId -Top 1 -ErrorAction SilentlyContinue)
        return ($commits.Count -gt 0)
    }
    catch {
        # If we can't get commits, assume empty repo
        return $false
    }
}

function Start-AzDoGitRepositoryImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceGitUrl
    )

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import directly
    $resource = "git/repositories/$RepositoryId/importRequests"
    $body = @{
        parameters = @{
            gitSource = @{
                url = $SourceGitUrl
            }
        }
    }
    return Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1'
}

function Wait-AzDoGitRepositoryImport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][object]$ImportResponse,
        [Parameter()][int]$TimeoutSeconds = 600
    )

    $importId = $null
    foreach ($prop in @('importRequestId', 'id', 'ImportRequestId')) {
        if ($ImportResponse.PSObject.Properties.Name -contains $prop) {
            $importId = $ImportResponse.$prop
            if ($importId) { break }
        }
    }

    if (-not $importId) {
        throw "Unable to determine import request ID from response."
    }

    # Use Invoke-VSTeamRequest since VSTeam doesn't support repository import status directly
    $resource = "git/repositories/$RepositoryId/importRequests/$importId"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        
        $status = Invoke-VSTeamRequest -Method GET -Resource $resource -Version '7.1-preview.1'

        if (-not $status) { continue }

        $state = $null
        foreach ($prop in @('status', 'state')) {
            if ($status.PSObject.Properties.Name -contains $prop) {
                $state = $status.$prop
                if ($state) { break }
            }
        }

        if ($state) {
            Write-Host "Import status: $state" -ForegroundColor DarkGray
        }

        if ($state -in @('completed', 'succeeded', 'success')) {
            return $status
        }
        if ($state -in @('failed', 'rejected', 'canceled', 'cancelled')) {
            $details = $status | ConvertTo-Json -Depth 20
            throw "Repository import did not succeed. Status: $state. Details: $details"
        }
    }

    throw "Timed out waiting for repository import to complete after $TimeoutSeconds seconds."
}

Write-Section "Select Azure DevOps organization"

# Use direct REST API to get organizations (VSTeam requires an org to connect to first)
$orgData = Invoke-WithErrorHandling -OperationName "Discovering Azure DevOps Organizations" -ScriptBlock {
    $headers = @{
        Authorization = "Bearer $($adoAccessToken.Token)"
    }

    # Get current user profile to obtain member ID
    $profileUrl = "https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=6.0"
    $profileResponse = Invoke-RestMethod -Uri $profileUrl -Method Get -Headers $headers
    
    $memberId = $profileResponse.publicAlias
    if (-not $memberId) {
        $memberId = $profileResponse.id
    }
    if (-not $memberId) {
        throw "Unable to determine memberId from profile response."
    }
   
    $accountsUrl = "https://app.vssps.visualstudio.com/_apis/accounts?memberId=$memberId&api-version=6.0"
    $accountsResponse = Invoke-RestMethod -Uri $accountsUrl -Method Get -Headers $headers
    
    $orgs = @($accountsResponse.value)
    
    if ($orgs.Count -eq 0) {
        throw "No Azure DevOps organizations were returned for this user."
    }

    $orgsSorted = $orgs | Sort-Object -Property accountName
    $orgNames = @($orgsSorted | ForEach-Object { $_.accountName })
    
    return @{
        Orgs = $orgsSorted
        OrgNames = $orgNames
    }
}

$orgsSorted = $orgData.Orgs
$orgNames = $orgData.OrgNames

$orgIndex = 0
$orgIndex = Select-FromMenu -Title "Select an Azure DevOps organization" -Items $orgNames
if ($null -eq $orgIndex) {
    Write-Host "No organization selected." -ForegroundColor Yellow
    return
}

$orgName = $orgNames[$orgIndex]
$orgId = $orgsSorted[$orgIndex].accountId
$orgUri = $orgsSorted[$orgIndex].accountUri
Write-Host "Selected organization: $orgName"
if ($orgUri) {
    Write-Host "Organization URI: $orgUri" -ForegroundColor DarkGray
}

# VSTeam expects -Account to be the org name (not the full URL).
Set-VSTeamAccount -Account $orgName -SecurePersonalAccessToken $secureToken -UseBearerToken -Force
Write-Host "VSTeam configured for organization '$orgName' using a bearer token."

function Initialize-AzDoProjectAndRepositories {
    [CmdletBinding()]
    param()

    Write-Section "Select target Azure DevOps Project"

    Write-SetupGuidance -Lines @(
        "Choose the long-lived Azure DevOps project that will host your repos, pipelines, service connections, and approvals.",
        "Best practice: avoid phase-specific project names so you do not paint future-you into a corner."
    ) -DocRelativePath 'docs/setup/azdo-automated-setup.md' -Ref $ALM4DataverseRef

    $azDevOpsAccessToken = $adoAccessToken.Token

    $projects = Get-VSTeamProject
    $projectNames = @()
    if ($projects) {
        $projectNames = @($projects | ForEach-Object { $_.Name })
    }

    $menuItems = $projectNames + @('Create a new project')
    $index = Select-FromMenu -Title "Select the target Azure DevOps project" -Items $menuItems

    if ($null -eq $index) {
        Write-Host "No project selected." -ForegroundColor Yellow
        return $null
    }

    if ($index -eq ($menuItems.Count - 1)) {
        $name = Read-Host 'Enter the name for the new Azure DevOps project'

        $created = New-AzDoProject -Organization $orgName -ProjectName $name -Visibility private

        $projects = Get-VSTeamProject
        $selectedProject = $null

        if ($projects) {
            $selectedProject = $projects | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        }
        if (-not $selectedProject -and $created -and $created.name) {
            $selectedProject = [pscustomobject]@{ Name = $created.name; Id = $created.id }
        }
        if (-not $selectedProject) {
            throw "Project creation completed, but the project could not be resolved for selection."
        }

        Write-Host "Created and selected project: $($selectedProject.Name)"
    }
    else {
        $selectedProject = $projects[$index]
        Write-Host "Selected project: $($selectedProject.Name)"
    }

    if (Get-Command -Name Set-VSTeamDefaultProject -ErrorAction SilentlyContinue) {
        Set-VSTeamDefaultProject -Project $selectedProject.Name | Out-Null
        Write-Host "Default VSTeam project set to '$($selectedProject.Name)'."
    }

    $mainRepo = Select-AzDoMainRepository -ProjectName $selectedProject.Name

    $script:mainRepoBranch = 'main'
    if ($mainRepo.defaultBranch) {
        $script:mainRepoBranch = ConvertFrom-GitRefToBranchName -Ref $mainRepo.defaultBranch
    }

    $script:devEnvironmentShortName = "Dev-$script:mainRepoBranch"

    $mainRepoWorkingTree = New-AzDoRepoWorkingTree -TargetRepo $mainRepo -AccessToken $azDevOpsAccessToken -PreferredBranch 'main'
    $mainRepoWorkingRoot = $mainRepoWorkingTree.Path

    Write-Section "Ensuring Needed Extensions are Enabled"

    Write-SetupGuidance -Lines @(
        "ALM4Dataverse extension mode enables Workload Identity Federation and the ALM4Dataverse Set Connection Variables task.",
        "Disable it only if you specifically want the Power Platform Build Tools secret-based fallback path."
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef

    $existingExtensionMode = Get-AzDoExtensionModeFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
    if ($existingExtensionMode.IsConfigured -and -not $existingExtensionMode.HasConflict) {
        $script:useAlm4DataverseExtension = $existingExtensionMode.UseAlm4DataverseExtension
        $modeLabel = if ($script:useAlm4DataverseExtension) { 'enabled' } else { 'disabled' }
        $sourceSummary = @($existingExtensionMode.SourceFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
        if ([string]::IsNullOrWhiteSpace($sourceSummary)) {
            Write-Host "Detected existing ALM4Dataverse extension mode: $modeLabel" -ForegroundColor Cyan
        }
        else {
            Write-Host "Detected existing ALM4Dataverse extension mode: $modeLabel (from $sourceSummary)" -ForegroundColor Cyan
        }
    }
    else {
        if ($existingExtensionMode.HasConflict) {
            $sourceSummary = @($existingExtensionMode.SourceFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
            $conflictSuffix = if ([string]::IsNullOrWhiteSpace($sourceSummary)) { '' } else { " ($sourceSummary)" }
            Write-Warning "Existing pipeline YAML files disagree on ALM4Dataverse extension mode$conflictSuffix. Please choose the desired mode."
        }

        $script:useAlm4DataverseExtension = Read-YesNo -Prompt "Use ALM4Dataverse AzDO extension? (required for Workload Identity Federation)"
    }

    if (-not $script:useAlm4DataverseExtension) {
        Write-Host "ALM4Dataverse extension mode disabled. Setup will use the PPBT Set Connection Variables task for service-connection-based client secret auth." -ForegroundColor Yellow
    }

    $requiredExtensions = @(
        "microsoft-IsvExpTools.PowerPlatform-BuildTools"
    )

    if ($script:useAlm4DataverseExtension) {
        $requiredExtensions += "ALM4Dataverse.alm4dataverse-azdo-extensions"
    }

    foreach ($requiredExtension in $requiredExtensions) {
        $parts = $requiredExtension -split '\.'
        $publisherId = $parts[0]
        $extensionId = $parts[1..($parts.Length - 1)] -join '.'

        Invoke-WithErrorHandling -OperationName "Installing extension '$requiredExtension'" -ScriptBlock {
            $installedExtensions = Get-VSTeamExtension
            $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }

            if ($installed) {
                Write-Host "Extension '$requiredExtension' is already installed (Version: $($installed.version))."
            }
            else {
                if (-not (Read-YesNo -Prompt "Extension '$requiredExtension' not found. Install it?")) {
                    throw "Extension '$requiredExtension' is required. Setup cannot continue without it."
                }
                Write-Host "Extension '$requiredExtension' not found. Installing..." -ForegroundColor Yellow
                Write-Host "This may require organization administrative permissions." -ForegroundColor Yellow

                Install-VSTeamExtension -PublisherId $publisherId -ExtensionId $extensionId

                $installedExtensions = Get-VSTeamExtension
                $installed = $installedExtensions | Where-Object { $_.publisherId -eq $publisherId -and $_.extensionId -eq $extensionId }

                if ($installed) {
                    Write-Host "Extension '$requiredExtension' installed successfully (Version: $($installed.version))."
                }
                else {
                    Write-Host "Please install the extension manually from:" -ForegroundColor Yellow
                    Write-Host "https://marketplace.visualstudio.com/acquisition?itemName=$requiredExtension" -ForegroundColor Yellow
                    throw "Failed to verify extension '$requiredExtension' installation after install command completed."
                }
            }
        } | Out-Null
    }

    $existingSharedRepoName = Get-AzDoSharedRepositoryNameFromWorkingTree -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch
    if (-not [string]::IsNullOrWhiteSpace($existingSharedRepoName)) {
        Write-Host "Existing shared repository detected from pipeline YAML: $existingSharedRepoName" -ForegroundColor DarkGray
    }

    Write-Section "Selecting shared Git repository"

    $repo = Select-AzDoSharedRepository -ProjectName $selectedProject.Name -PreferredRepositoryName $existingSharedRepoName -ExcludeRepositoryName $mainRepo.Name
    $sharedRepoName = $repo.Name

    try {
        [void]$Host.UI.RawUI
    }
    catch {
        throw "This script must be run in an interactive PowerShell session."
    }

    Write-Section "Creating/updating shared repository '$sharedRepoName'"

    $hasCommits = Test-AzDoGitRepositoryHasCommits -Organization $orgName -Project $selectedProject.Name -RepositoryId $repo.Id
    $justInitialized = $false
    if (-not $hasCommits) {
        $justInitialized = Invoke-WithErrorHandling -OperationName "Initializing Shared Repository" -ScriptBlock {
            Write-Host "Repository '$sharedRepoName' has no commits. Seeding it from the upstream repo..." -ForegroundColor Yellow

            $sharedSourceUrl = $upstreamRepo
            $destUrl = $repo.remoteUrl
            if (-not $destUrl) {
                throw "Could not determine remoteUrl for repository '$sharedRepoName'."
            }

            $workRoot = Join-Path $env:TEMP ("ALM4Dataverse-Init-" + [guid]::NewGuid().ToString('n'))
            New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

            try {
                Push-Location $workRoot

                & git init --initial-branch=main | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git init failed with exit code $LASTEXITCODE" }

                & git remote add origin $sharedSourceUrl | Out-Null
                & git fetch origin | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git fetch failed with exit code $LASTEXITCODE" }

                & git ls-remote --exit-code origin $ALM4DataverseRef | Out-Null
                if ($LASTEXITCODE -eq 2) {
                    throw "Could not resolve reference '$ALM4DataverseRef' from upstream repository."
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Git ls-remote failed with exit code $LASTEXITCODE"
                }

                $lsRemoteOutput = (& git ls-remote origin $ALM4DataverseRef | Select-Object -First 1)
                if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
                    $commitSha = $Matches[1]
                    $fullRef = $Matches[2]
                    if ($fullRef -match '^refs/heads/(.+)$') {
                        $targetRef = "origin/$($Matches[1])"
                    }
                    elseif ($fullRef -match '^refs/tags/') {
                        $targetRef = $commitSha
                    }
                    else {
                        $targetRef = $ALM4DataverseRef
                    }
                }
                else {
                    $targetRef = $ALM4DataverseRef
                }

                & git checkout -b main $targetRef | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Git checkout failed with exit code $LASTEXITCODE" }

                & git remote set-url origin $destUrl | Out-Null
                & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push -u origin main
                if ($LASTEXITCODE -ne 0) { throw "Git push failed with exit code $LASTEXITCODE" }

                Write-Host "Shared repository initialized successfully."
                return $true
            }
            finally {
                if ((Get-Location).Path -eq $workRoot) { Pop-Location }
                try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }

    if (-not $justInitialized) {
        $sharedSourceUrl = $upstreamRepo
        $destUrl = $repo.remoteUrl
        if (-not $destUrl) {
            throw "Could not determine remoteUrl for repository '$sharedRepoName'."
        }

        $workRoot = Join-Path $env:TEMP ("ALM4Dataverse-Check-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

        try {
            Write-Host "Checking shared repository status against shared repo..." -ForegroundColor DarkGray

            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $destUrl $workRoot | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone failed with exit code $LASTEXITCODE"
            }

            Push-Location $workRoot

            & git remote add upstream $sharedSourceUrl | Out-Null
            & git fetch upstream | Out-Null

            & git ls-remote --exit-code upstream $ALM4DataverseRef | Out-Null
            if ($LASTEXITCODE -eq 2) {
                throw "Could not resolve reference '$ALM4DataverseRef' from upstream repository."
            }
            if ($LASTEXITCODE -ne 0) {
                throw "Git ls-remote failed with exit code $LASTEXITCODE"
            }

            $lsRemoteOutput = (& git ls-remote upstream $ALM4DataverseRef | Select-Object -First 1)
            if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
                $commitSha = $Matches[1]
                $fullRef = $Matches[2]
                if ($fullRef -match '^refs/heads/(.+)$') {
                    $targetRef = "upstream/$($Matches[1])"
                }
                elseif ($fullRef -match '^refs/tags/') {
                    $targetRef = $commitSha
                }
                else {
                    $targetRef = $ALM4DataverseRef
                }
            }
            else {
                $targetRef = $ALM4DataverseRef
            }
            $upstreamRef = $targetRef

            $localHash = (& git rev-parse HEAD).Trim()
            $upstreamHash = (& git rev-parse $upstreamRef).Trim()

            if ($localHash -eq $upstreamHash) {
                Write-Host "Shared repository is already up to date."
            }
            else {
                & git merge-base --is-ancestor HEAD $upstreamRef
                $canFastForward = ($LASTEXITCODE -eq 0)

                if ($canFastForward) {
                    if (Read-YesNo -Prompt "Updates are available from the shared repo (fast-forward). Update '$sharedRepoName'?" ) {
                        Write-Host "Fast-forwarding..." -ForegroundColor Yellow
                        & git merge --ff-only $upstreamRef
                        if ($LASTEXITCODE -ne 0) { throw "Git merge failed" }

                        & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push origin
                        if ($LASTEXITCODE -ne 0) { throw "Git push failed" }

                        Write-Host "Repository updated successfully."
                    }
                }
                else {
                    & git merge-base --is-ancestor $upstreamRef HEAD
                    $isAhead = ($LASTEXITCODE -eq 0)

                    if ($isAhead) {
                        Write-Host "Shared repository is ahead of the shared repo."
                    }
                    else {
                        $divergedMenuItems = @(
                            "Rebase '$sharedRepoName' onto ref '$ALM4DataverseRef'",
                            "Reset '$sharedRepoName' to ref '$ALM4DataverseRef' (force push)",
                            "Leave '$sharedRepoName' unchanged"
                        )
                        $divergedSelection = Select-FromMenu -Title "The shared repo '$sharedRepoName' has diverged. Choose how to update it." -Items $divergedMenuItems

                        switch ($divergedSelection) {
                            0 {
                                Write-Host "Rebasing..." -ForegroundColor Yellow
                                & git rebase $upstreamRef
                                if ($LASTEXITCODE -ne 0) { throw "Git rebase failed - this script can't handle conflicts. You need to rebase your local changes manually." }

                                Write-Host "Pushing rebased branch (force-with-lease)..." -ForegroundColor Yellow
                                & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                                if ($LASTEXITCODE -ne 0) { throw "Git push failed" }

                                Write-Host "Repository updated successfully."
                            }
                            1 {
                                Write-Host "Resetting shared repository to ref '$ALM4DataverseRef' and force pushing..." -ForegroundColor Yellow
                                & git reset --hard $upstreamRef
                                if ($LASTEXITCODE -ne 0) { throw "Git reset failed" }

                                & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" push --force-with-lease origin
                                if ($LASTEXITCODE -ne 0) { throw "Git push failed" }

                                Write-Host "Repository updated successfully."
                            }
                            default {
                                Write-Host "Leaving shared repository unchanged." -ForegroundColor Yellow
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Host "Failed to check or update repository: $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
        finally {
            if ((Get-Location).Path -eq $workRoot) { Pop-Location }
            try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    return [pscustomobject]@{
        SelectedProject      = $selectedProject
        MainRepo             = $mainRepo
        MainRepoWorkingTree  = $mainRepoWorkingTree
        MainRepoWorkingRoot  = $mainRepoWorkingRoot
        SharedRepo           = $repo
        SharedRepoName       = $sharedRepoName
    }
}

#endregion

#region Dataverse Environment Selection Helper

function Select-DataverseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Prompt = "Select a Dataverse environment",
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl
    )

    Write-Host "Listing Dataverse environments..." -ForegroundColor Yellow

    # Get all environments using Get-DataverseEnvironment
    $environments = @(Get-DataverseEnvironment -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource
        return $auth.AccessToken
    })

    if (-not $environments -or $environments.Count -eq 0) {
        throw "No Dataverse environments found for this user."
    }

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    # Filter out excluded URL if provided
    if ($ExcludeUrl) {
        $environments = @($environments | Where-Object { 
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl 
        })
        if ($environments.Count -eq 0) {
            throw "No environments available after filtering."
        }
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $menuItems += "Use existing environment: $($preferredEnvironment.FriendlyName) - $($preferredEnvironment.UniqueName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            $menuActions += $preferredEnvironment

            $environments = @($environments | Where-Object {
                (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
            })
        }
    }

    foreach ($env in $environments) {
        $webUrl = $env.Endpoints["WebApplication"]
        $menuItems += "$($env.FriendlyName) - $($env.UniqueName) ($webUrl)"
        $menuActions += $env
    }

    # Show menu
    $selectedIndex = Select-FromMenu -Title $Prompt -Items $menuItems
    if ($null -eq $selectedIndex) {
        return $null
    }

    return $menuActions[$selectedIndex]
}

#endregion

#region Pipeline Setup

function Select-AzDoMainRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$SharedRepositoryName
    )

    Write-Section "Selecting main Git repository"

    $repos = @(Get-VSTeamGitRepository -ProjectName $ProjectName)
    # 'Main' repo is the user's application repo (not the shared ALM4Dataverse repo)
    $reposSorted = @($repos | Sort-Object -Property Name)

    $repoNames = @($reposSorted | ForEach-Object { $_.Name })
    if (-not [string]::IsNullOrWhiteSpace($SharedRepositoryName)) {
        $repoNames = @($repoNames | Where-Object { $_ -ne $SharedRepositoryName })
    }
    $menu = @($repoNames + @('Create a new repository'))

    Write-Host "Select the repository where you want to set up pipelines:" -ForegroundColor Green

    $selectedIndex = Select-FromMenu -Title "Select the repo" -Items $menu
    if ($null -eq $selectedIndex) {
        throw "No main repository selected."
    }

    if ($selectedIndex -eq ($menu.Count - 1)) {
        $newRepoName = Read-Host "Enter the name for the new main repository"
        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            throw "Repository name cannot be empty."
        }

        Write-Host "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ForegroundColor Yellow
        $created = Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        if (-not $created -or -not $created.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }
        Write-Host "Created repository '$newRepoName'."
        return $created
    }

    $selectedName = $menu[$selectedIndex]
    $selected = $reposSorted | Where-Object { $_.Name -eq $selectedName } | Select-Object -First 1
    if (-not $selected -or -not $selected.Id) {
        throw "Failed to resolve selected repository '$selectedName'."
    }

    Write-Host "Selected main repository: $($selected.Name)"
    return $selected
}

function Resolve-EntraIdApplicationByAppId {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ApplicationId,
        [Parameter()][string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ApplicationId) -or [string]::IsNullOrWhiteSpace($TenantId)) {
        return $null
    }

    if (-not (Get-Variable -Name 'entraApplicationCache' -Scope Script -ErrorAction SilentlyContinue)) {
        $script:entraApplicationCache = @{}
    }

    $cacheKey = "$TenantId|$ApplicationId"
    if ($script:entraApplicationCache.ContainsKey($cacheKey)) {
        return $script:entraApplicationCache[$cacheKey]
    }

    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $TenantId
    $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$ApplicationId'&`$select=id,appId,displayName"

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $application = $response.value | Select-Object -First 1
        $script:entraApplicationCache[$cacheKey] = $application
        return $application
    }
    catch {
        Write-Warning "Failed to resolve App Registration '$ApplicationId' from Entra ID: $($_.Exception.Message)"
        $script:entraApplicationCache[$cacheKey] = $null
        return $null
    }
}

function Get-AzDoSharedRepositoryNameFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $candidateFiles = @(
        (Join-Path $RepoRoot 'pipelines/BUILD.yml'),
        (Join-Path $RepoRoot 'pipelines/EXPORT.yml'),
        (Join-Path $RepoRoot 'pipelines/IMPORT.yml'),
        (Join-Path $RepoRoot "pipelines/DEPLOY-$Branch.yml")
    )

    foreach ($candidateFile in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidateFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $candidateFile -Raw
        $match = [regex]::Match($content, 'repository:\s*ALM4Dataverse\s+type:\s*git\s+name:\s*([^\r\n]+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            return $match.Groups[1].Value.Trim().Trim('"', "'")
        }
    }

    return $null
}

function Get-AzDoDeploymentEnvironmentNamesFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $deployPath = Join-Path $RepoRoot "pipelines/DEPLOY-$Branch.yml"
    if (-not (Test-Path -LiteralPath $deployPath)) {
        return @()
    }

    $content = Get-Content -LiteralPath $deployPath -Raw
    $envMatches = [regex]::Matches($content, 'environmentName:\s*([^\s\r\n]+)')
    $environmentNames = @()
    foreach ($envMatch in $envMatches) {
        $environmentName = $envMatch.Groups[1].Value.Trim().Trim('"', "'")
        if (-not [string]::IsNullOrWhiteSpace($environmentName) -and $environmentNames -notcontains $environmentName) {
            $environmentNames += $environmentName
        }
    }

    return @($environmentNames)
}

function Get-AzDoExtensionModeFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    $candidateFiles = @(
        (Join-Path $RepoRoot 'pipelines/EXPORT.yml'),
        (Join-Path $RepoRoot 'pipelines/IMPORT.yml'),
        (Join-Path $RepoRoot "pipelines/DEPLOY-$Branch.yml")
    )

    $detectedValues = @()
    foreach ($candidateFile in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidateFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $candidateFile -Raw
        $extensionMatches = [regex]::Matches($content, '(?mi)^\s*useAlm4DataverseExtension:\s*(true|false)\s*$')
        foreach ($match in $extensionMatches) {
            $detectedValues += [pscustomobject]@{
                File  = $candidateFile
                Value = ($match.Groups[1].Value -ieq 'true')
            }
        }
    }

    if ($detectedValues.Count -eq 0) {
        return [pscustomobject]@{
            IsConfigured                = $false
            HasConflict                 = $false
            UseAlm4DataverseExtension   = $null
            SourceFiles                 = @()
        }
    }

    $distinctValues = @($detectedValues | Select-Object -ExpandProperty Value -Unique)
    return [pscustomobject]@{
        IsConfigured              = ($distinctValues.Count -eq 1)
        HasConflict               = ($distinctValues.Count -gt 1)
        UseAlm4DataverseExtension = $(if ($distinctValues.Count -eq 1) { [bool]$distinctValues[0] } else { $null })
        SourceFiles               = @($detectedValues | Select-Object -ExpandProperty File -Unique)
    }
}

function Select-AzDoSharedRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter()][string]$PreferredRepositoryName,
        [Parameter()][string]$ExcludeRepositoryName
    )

    Write-Section 'Selecting shared ALM4Dataverse repository'

    $repos = @(Get-VSTeamGitRepository -ProjectName $ProjectName)
    $reposSorted = @($repos | Sort-Object -Property Name)
    $candidateRepos = @($reposSorted | Where-Object {
        [string]::IsNullOrWhiteSpace($ExcludeRepositoryName) -or $_.Name -ne $ExcludeRepositoryName
    })

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryName)) {
        $preferredRepo = $candidateRepos | Where-Object { $_.Name -eq $PreferredRepositoryName } | Select-Object -First 1
        if ($preferredRepo) {
            $menuItems += "Use current shared repository: $($preferredRepo.Name)"
            $menuActions += @{ Type = 'UseExisting'; Repo = $preferredRepo }
            $candidateRepos = @($candidateRepos | Where-Object { $_.Id -ne $preferredRepo.Id })
        }
    }

    foreach ($candidateRepo in $candidateRepos) {
        $menuItems += "Use existing repository: $($candidateRepo.Name)"
        $menuActions += @{ Type = 'UseExisting'; Repo = $candidateRepo }
    }

    $defaultNewName = if ([string]::IsNullOrWhiteSpace($PreferredRepositoryName)) { 'ALM4Dataverse' } else { $PreferredRepositoryName }
    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew'; DefaultName = $defaultNewName }

    $selection = Select-FromMenu -Title 'Select the shared repository that will host the ALM4Dataverse templates' -Items $menuItems
    if ($null -eq $selection) {
        throw 'No shared repository selected.'
    }

    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        Write-Host "Selected shared repository: $($selectedAction.Repo.Name)"
        return $selectedAction.Repo
    }

    while ($true) {
        $newRepoName = Read-Host "Enter the name for the shared repository [$($selectedAction.DefaultName)]"
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            $newRepoName = $selectedAction.DefaultName
        }

        $newRepoName = $newRepoName.Trim()
        if ([string]::IsNullOrWhiteSpace($newRepoName)) {
            Write-Warning 'Repository name cannot be empty.'
            continue
        }

        Write-Host "Creating Git repository '$newRepoName' in project '$ProjectName'..." -ForegroundColor Yellow
        $createdRepo = Add-VSTeamGitRepository -ProjectName $ProjectName -Name $newRepoName
        if (-not $createdRepo -or -not $createdRepo.Id) {
            throw "Failed to create Git repository '$newRepoName'."
        }

        Write-Host "Created shared repository '$newRepoName'."
        return $createdRepo
    }
}

function Sync-CopyToYourRepoIntoGitRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$RepositoryName,
        [Parameter(Mandatory)][string]$SharedRepositoryName,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section "Syncing pipeline files into main repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\', '/'
        $destPath = Join-Path $TargetRoot $relativePath

        if ($normalizedRelativePath -eq 'alm-config.psd1' -and (Test-Path -LiteralPath $destPath)) {
            if (Test-Path -LiteralPath "$destPath.template") {
                Remove-Item -LiteralPath "$destPath.template" -Force
            }

            Write-Host 'Preserving existing alm-config.psd1 so current solution defaults and extended config can be merged later.' -ForegroundColor DarkGray
            continue
        }

        $destDir = Split-Path -Parent $destPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        $sourceFileToUse = $file.FullName
        $isTempFile = $false

        if ($normalizedRelativePath -eq 'pipelines/DEPLOY-main.yml') {
            $destPath = Join-Path $TargetRoot "pipelines/DEPLOY-$Branch.yml"

            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace "source: 'BUILD'", "source: '$RepositoryName\BUILD'"
            $content = $content -replace "- main", "- $Branch"
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"
            if (-not $UseAlm4DataverseExtension) {
                $content = $content -replace '(?m)^(\s*#?\s*useAlm4DataverseExtension:\s*)true\s*$', '${1}false'
            }

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }
        elseif (-not $UseAlm4DataverseExtension -and $normalizedRelativePath -in @('pipelines/EXPORT.yml', 'pipelines/IMPORT.yml')) {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace '(?m)^(\s*useAlm4DataverseExtension:\s*)true\s*$', '${1}false'
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }
        elseif ($normalizedRelativePath -eq 'pipelines/BUILD.yml') {
            $content = Get-Content -LiteralPath $file.FullName -Raw
            $content = $content -replace '(?m)^(\s*name:\s*)ALM4Dataverse\s*$', "`${1}$SharedRepositoryName"

            $tempFile = [System.IO.Path]::GetTempFileName()
            $content | Set-Content -LiteralPath $tempFile -NoNewline
            $sourceFileToUse = $tempFile
            $isTempFile = $true
        }

        try {
            if (Test-Path -LiteralPath $destPath) {
                $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm MD5
                $dstHash = Get-FileHash -LiteralPath $destPath -Algorithm MD5

                if ($srcHash.Hash -ne $dstHash.Hash) {
                    Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
                else {
                    if (Test-Path -LiteralPath "$destPath.template") {
                        Remove-Item -LiteralPath "$destPath.template" -Force
                    }
                }
            }
            else {
                Copy-Item -LiteralPath $sourceFileToUse -Destination $destPath -Force
            }
        }
        finally {
            if ($isTempFile -and (Test-Path -LiteralPath $sourceFileToUse)) {
                Remove-Item -LiteralPath $sourceFileToUse -Force
            }
        }
    }

    Write-Host 'Pipeline files synced into the working tree.' -ForegroundColor Green
}

function New-AzDoRepoWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$TargetRepo,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter()][string]$PreferredBranch = 'main',
        [Parameter()][string]$WorkBranch
    )

    if (-not $TargetRepo.remoteUrl) {
        throw "Could not determine remoteUrl for repository '$($TargetRepo.Name)'."
    }

    $cloneRoot = Join-Path $env:TEMP ("ALM4Dataverse-MainRepo-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $cloneRoot -Force | Out-Null

    Write-Host "Cloning '$($TargetRepo.Name)' to a temp folder..." -ForegroundColor Yellow
    try {
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" clone $TargetRepo.remoteUrl $cloneRoot
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone exited with code $LASTEXITCODE"
        }

        Push-Location $cloneRoot
        try {
            $branch = $PreferredBranch
            if ($TargetRepo.defaultBranch) {
                $branch = ConvertFrom-GitRefToBranchName -Ref $TargetRepo.defaultBranch
            }
            if ([string]::IsNullOrWhiteSpace($branch)) {
                $branch = 'main'
            }

            $hasCommits = $false
            try {
                & git rev-parse HEAD 2>$null | Out-Null
                $hasCommits = ($LASTEXITCODE -eq 0)
            }
            catch {
                $hasCommits = $false
            }

            if ($hasCommits) {
                & git checkout $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    & git checkout -b $branch 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) {
                        throw "Git checkout failed for branch '$branch'."
                    }
                }
            }
            else {
                & git checkout -b $branch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout -b failed with exit code $LASTEXITCODE"
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($WorkBranch) -and $WorkBranch -ne $branch) {
                & git checkout -B $WorkBranch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Git checkout failed for working branch '$WorkBranch'."
                }
            }

            return [pscustomobject]@{
                Path       = $cloneRoot
                BaseBranch = $branch
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        throw
    }
}

function Get-AzDoDefaultAgentQueueId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project
    )

    $queues = @(Get-VSTeamQueue -ProjectName $Project)
    if ($queues.Count -eq 0) {
        throw "No agent queues found in project '$Project'."
    }

    $preferred = $queues | Where-Object { $_.name -eq 'Azure Pipelines' } | Select-Object -First 1
    if (-not $preferred) {
        $preferred = $queues | Where-Object { $_.name -eq 'Default' } | Select-Object -First 1
    }
    if (-not $preferred) {
        $preferred = $queues | Select-Object -First 1
    }

    if (-not $preferred -or -not $preferred.id) {
        throw "Unable to resolve an agent queue id."
    }

    return [int]$preferred.id
}

function Get-AzDoSecurityNamespaceByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Name
    )

    # Use VSTeam command to get security namespace by name
    $allNamespaces = Get-VSTeamSecurityNamespace
    $ns = $allNamespaces | Where-Object { $_.Name -eq $Name -or $_.DisplayName -eq $Name } | Select-Object -First 1
    if (-not $ns -or -not $ns.Id) {
        throw "Unable to resolve security namespace '$Name'."
    }
    return $ns
}

function Get-AzDoSecurityNamespaceActionBit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Namespace,
        [Parameter(Mandatory)][string]$ActionName
    )

    $actions = @()
    if ($Namespace -and $Namespace.actions) {
        $actions = @($Namespace.actions)
    }

    $action = $actions | Where-Object {
        ($_.name -eq $ActionName) -or ($_.displayName -eq $ActionName)
    } | Select-Object -First 1

    if (-not $action -or -not ($action.PSObject.Properties.Name -contains 'bit')) {
        throw "Unable to resolve action '$ActionName' in security namespace '$($Namespace.name)'."
    }

    return [long]$action.bit
}

function Get-AzDoBuildServiceIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter()][string]$ProjectName
    )

    # Use VSTeam command to search for Build Service identity
    $serviceIdentities = @(Get-VSTeamUser -SubjectTypes svc)
    
    $buildServicePattern = "Build:$ProjectId"
    $buildIdentity = $null
    
    foreach ($identity in $serviceIdentities) {
        if ($identity.descriptor -and $identity.descriptor.StartsWith('svc.')) {
            try {
                # Remove "svc." prefix and base64 decode
                $encodedPart = $identity.descriptor.Substring(4)
                
                # Add padding if needed for proper base64 decoding
                $padding = (4 - ($encodedPart.Length % 4)) % 4
                if ($padding -gt 0) {
                    $encodedPart += '=' * $padding
                }
                
                $decodedBytes = [Convert]::FromBase64String($encodedPart)
                $decodedString = [Text.Encoding]::UTF8.GetString($decodedBytes)
                
                # Check if decoded string ends with "Build:$ProjectId"
                if ($decodedString.EndsWith($buildServicePattern)) {
                    $buildIdentity = $identity
                    $correctDescriptor = "Microsoft.TeamFoundation.ServiceIdentity;$decodedString"
                    break
                }
            }
            catch {
                # Skip if base64 decode fails
                continue
            }
        }
    }

    if (-not $buildIdentity) {
        throw "Unable to find Build Service identity with descriptor ending 'Build:$ProjectId' for project '$ProjectName'."
    }

    if (-not $correctDescriptor) {
        throw "Build Service identity found but correct descriptor could not be constructed."
    }

    Write-Host "Found Build Service identity: $($buildIdentity.displayName)"
    return $correctDescriptor
}

function Get-AzDoAccessControlEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Descriptor
    )

    try {
        # Use VSTeam command to get access control list
        $acls = Get-VSTeamAccessControlList -SecurityNamespaceId $NamespaceId -Token $Token -Descriptors $Descriptor
        
        if (-not $acls -or $acls.Count -eq 0) {
            return $null
        }

        $acl = $acls | Select-Object -First 1
        if (-not $acl -or -not $acl.acesDictionary) {
            return $null
        }

        # Extract the ACE for the requested descriptor
        $ace = $null
        try {
            if ($acl.acesDictionary.PSObject.Properties.Name -contains $Descriptor) {
                $ace = $acl.acesDictionary.$Descriptor
            }
            elseif ($acl.acesDictionary.ContainsKey -and $acl.acesDictionary.ContainsKey($Descriptor)) {
                $ace = $acl.acesDictionary[$Descriptor]
            }
        }
        catch {
            $ace = $null
        }

        return $ace
    }
    catch {
        # If VSTeam command fails, return null (ACE doesn't exist)
        return $null
    }
}

function Set-AzDoAccessControlEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$NamespaceId,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Descriptor,
        [Parameter(Mandatory)][long]$Allow,
        [Parameter(Mandatory)][long]$Deny
    )

    # Use VSTeam command to set access control entry
    # Note: Add-VSTeamAccessControlEntry requires a SecurityNamespace object, so we need to get it first
    $ns = Get-VSTeamSecurityNamespace -Id $NamespaceId
    Add-VSTeamAccessControlEntry -SecurityNamespace $ns -Token $Token -Descriptor $Descriptor -AllowMask $Allow -DenyMask $Deny -OverwriteMask
}

function Ensure-AzDoBuildServiceHasContributeOnRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$RepositoryId
    )

    # Find the Build Service identity by searching identities
    $descriptor = Get-AzDoBuildServiceIdentity -Organization $Organization -ProjectId $ProjectId -ProjectName $ProjectName
    $descriptor = $descriptor.Trim()  # Clean any whitespace
    Write-Host "Found Build Service descriptor: $descriptor" -ForegroundColor DarkGray

    $ns = Get-AzDoSecurityNamespaceByName -Organization $Organization -Name 'Git Repositories'
    $contributeBit = Get-AzDoSecurityNamespaceActionBit -Namespace $ns -ActionName 'Contribute'

    # Repo token format for Git Repositories namespace:
    #   repoV2/<projectId>/<repoId>
    $token = "repoV2/$ProjectId/$RepositoryId"

    $existing = Get-AzDoAccessControlEntry -Organization $Organization -NamespaceId $ns.Id -Token $token -Descriptor $descriptor
    $existingAllow = 0L
    $existingDeny = 0L

    if ($existing) {
        if ($existing.PSObject.Properties.Name -contains 'allow') { $existingAllow = [long]$existing.allow }
        if ($existing.PSObject.Properties.Name -contains 'deny') { $existingDeny = [long]$existing.deny }
    }

    $alreadyAllowed = (($existingAllow -band $contributeBit) -ne 0)
    $isDenied = (($existingDeny -band $contributeBit) -ne 0)

    if ($alreadyAllowed -and -not $isDenied) {
        Write-Host "Build Service already has 'Contribute' on repo."
        return
    }

    $desiredAllow = ($existingAllow -bor $contributeBit)
    $desiredDeny = ($existingDeny -band (-bnot $contributeBit))

    Write-Host "Granting Build Service 'Contribute' on repo..." -ForegroundColor Yellow
    Set-AzDoAccessControlEntry -Organization $Organization -NamespaceId $ns.Id -Token $token -Descriptor $descriptor -Allow $desiredAllow -Deny $desiredDeny | out-null
    Write-Host "Granted 'Contribute' to Build Service on repository."
}

function Ensure-AzDoYamlPipelineDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string]$DefinitionName,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][int]$QueueId,
        [Parameter()][string]$FolderPath = '\'
    )

    $YamlPath = $YamlPath.TrimStart('/')

    $existing = @(Get-VSTeamBuildDefinition -ProjectName $Project) | Where-Object { $_.name -eq $DefinitionName -and $_.path -eq $FolderPath }
    $def = $existing | Select-Object -First 1

    if (-not $def) {
        Write-Host "Creating pipeline '$DefinitionName' (YAML: $YamlPath)..." -ForegroundColor Yellow

        $repoBranch = 'refs/heads/main'
        if ($Repository.defaultBranch) {
            $repoBranch = $Repository.defaultBranch
        }

        # Use Invoke-VSTeamRequest since VSTeam build definition commands require JSON files
        $body = @{
            name        = $DefinitionName
            path        = $FolderPath
            type        = 'build'
            queueStatus = 'enabled'
            queue       = @{ id = $QueueId }
            repository  = @{
                id            = $Repository.Id
                name          = $Repository.Name
                type          = 'TfsGit'
                defaultBranch = $repoBranch
            }
            process     = @{
                type         = 2
                yamlFilename = $YamlPath
            }
            triggers    = @(
                @{
                    settingsSourceType = 2
                    triggerType        = 'continuousIntegration'
                }
            )
        }

        $resource = "build/definitions"
        [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1')
        Write-Host "Created pipeline '$DefinitionName'."
        return
    }

    # Ensure existing points at expected YAML + repo
    $full = Get-VSTeamBuildDefinition -ProjectName $Project -Id $def.id

    $needsUpdate = $false
    if (-not $full.process -or -not $full.process.type -or [int]$full.process.type -ne 2) {
        $needsUpdate = $true
    }
    elseif ($full.process.PSObject.Properties.Name -contains 'yamlFilename') {
        if ($full.process.yamlFilename -ne $YamlPath) { $needsUpdate = $true }
    }
    else {
        # If yamlFilename isn't present, treat as needs update.
        $needsUpdate = $true
    }

    if ($full.repository -and $full.repository.id -and ($full.repository.id -ne $Repository.Id)) {
        $needsUpdate = $true
    }

    if (-not $needsUpdate) {
        Write-Host "Pipeline '$DefinitionName' already exists and points at '$YamlPath'."
        return
    }

    Write-Host "Updating pipeline '$DefinitionName' to point at '$YamlPath'..." -ForegroundColor Yellow

    $def.repository.name = $Repository.Name
    $def.repository.id = $Repository.Id
    if ($Repository.defaultBranch) {
        $def.repository.defaultBranch = $Repository.defaultBranch
    }
    $def.process.yamlFilename = $YamlPath

    # Use Invoke-VSTeamRequest since VSTeam update commands require JSON files
    $resource = "build/definitions/$($def.id)"
    [void](Invoke-VSTeamRequest -Method PUT -Resource $resource -Body ($def | ConvertTo-Json -Depth 50) -ContentType 'application/json' -Version '7.1')
    Write-Host "Updated pipeline '$DefinitionName'."
}

function Ensure-AzDoPipelinesForMainRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Repository,
        [Parameter(Mandatory)][string[]]$YamlFiles,
        [Parameter()][string]$FolderPath = '\\'
    )

    Write-Section "Ensuring Azure DevOps pipeline definitions exist"

    $queueId = Get-AzDoDefaultAgentQueueId -Organization $Organization -Project $Project
    Write-Host "Using agent queue id: $queueId" -ForegroundColor DarkGray

    foreach ($yaml in $YamlFiles) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($yaml)
        Ensure-AzDoYamlPipelineDefinition -Organization $Organization -Project $Project -Repository $Repository -DefinitionName $name -YamlPath $yaml -QueueId $queueId -FolderPath $FolderPath
    }
}

function Ensure-AzDoDeploymentApproversTeam {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $teamName = "$EnvironmentName deployment approvers"
    Write-Host "Ensuring team '$teamName' exists..." -ForegroundColor DarkGray

    $team = Get-VSTeam -ProjectName $ProjectName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $teamName } | Select-Object -First 1
    
    if (-not $team) {
        Write-Host "Creating team '$teamName'..." -ForegroundColor Yellow
        Add-VSTeam -ProjectName $ProjectName -Name $teamName -Description "Approvers for $EnvironmentName deployment" | Out-Null
        $team = Get-VSTeam -ProjectName $ProjectName | Where-Object { $_.Name -eq $teamName } | Select-Object -First 1
    }
       
    # Add current user to the team
    
    $me = Invoke-VSTeamRequest -NoProject -Method GET -Url "https://app.vssps.visualstudio.com/_apis/profile/profiles/me" -Version "7.1"
    Write-Host "Adding current user ($($me.emailAddress)) to team '$teamName'..." -ForegroundColor Yellow
    
    $user = Get-VSTeamUser | Where-Object { $_.UniqueName -eq $me.emailAddress } | Select-Object -First 1
    $group = Get-VSTeamGroup -ProjectName $ProjectName | Where-Object { $_.DisplayName -eq $teamName } | Select-Object -First 1

    if ($user -and $group) {
        Add-VSTeamMembership -MemberDescriptor $user.Descriptor -ContainerDescriptor $group.Descriptor | Out-Null
    }
    else {
        throw "Could not resolve user or group to add membership."
    }

    
    return $team
}

function Ensure-AzDoVariableGroupApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$VariableGroupId,
        [Parameter(Mandatory)][string]$VariableGroupName,
        [Parameter(Mandatory)][object]$ApproverTeam
    )

    Write-Host "Ensuring Approval check on variable group '$VariableGroupName'..." -ForegroundColor DarkGray

    # Check for existing checks
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/checks/configurations?resourceType=variablegroup&resourceId=$VariableGroupId&api-version=7.1-preview.1"
    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    $existingChecks = $null

    $existingChecks = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    
    $hasApproval = $false
    if ($existingChecks -and $existingChecks.count -gt 0) {
        foreach ($check in $existingChecks.value) {
            if ($check.resource.type -eq 'variablegroup' -and [string]$check.resource.id -eq [string]$VariableGroupId -and $check.type -and $check.type.name -eq 'Approval') {
                $hasApproval = $true
                break
            }
        }
    }

    if ($hasApproval) {
        Write-Host "Approval check already exists on variable group '$VariableGroupName'."
        return
    }

    Write-Host "Adding Approval check to variable group '$VariableGroupName'..." -ForegroundColor Yellow

    # We need the descriptor for the team. Get-VSTeamTeam doesn't return it directly.
    # We can find the group identity using Get-VSTeamGroup.
    $teamIdentity = Get-VSTeamGroup -ProjectName $Project | Where-Object { $_.principalName -eq $ApproverTeam.name -or $_.displayName -eq $ApproverTeam.name } | Select-Object -First 1
    
    if (-not $teamIdentity) {
        throw "Could not resolve identity for team '$($ApproverTeam.name)' for approval check creation."
    }

    $body = @{
        type = @{
            id = "8C6F20A7-A545-4486-9777-F762FAFE0D4D"
            name = "Approval"
        }
        settings = @{
            approvers = @(
                @{
                    id = $teamIdentity.originId
                    descriptor = $teamIdentity.descriptor
                    displayName = $teamIdentity.displayName
                }
            )
            executionOrder = 1
            minRequiredApprovers = 0
            requesterCannotBeApprover = $false
        }
        resource = @{
            type = "variablegroup"
            id = [string]$VariableGroupId
            name = $VariableGroupName
        }
        timeout = 43200
    }

    $resource = "pipelines/checks/configurations"
    [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1')
    Write-Host "Approval check added."
}

function Ensure-AzDoVariableGroupExclusiveLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$VariableGroupId,
        [Parameter(Mandatory)][string]$VariableGroupName
    )

    Write-Host "Ensuring ExclusiveLock check on variable group '$VariableGroupName'..." -ForegroundColor DarkGray

    # Check for existing checks
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/checks/configurations?resourceType=variablegroup&resourceId=$VariableGroupId&api-version=7.1-preview.1"
    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    $existingChecks = $null
    $existingChecks = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers

    $hasExclusiveLock = $false
    if ($existingChecks -and $existingChecks.count -gt 0) {
        foreach ($check in $existingChecks.value) {
            if ($check.resource.type -eq 'variablegroup' -and [string]$check.resource.id -eq [string]$VariableGroupId -and $check.type -and $check.type.name -eq 'ExclusiveLock') {
                $hasExclusiveLock = $true
                break
            }
        }
    }

    if ($hasExclusiveLock) {
        Write-Host "ExclusiveLock check already exists on variable group '$VariableGroupName'."
        return
    }

    Write-Host "Adding ExclusiveLock check to variable group '$VariableGroupName'..." -ForegroundColor Yellow

    $body = @{
        type = @{
            id = "2EF31AD6-BAA0-403A-8B45-2CBC9B4E5563"
            name = "ExclusiveLock"
        }
        settings = @{}
        resource = @{
            type = "variablegroup"
            id = [string]$VariableGroupId
            name = $VariableGroupName
        }
        timeout = 43200
    }

    $resource = "pipelines/checks/configurations"
    [void](Invoke-VSTeamRequest -Method POST -Resource $resource -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1-preview.1')
    Write-Host "ExclusiveLock check added."
}

function Ensure-AzDoEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$Description
    )

    Write-Host "Ensuring Environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    # List environments to check if it exists
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/environments?name=$EnvironmentName&api-version=7.2-preview.1"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        $env = $response.value | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        
        if ($env) {
            Write-Host "Environment '$EnvironmentName' already exists (id: $($env.id))."
            return $env
        }

        Write-Host "Creating Environment '$EnvironmentName'..." -ForegroundColor Yellow
        
        $body = @{
            name = $EnvironmentName
            description = $Description
        }

        $createUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/environments?api-version=7.2-preview.1"
        $created = Invoke-RestMethod -Uri $createUri -Method Post -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json"
        
        Write-Host "Created Environment '$EnvironmentName' (id: $($created.id))."
        return $created
    }
    catch {
        Write-Host "Failed to ensure environment: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Ensure-AzDoPipelinePermission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ResourceType, # 'endpoint' or 'variablegroup'
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][int]$PipelineId
    )

    Write-Host "Ensuring pipeline $PipelineId has permission on $ResourceType $ResourceId..." -ForegroundColor DarkGray

    $headers = @{ Authorization = "Bearer $($adoAccessToken.Token)" }
    
    # Check existing permissions
    $uri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinePermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        
        $isAuthorized = $false
        if ($response.pipelines) {
            foreach ($p in $response.pipelines) {
                if ($p.id -eq $PipelineId -and $p.authorized -eq $true) {
                    $isAuthorized = $true
                    break
                }
            }
        }

        if ($isAuthorized) {
            Write-Host "Pipeline $PipelineId is already authorized."
            return
        }

        Write-Host "Authorizing pipeline $PipelineId..." -ForegroundColor Yellow
        
        $body = @{
            pipelines = @(
                @{
                    id = $PipelineId
                    authorized = $true
                }
            )
        }

        $patchUri = "https://dev.azure.com/$Organization/$Project/_apis/pipelines/pipelinePermissions/$ResourceType/$ResourceId`?api-version=7.1-preview.1"
        [void](Invoke-RestMethod -Uri $patchUri -Method Patch -Headers $headers -Body ($body | ConvertTo-Json) -ContentType "application/json")
        
        Write-Host "Pipeline authorized successfully."
    }
    catch {
        Write-Host "Failed to authorize pipeline: $($_.Exception.Message)" -ForegroundColor Red
        Write-Warning "Could not authorize pipeline. You may need to authorize it manually when running the pipeline."
    }
}

function Ensure-AzDoServiceEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ServiceEndpointName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter()][string]$ClientSecret,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'Secret'
    )

    Write-Host "Ensuring Service Endpoint '$ServiceEndpointName'..." -ForegroundColor DarkGray

    # Get-VSTeamServiceEndpoint does not support -Name, so we filter client-side
    $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
    $existing = $endpoints | Where-Object { $_.name -eq $ServiceEndpointName } | Select-Object -First 1
    
    if ($existing) {
        $existingAuthParameters = $existing.authorization.parameters
        $existingApplicationId = $null
        if ($existingAuthParameters) {
            if ($existingAuthParameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingApplicationId = $existingAuthParameters.applicationId
            }
            elseif ($existingAuthParameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingApplicationId = $existingAuthParameters.serviceprincipalid
            }
        }

        $existingAuthType = 'Secret'
        if ($existing.authorization -and $existing.authorization.scheme -eq 'WorkloadIdentityFederation') {
            $existingAuthType = 'WIF'
        }

        $normalizedExistingUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existing.url
        $normalizedTargetUrl = ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl
        $requiresUpdate = ($normalizedExistingUrl -ne $normalizedTargetUrl) -or ($existingApplicationId -ne $ApplicationId) -or ($existingAuthType -ne $AuthType)

        if ($AuthType -eq 'Secret' -and -not [string]::IsNullOrWhiteSpace($ClientSecret)) {
            $requiresUpdate = $true
        }

        if (-not $requiresUpdate) {
            Write-Host "Service Endpoint '$ServiceEndpointName' already exists."
            return $existing
        }

        Write-Host "Service Endpoint '$ServiceEndpointName' already exists but needs to be refreshed. Recreating it..." -ForegroundColor Yellow
        Remove-VSTeamServiceEndpoint -ProjectName $ProjectName -Id $existing.id -Force | Out-Null
    }

    Write-Host "Creating Service Endpoint '$ServiceEndpointName'..." -ForegroundColor Yellow

    try {
        $payload = @{
            url = $EnvironmentUrl
            data = @{}
        }

        if ($AuthType -eq 'WIF') {
            # Workload Identity Federation
            $payload.authorization = @{
                parameters = @{
                    "serviceprincipalid" = $ApplicationId
                    "tenantid" = $TenantId
                }
                scheme = "WorkloadIdentityFederation"
            }
        }
        else {
            # Traditional Service Principal with Secret
            if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
                throw "ClientSecret is required when AuthType is 'Secret'."
            }
            
            $payload.authorization = @{
                parameters = @{
                    "tenantId" = $TenantId
                    "applicationId" = $ApplicationId
                    "clientSecret" = $ClientSecret
                }
                scheme = "None"
            }
        }

        $response = Add-VSTeamServiceEndpoint -ProjectName $ProjectName `
            -EndpointName $ServiceEndpointName `
            -EndpointType "powerplatform-spn" `
            -Object $payload

        Write-Host "Service Endpoint '$ServiceEndpointName' created successfully."
        Start-Sleep -Seconds 5 # Wait a bit for SE to be fully available
        # Re-fetch to ensure we have all properties including WIF issuer/subject assigned by Azure DevOps
        $fetched = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue) | Where-Object { $_.name -eq $ServiceEndpointName } | Select-Object -First 1
        if ($fetched) { return $fetched }
        return $response
    }
    catch {
        Write-Host "Failed to create Service Endpoint '$ServiceEndpointName': $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Ensure-EntraIdServicePrincipal {
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if SP exists
    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    try {
        $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        if ($existing.value.Count -gt 0) {
            Write-Host "Service Principal for App '$ApplicationId' already exists."
            return $existing.value[0]
        }
    }
    catch {
        Write-Warning "Failed to check for existing Service Principal: $($_.Exception.Message)"
    }

    # Create SP
    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{
        appId = $ApplicationId
    }
    
    try {
        $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created Service Principal ($($sp.id))."
        start-sleep -Seconds 10 # Wait a bit for SP to be fully available
        return $sp
    }
    catch {
        Write-Error "Failed to create Service Principal: $($_.Exception.Message)"
        throw
    }
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.
    
    .DESCRIPTION
        Creates a federated identity credential that allows Azure DevOps to authenticate to Azure
        using Workload Identity Federation (WIF) without requiring client secrets.
    #>
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Issuer,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $issuer = $Issuer
    $subject = $Subject
    $credentialName = $CredentialName

    Write-Host "Adding federated identity credential '$credentialName'..." -ForegroundColor Yellow

    # Check if credential already exists
    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
        $existingCred = $existing.value | Where-Object { 
            $_.issuer -eq $issuer -and $_.subject -eq $subject 
        } | Select-Object -First 1
        
        if ($existingCred) {
            Write-Host "Federated identity credential already exists for this issuer and subject."
            return $existingCred
        }
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    # Create the federated credential
    $body = @{
        name = $credentialName
        issuer = $issuer
        subject = $subject
        audiences = @("api://AzureADTokenExchange")
        description = "Workload Identity Federation for Azure DevOps service connection"
    }

    try {
        $credential = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $credential
    }
    catch {
        Write-Error "Failed to create federated identity credential: $($_.Exception.Message)"
        throw
    }
}

function New-EntraIdApplication {
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter()][string]$AuthType = 'Secret'
    )
    
    # Get token for Graph
    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    # Check if app exists
    $filter = "displayName eq '$DisplayName'"
    $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter"
    
    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    
    $app = $null
    if ($existing.value.Count -gt 0) {
        $app = $existing.value[0]
        Write-Host "Found existing App Registration '$DisplayName' ($($app.appId))."
    }
    else {
        Write-Host "Creating App Registration '$DisplayName'..." -ForegroundColor Yellow
        $body = @{
            displayName = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Ensure-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name = $DisplayName
        ApplicationId = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret = $null
        TenantId = $TenantId
        AuthType = $AuthType
        IsExistingServiceConnection = $false
    }

    if ($AuthType -ne 'WIF') {
        # Create secret for traditional authentication
        Write-Host "Creating client secret..." -ForegroundColor Yellow
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
    }

    return $result
}

function Get-PowerPlatformSCCredentials {
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$OrganizationId,
        [Parameter()][string]$OrganizationName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential
    )

    # 1. Try to find existing Service Connection to see if we can reuse its App ID
    $existingEndpoint = $null
    $existingScAppId = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $existingEndpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        if ($existingEndpoint -and $existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $existingScAppId = $existingEndpoint.authorization.parameters.applicationId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $existingScAppId = $existingEndpoint.authorization.parameters.serviceprincipalid
            }
        }
    }
    catch {
        # Ignore errors checking for existing SC
    }

    if (-not $ExistingCredential -and $existingEndpoint -and -not [string]::IsNullOrWhiteSpace($existingScAppId)) {
        $existingAuthType = if ($existingEndpoint.authorization -and $existingEndpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }
        $existingTenantId = $TenantId
        if ($existingEndpoint.authorization -and $existingEndpoint.authorization.parameters) {
            if ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantId)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantId
            }
            elseif ($existingEndpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($existingEndpoint.authorization.parameters.tenantid)) {
                $existingTenantId = $existingEndpoint.authorization.parameters.tenantid
            }
        }

        $existingApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $existingScAppId -TenantId $existingTenantId
        $ExistingCredential = [pscustomobject]@{
            Name                        = $(if ($existingApplication -and -not [string]::IsNullOrWhiteSpace($existingApplication.displayName)) { $existingApplication.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId               = $existingScAppId
            ApplicationObjectId         = $(if ($existingApplication) { $existingApplication.id } else { $null })
            ClientSecret                = $null
            TenantId                    = $existingTenantId
            AuthType                    = $existingAuthType
            IsExistingServiceConnection = $true
            HasExistingSecret           = ($existingAuthType -eq 'Secret')
        }
    }

    # 2. Search Entra ID for relevant applications
    $foundApps = @()
    try {
        $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
        $headers = @{ Authorization = "Bearer $($graphToken.AccessToken)" }

        # If we have an existing SC App ID, ensure it's in the list
        if ($existingScAppId) {
            $alreadyFound = $foundApps | Where-Object { $_.appId -eq $existingScAppId }
            if (-not $alreadyFound) {
                $filter = "appId eq '$existingScAppId'"
                $uri = "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=appId,displayName,id"
                $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                if ($response.value) {
                    $foundApps += $response.value
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to list applications from Entra ID: $($_.Exception.Message)"
    }

    # 3. Build Menu
    $menuItems = @()
    $menuActions = @() # To track what each item does

    if ($ExistingCredential -and -not [string]::IsNullOrWhiteSpace($ExistingCredential.ApplicationId)) {
        $existingLabel = "Use existing: $($ExistingCredential.Name) ($($ExistingCredential.ApplicationId))"
        if ($ExistingCredential.AuthType -eq 'Secret' -and $ExistingCredential.HasExistingSecret) {
            $existingLabel += ' [secret already configured]'
        }
        elseif ($ExistingCredential.AuthType -eq 'WIF') {
            $existingLabel += ' [workload identity federation]'
        }

        $menuItems += $existingLabel
        $menuActions += @{ Type = 'Existing'; Creds = $ExistingCredential }
    }

    # Priority 1: Recommended App (Existing SC or Exact Name Match)
    $recommendedApp = $null
    
    if ($existingScAppId) {
        $recommendedApp = $foundApps | Where-Object { $_.appId -eq $existingScAppId } | Select-Object -First 1
    }
   
    if ($UseAlm4DataverseExtension -and $recommendedApp) {
        $menuItems += "Use existing: $($recommendedApp.displayName) ($($recommendedApp.appId))"
        $menuActions += @{ Type = 'ExistingSCApp'; App = $recommendedApp }
        
        # Remove from foundApps to avoid duplicate listing
        $foundApps = $foundApps | Where-Object { $_.appId -ne $recommendedApp.appId }
    }

    # Standard Options
    $menuItems += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems += "Enter existing Service Principal details"
    $menuActions += @{ Type = 'Manual' }

    # Cached Credentials
    foreach ($c in $ExistingCredentials) {
        $menuItems += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }
 

    # 4. Show Menu
    Write-Host ""
    Write-SetupGuidance -Lines @(
        "Service Principal credentials are used to authenticate the pipeline to Dataverse.",
        "Best practice: use a separate App Registration per environment and prefer Workload Identity Federation when ALM4Dataverse extension mode stays enabled."
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef
    
    $selection = Select-FromMenu -Title "Select Service Principal credentials for '$EnvironmentName'" -Items $menuItems
    if ($null -eq $selection) { throw "No credential selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Existing') {
        $selectedCredential = $action.Creds.PSObject.Copy()

        if ($selectedCredential.AuthType -eq 'Secret' -and $selectedCredential.HasExistingSecret) {
            $secretHandlingItems = @(
                'Keep the existing client secret',
                'Generate a new client secret now'
            )

            $secretHandlingSelection = Select-FromMenu -Title "How should setup handle the existing client secret for '$EnvironmentName'?" -Items $secretHandlingItems
            if ($null -eq $secretHandlingSelection) {
                throw 'No client secret handling option selected.'
            }

            if ($secretHandlingSelection -eq 1) {
                if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                    $resolvedApplication = Resolve-EntraIdApplicationByAppId -ApplicationId $selectedCredential.ApplicationId -TenantId $selectedCredential.TenantId
                    if ($resolvedApplication) {
                        $selectedCredential.ApplicationObjectId = $resolvedApplication.id
                        if ([string]::IsNullOrWhiteSpace($selectedCredential.Name) -and -not [string]::IsNullOrWhiteSpace($resolvedApplication.displayName)) {
                            $selectedCredential.Name = $resolvedApplication.displayName
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($selectedCredential.ApplicationObjectId)) {
                    throw "Cannot generate a new client secret for '$($selectedCredential.ApplicationId)' because the App Registration object id could not be resolved."
                }

                Write-Host 'Generating a new client secret...' -ForegroundColor Yellow
                $selectedCredential.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $selectedCredential.ApplicationObjectId -TenantId $selectedCredential.TenantId
                $selectedCredential.IsExistingServiceConnection = $false
            }

            return $selectedCredential
        }

        return $selectedCredential
    }
    elseif ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Workload Identity Federation (recommended, no secrets)",
                "Service Principal with Secret (traditional)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new service connection" -Items $authTypeItems
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
            
            $authType = if ($authTypeSelection -eq 1) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }
        
        $appName = "$ProjectName - $EnvironmentName - deployment"
        
        if ($authType -eq 'WIF') {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'WIF'
        }
        else {
            return New-EntraIdApplication `
                -DisplayName $appName `
                -TenantId $TenantId `
                -AuthType 'Secret'
        }
    }
    elseif ($action.Type -eq 'ExistingSCApp') {
        if (-not $UseAlm4DataverseExtension) {
            throw "Reusing existing service connection credentials requires ALM4Dataverse extension mode. Enable extension mode or enter Service Principal details manually."
        }
        $app = $action.App
        Write-Host "Using existing service connection with App: $($app.displayName) ($($app.appId))" -ForegroundColor Cyan
     
        # Since the service connection already exists, we just return a marker object
        # The credentials are already configured in the existing service connection
        return [pscustomobject]@{
            Name = $app.displayName
            ApplicationId = $app.appId
            ApplicationObjectId = $app.id
            ClientSecret = $null
            TenantId = $TenantId
            AuthType = 'Unknown' # Existing SC, auth type already configured
            IsExistingServiceConnection = $true
        }
    }
    else { # Manual
        Write-Host "Enter Service Principal details:" -ForegroundColor Cyan
        $name = Read-Host "Credential Name (for reuse reference)"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Credential-" + (Get-Date -Format "HHmm") }
        
        while ($true) {
            $appId = Read-Host "Application ID (Client ID)"
            if ($appId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application ID must be a valid GUID. Please try again."
            }
        }

        $authType = 'Secret'
        if ($UseAlm4DataverseExtension) {
            # Prompt for authentication type
            Write-Host ""
            $authTypeItems = @(
                "Service Principal with Secret (traditional)",
                "Workload Identity Federation (recommended, no secrets)"
            )
            $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems
            if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
            
            $authType = if ($authTypeSelection -eq 0) { 'Secret' } else { 'WIF' }
        }
        else {
            Write-Host "Using Service Principal with Secret authentication because ALM4Dataverse extension mode is disabled." -ForegroundColor Yellow
        }
        
        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secretSecure = Read-Host "Client Secret" -AsSecureString
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure)
                $secret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                
                if ($secret -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                    Write-Warning "The Client Secret looks like a GUID. You should enter the Secret VALUE, not the Secret ID."
                    if (Read-YesNo -Prompt "Are you sure this is the Secret Value?" -DefaultNo) {
                        break
                    }
                } else {
                    break
                }
            }
        }

        [void](Ensure-EntraIdServicePrincipal -ApplicationId $appId -TenantId $TenantId)

        return [pscustomobject]@{
            Name = $name
            ApplicationId = $appId
            ApplicationObjectId = $null
            ClientSecret = $secret
            TenantId = $TenantId
            AuthType = $authType
            IsExistingServiceConnection = $false
        }
    }
}

function Get-DataverseServiceAccountUPN {
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    # Build Menu
    $menuItems = @()
    $menuActions = @() # To track what each item does

    # Priority 1: Existing value from variable group (if provided)
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    # Standard Options
    $menuItems += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    # Cached Service Accounts (exclude the existing value to avoid duplication)
    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    # Show Menu
    Write-Host ""
    Write-SetupGuidance -Lines @(
        "Service Account credentials are used for ownership and licensing of Cloud Flows.",
        "Use a licensed user account with System Administrator role.",
        "Best practice: keep this separate from your personal admin account so automation ownership stays stable."
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef
    
    $selection = Select-FromMenu -Title "Select Dataverse Service Account for '$EnvironmentName'" -Items $menuItems
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -eq 'Cached' -or $action.Type -eq 'Existing') {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licenced with an appropriate D365/PowerApps/etc licence for your use-case." -ForegroundColor Yellow
        Write-Host ""
        
        while ($true) {
            $upn = Read-Host "Service Account UPN (e.g., serviceaccount@contoso.com)"
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty. Please try again."
                continue
            }
            # Basic UPN format validation
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid UPN format. Please try again."
            }
        }
    }
}

function Ensure-AzDoVariableGroupExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Organization,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    $group = $null

    # Use VSTeam command to check for existing variable groups
    try {
        $existing = Get-VSTeamVariableGroup -ProjectName $Project -Name $GroupName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Host "Variable group '$GroupName' already exists (id: $($existing.id))."
            $group = $existing
        }
    }
    catch {
        # Group doesn't exist, continue with creation
    }

    if (-not $group) {
        Write-Host "Creating variable group '$GroupName'..." -ForegroundColor Yellow

        # Build variables payload in the format expected by Add-VSTeamVariableGroup
        $variablesPayload = @{}
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        # Use VSTeam command to create variable group
        $created = Add-VSTeamVariableGroup -ProjectName $Project -Name $GroupName -Type 'Vsts' -Variables $variablesPayload -Description 'ALM4Dataverse environment variable group (created by setup-azdo.ps1)'

        if ($created -and $created.id) {
            Write-Host "Created variable group '$GroupName' (id: $($created.id))."
            $group = $created
        }
        else {
            Write-Host "Created variable group '$GroupName'."
            $group = $created
        }
    }

    if ($group -and $group.id) {
        Ensure-AzDoVariableGroupExclusiveLock -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName

        if ($GroupName -notmatch 'Dev') {
            $envName = $GroupName -replace '^Environment-', ''
            $team = Ensure-AzDoDeploymentApproversTeam -ProjectName $Project -EnvironmentName $envName
            Ensure-AzDoVariableGroupApproval -Organization $Organization -Project $Project -VariableGroupId $group.id -VariableGroupName $GroupName -ApproverTeam $team
            
        }
    }

    return $group
}

function Update-AzDoVariableGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][hashtable]$Variables
    )

    try {
        $group = Get-VSTeamVariableGroup -ProjectName $ProjectName -Name $GroupName -ErrorAction SilentlyContinue
        if (-not $group) {
            Write-Warning "Variable group '$GroupName' not found. Cannot update."
            return $null
        }

        Write-Host "Updating variable group '$GroupName'..." -ForegroundColor DarkGray

        # Build variables payload in the format expected by Update-VSTeamVariableGroup
        $variablesPayload = @{}
        
        # First, copy existing variables if the group has any
        if ($group.variables) {
            foreach ($key in $group.variables.PSObject.Properties.Name) {
                $variablesPayload[$key] = @{ value = $group.variables.$key.value }
            }
        }

        # Then add/update with new variables
        foreach ($k in $Variables.Keys) {
            $variablesPayload[$k] = @{ value = [string]$Variables[$k] }
        }

        # Use VSTeam command to update variable group
        Update-VSTeamVariableGroup -ProjectName $ProjectName -Id $group.id -Name $GroupName -Type 'Vsts' -Variables $variablesPayload -Description $group.description | Out-Null

        Write-Host "Variable group '$GroupName' updated successfully."
        return $group
    }
    catch {
        Write-Warning "Failed to update variable group '$GroupName': $($_.Exception.Message)"
        return $null
    }
}

$initialization = Initialize-AzDoProjectAndRepositories
if (-not $initialization) {
    return
}

$selectedProject = $initialization.SelectedProject
$mainRepo = $initialization.MainRepo
$mainRepoWorkingTree = $initialization.MainRepoWorkingTree
$mainRepoWorkingRoot = $initialization.MainRepoWorkingRoot
$repo = $initialization.SharedRepo
$sharedRepoName = $initialization.SharedRepoName

Write-Section "Ensuring main repository contains pipeline YAMLs"

$credentialsCache = @()
$serviceAccountsCache = @()
$repoPublishResult = $null
$script:yamlFiles = @(
    'pipelines/BUILD.yml',
    "pipelines/DEPLOY-$script:mainRepoBranch.yml",
    'pipelines/EXPORT.yml',
    'pipelines/IMPORT.yml'
)

$repoPublishPlan = Get-RepoChangePublishPlan `
    -ProviderName 'Azure DevOps' `
    -RepositoryName $mainRepo.Name `
    -BaseBranch $script:mainRepoBranch `
    -DefaultCommitMessage 'Add ALM4Dataverse Azure DevOps pipelines' `
    -DefaultPullRequestTitle 'Add ALM4Dataverse Azure DevOps pipelines' `
    -DefaultPullRequestDescription 'This pull request adds or updates the ALM4Dataverse Azure DevOps pipeline YAML and repository configuration generated by setup-azdo.ps1.' `
    -GuidanceLines @(
        'If the repository uses branch protection or a review policy, choose the pull-request path so the generated YAML and config changes can be reviewed before they land on the main automation branch.',
        'If you commit directly, the target branch is updated immediately and the Azure DevOps pipeline definitions can start using the new YAML as soon as the push completes.'
    ) `
    -DocRelativePath 'docs/setup/azdo-automated-setup.md' `
    -Ref $ALM4DataverseRef
        Push-Location $mainRepoWorkingRoot
        try {
            & git checkout $script:mainRepoBranch 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) {
                & git checkout -b $script:mainRepoBranch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to check out branch '$script:mainRepoBranch' in the working tree."
                }
            }

            if ($repoPublishPlan.BranchName -ne $script:mainRepoBranch) {
                & git checkout -B $repoPublishPlan.BranchName 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create or switch to working branch '$($repoPublishPlan.BranchName)'."
                }
            }
        }
        finally {
            Pop-Location
        }


Invoke-WithErrorHandling -OperationName "Preparing main repository working tree" -ScriptBlock {
    $copyRoot = $null
    if ($PSScriptRoot) {
        $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    }
    else {
        $sharedRepoClone = Join-Path $env:TEMP ("ALM4Dataverse-SharedRepo-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $sharedRepoClone -Force | Out-Null

        try {
            Write-Host 'Cloning shared repository to get template files...' -ForegroundColor Yellow
            & git -c "http.extraheader=AUTHORIZATION: bearer $azDevOpsAccessToken" clone $repo.remoteUrl $sharedRepoClone
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone of shared repository failed with exit code $LASTEXITCODE"
            }

            $copyRoot = Join-Path $sharedRepoClone 'copy-to-your-repo'
            Sync-CopyToYourRepoIntoGitRepo -SourceRoot $copyRoot -TargetRoot $mainRepoWorkingRoot -RepositoryName $mainRepo.Name -SharedRepositoryName $sharedRepoName -Branch $script:mainRepoBranch -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
        }
        finally {
            if (Test-Path $sharedRepoClone) {
                Remove-Item -LiteralPath $sharedRepoClone -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        return
    }

    Sync-CopyToYourRepoIntoGitRepo -SourceRoot $copyRoot -TargetRoot $mainRepoWorkingRoot -RepositoryName $mainRepo.Name -SharedRepositoryName $sharedRepoName -Branch $script:mainRepoBranch -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
} | Out-Null

#endregion

#region Dev Environment and Solutions Selection

function Get-DataverseSolutionsSelection {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl
    )
    
    try {
        Write-Host ""
        Write-Host "When prompted, select your dataverse DEV environment containing the solution(s) you want to manage" -ForegroundColor Green
        Write-Host ""

        # Select environment using the helper function
        $selectedEnv = Select-DataverseEnvironment -Prompt "Select your DEV environment" -PreferredUrl $ExistingEnvironmentUrl
        if (-not $selectedEnv) {
            throw "No environment selected."
        }

        $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
        Write-Host "Selected environment: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

        # Connect to the selected environment
        $connection = Get-DataverseConnection -Url $devEnvUrl -AccessToken { 
            param($resource)
            if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
            try {
                $uri = [System.Uri]$resource
                $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
            } catch {}
            $auth = Get-AuthToken -ResourceUrl $resource
            return $auth.AccessToken
        }
        
        if (-not $connection) {
            throw "Failed to connect to Dataverse environment."
        }
        
        Write-Host "Connected to environment: $($connection.ConnectedOrgFriendlyName)"
        Write-Host "Retrieving solutions..." -ForegroundColor Yellow
        
        # Get all solutions (excluding system solutions)
        $allSolutions = Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid', 'uniquename', 'friendlyname', 'version', 'ismanaged', 'description') -FilterValues @{
            'isvisible' = $true
            'ismanaged' = $false
        }
        
        if (-not $allSolutions -or $allSolutions.Count -eq 0) {
            Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }
        
        # Filter out system solutions and prepare for selection
        $userSolutions = $allSolutions | Where-Object { 
            $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and 
            $_.uniquename -ne 'System' 
        } | Sort-Object friendlyname
        
        if (-not $userSolutions -or $userSolutions.Count -eq 0) {
            Write-Host "No user-created solutions found in the environment." -ForegroundColor Yellow
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl }
        }

        $selectedSolutions = @()

        if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
            try {
                $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
                foreach ($existing in @($existingConfig.solutions)) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) {
                        $selectedSolutions += $match
                    }
                }
            }
            catch {
                Write-Warning "Failed to read existing alm-config.psd1 defaults: $($_.Exception.Message)"
            }
        }

        if ($selectedSolutions.Count -gt 0) {
            Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        

        $selectedSolutions = @(Select-OrderedSolutions -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)
        
        if ($selectedSolutions.Count -eq 0) {
            Write-Host "No solutions selected." -ForegroundColor Yellow
            return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }
        }
        
        Write-Host "Final selection:"
        foreach ($sol in $selectedSolutions) {
            Write-Host "  - $($sol.friendlyname) ($($sol.uniquename))"
        }
        
        # Convert to the format needed for alm-config.psd1
        $configSolutions = @()
        foreach ($sol in $selectedSolutions) {
            $configSolutions += @{
                name            = $sol.uniquename
                deployUnmanaged = $false
            }
        }
        
        return @{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName }
        
    }
    catch {
        Write-Host "Error retrieving solutions from Dataverse: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Update-AlmConfigInWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Solutions,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }
    $changed = Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $Solutions -CreateIfMissing -TemplatePath $templatePath

    if ($changed) {
        Write-Host 'Updated alm-config.psd1 in the working tree.' -ForegroundColor Green
    }
    else {
        Write-Host 'No changes to alm-config.psd1; solutions already configured.' -ForegroundColor Green
    }

    return $changed
}

#endregion

#region Deployment Environments Selection

function Ensure-DataverseApplicationUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring application user '$ApplicationId' exists in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = $EnvironmentUrl }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    }

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Check/Create System User
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ applicationid = $ApplicationId } -Columns "systemuserid" | Select-Object -First 1
    $userId = $null

    if ($user) {
        Write-Host "User already exists. ID: $($user.systemuserid)"
        $userId = $user.systemuserid
    }
    else {
        Write-Host "Creating application user..."
        $userAttributes = @{
            "applicationid" = $ApplicationId
            "businessunitid" = $rootBuId
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "User created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating user with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "User is already associated with '$roleName' role."
    }
}

function Ensure-DataverseServiceAccountUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN,
        [Parameter(Mandatory)][string]$TenantId
    )

    Write-Host "Ensuring service account '$ServiceAccountUPN' has System Administrator role in '$EnvironmentUrl'..." -ForegroundColor DarkGray

    $conn = Get-DataverseConnection -Url $EnvironmentUrl -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = $EnvironmentUrl }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    }

    if (-not $conn) {
        throw "Failed to connect to Dataverse."
    }

    # 1. Get Root Business Unit
    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    # 2. Get System Administrator Role
    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    # 3. Find the System User by UPN
    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ 
        domainname = $ServiceAccountUPN
    } -Columns "systemuserid","fullname" | Select-Object -First 1
    
    $userId = $null
    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account user: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account user '$ServiceAccountUPN' not found. Creating..."
        $userAttributes = @{
            "domainname" = $ServiceAccountUPN
            "businessunitid" = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname" = "Service"
            "lastname" = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account user created. ID: $userId"
    }

    # 4. Associate User with Role
    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-ExistingEnvironmentsFromWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch
    )

    return @(Get-AzDoDeploymentEnvironmentNamesFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)
}

function Get-AzDoExistingEnvironmentServiceAccountUPN {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    try {
        $existingVarGroup = Get-VSTeamVariableGroup -ProjectName $ProjectName -Name "Environment-$EnvironmentName" -ErrorAction SilentlyContinue
        if ($existingVarGroup -and $existingVarGroup.variables -and $existingVarGroup.variables.PSObject.Properties.Name -contains 'DataverseServiceAccountUPN') {
            return $existingVarGroup.variables.DataverseServiceAccountUPN.value
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-AzDoExistingEnvironmentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $serviceAccountUPN = Get-AzDoExistingEnvironmentServiceAccountUPN -ProjectName $ProjectName -EnvironmentName $EnvironmentName
    $endpoint = $null
    try {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
    }
    catch {
        $endpoint = $null
    }

    $credentials = $null
    $environmentUrl = $null
    if ($endpoint) {
        $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $endpoint.url

        $applicationId = $null
        $resolvedTenantId = $TenantId
        if ($endpoint.authorization -and $endpoint.authorization.parameters) {
            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'applicationId') {
                $applicationId = $endpoint.authorization.parameters.applicationId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'serviceprincipalid') {
                $applicationId = $endpoint.authorization.parameters.serviceprincipalid
            }

            if ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantId' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantId)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantId
            }
            elseif ($endpoint.authorization.parameters.PSObject.Properties.Name -contains 'tenantid' -and -not [string]::IsNullOrWhiteSpace($endpoint.authorization.parameters.tenantid)) {
                $resolvedTenantId = $endpoint.authorization.parameters.tenantid
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
            $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
            $authType = if ($endpoint.authorization -and $endpoint.authorization.scheme -eq 'WorkloadIdentityFederation') { 'WIF' } else { 'Secret' }

            $credentials = [pscustomobject]@{
                Name                        = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
                ApplicationId               = $applicationId
                ApplicationObjectId         = $(if ($application) { $application.id } else { $null })
                ClientSecret                = $null
                TenantId                    = $resolvedTenantId
                AuthType                    = $authType
                IsExistingServiceConnection = $true
                HasExistingSecret           = ($authType -eq 'Secret')
            }
        }
    }

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $EnvironmentName
        Url               = $environmentUrl
        Credentials       = $credentials
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Get-AzDoEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$ProjectName,
        [Parameter()][string]$OrganizationId,
        [Parameter()][string]$OrganizationName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN,
        [Parameter()][bool]$IsDevelopmentEnvironment = $false
    )

    $creds = Get-PowerPlatformSCCredentials `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -ProjectName $ProjectName `
        -EnvironmentName $EnvironmentName `
        -OrganizationId $OrganizationId `
        -OrganizationName $OrganizationName `
        -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName            = $EnvironmentName
        FriendlyName         = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url                  = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials          = $creds
        ServiceAccountUPN    = $serviceAccountUPN
        IsDevelopmentEnvironment = $IsDevelopmentEnvironment
    }
}

function Get-DataverseEnvironmentsSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][string]$ExcludedUrl,
        [Parameter()][string]$RepoRoot,
        [Parameter()][string]$Branch,
        [Parameter()][string]$ProjectName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$OrganizationId,
        [Parameter()][string]$OrganizationName,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    $selectedEnvironments = @()
    $credentialsForReuse = @($ExistingCredentials)
    $serviceAccountsForReuse = @($ExistingServiceAccounts)
    $normalizedExcludedUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludedUrl

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot) -and -not [string]::IsNullOrWhiteSpace($Branch) -and $ProjectName) {
        $existingNames = @(Get-ExistingEnvironmentsFromWorkingTree -RepoRoot $RepoRoot -Branch $Branch)

        if ($existingNames.Count -gt 0) {
            Write-Host "Found $($existingNames.Count) environment(s) in deployment pipeline. Pre-populating the deployment environment table..." -ForegroundColor Cyan

            foreach ($name in $existingNames) {
                if ($selectedEnvironments | Where-Object { $_.ShortName -ieq $name }) {
                    continue
                }

                $existingEnvironmentState = Get-AzDoExistingEnvironmentState -ProjectName $ProjectName -EnvironmentName $name -TenantId $TenantId

                $existingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingEnvironmentState.Url
                if ($existingEnvironmentUrl -eq $normalizedExcludedUrl) {
                    Write-Warning "Skipping existing deployment stage '$name' because it points at the selected DEV environment URL."
                    continue
                }

                $selectedEnvironments += [pscustomobject]@{
                    ShortName            = $name
                    FriendlyName         = $(if (-not [string]::IsNullOrWhiteSpace($existingEnvironmentState.FriendlyName)) { $existingEnvironmentState.FriendlyName } else { "$name (Existing)" })
                    Url                  = $existingEnvironmentUrl
                    Credentials          = $existingEnvironmentState.Credentials
                    ServiceAccountUPN    = $existingEnvironmentState.ServiceAccountUPN
                    ConfigurationPending = (($null -eq $existingEnvironmentState.Credentials) -or [string]::IsNullOrWhiteSpace($existingEnvironmentState.ServiceAccountUPN))
                }
            }
        }
    }

    $selectedEnvironments = @(Select-ConfiguredDeploymentEnvironments `
        -InitialEnvironments $selectedEnvironments `
        -Heading 'Target Deployment Environments' `
        -Title 'Manage deployment environments' `
        -GuidanceLines @(
            'Add each deployment environment together with the service principal choice and the Dataverse service account that should own automation in that environment.',
            'The summary table lets you review environment URLs, authentication choices, and service-account ownership together before the script updates DEPLOY YAML and Azure DevOps resources.',
            'Best practice: keep the short names stable and in promotion order because that order becomes the generated deployment stage sequence.'
        ) `
        -DocRelativePath 'docs/setup/azdo-manual-setup.md' `
        -Ref $ALM4DataverseRef `
        -AddEnvironmentScriptBlock {
            param($currentSelections)

            $selectedEnv = Select-DataverseEnvironment -Prompt 'Select a deployment environment' -ExcludeUrl $ExcludedUrl
            if (-not $selectedEnv) {
                return $null
            }

            $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
            if ($currentSelections | Where-Object { $_.Url -ieq $url }) {
                Write-Host "An environment with Url '$url' is already selected." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
            $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue ''
            if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($currentSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($currentSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            return Get-AzDoEnvironmentConfiguration `
                -EnvironmentName $shortName `
                -EnvironmentUrl $url `
                -FriendlyName $selectedEnv.FriendlyName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -OrganizationId $OrganizationId `
                -OrganizationName $OrganizationName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension
        } `
        -EditEnvironmentScriptBlock {
            param($currentSelections, $environmentToEdit, $environmentIndex)

            $otherSelections = @()
            for ($selectionIndex = 0; $selectionIndex -lt $currentSelections.Count; $selectionIndex++) {
                if ($selectionIndex -ne $environmentIndex) {
                    $otherSelections += $currentSelections[$selectionIndex]
                }
            }

            $currentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environmentToEdit.Url
            $selectedEnv = Select-DataverseEnvironment -Prompt "Select the deployment environment for '$($environmentToEdit.ShortName)'" -ExcludeUrl $ExcludedUrl -PreferredUrl $currentUrl
            if (-not $selectedEnv) {
                return $null
            }

            $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
            if ($otherSelections | Where-Object { $_.Url -ieq $url }) {
                Write-Host "An environment with Url '$url' is already selected." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
            $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue $environmentToEdit.ShortName
            if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                Write-Host "An environment with short name '$shortName' is already selected (case-insensitive match)." -ForegroundColor Red
                Start-Sleep -Seconds 2
                return $null
            }

            $currentCredentials = @($ExistingCredentials)
            $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
            $currentServiceAccounts = @($ExistingServiceAccounts)
            $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

            return Get-AzDoEnvironmentConfiguration `
                -EnvironmentName $shortName `
                -EnvironmentUrl $url `
                -FriendlyName $selectedEnv.FriendlyName `
                -ExistingCredentials $currentCredentials `
                -ExistingServiceAccounts $currentServiceAccounts `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -OrganizationId $OrganizationId `
                -OrganizationName $OrganizationName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExistingCredential $environmentToEdit.Credentials `
                -ExistingServiceAccountUPN $environmentToEdit.ServiceAccountUPN
        })

    $completedEnvironments = @()
    foreach ($selectedEnvironment in @($selectedEnvironments)) {
        if ([string]::IsNullOrWhiteSpace($selectedEnvironment.ShortName)) {
            continue
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnvironment.Url
        $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($selectedEnvironment.FriendlyName)) { $selectedEnvironment.ShortName } else { $selectedEnvironment.FriendlyName }

        if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl)) {
            Write-Warning "Environment '$($selectedEnvironment.ShortName)' was detected in the deployment pipeline but no matching Service Endpoint URL was found. You'll be asked to resolve it now."
            $resolvedEnvironment = Select-DataverseEnvironment -Prompt "Resolve the Dataverse environment for existing deployment stage '$($selectedEnvironment.ShortName)'" -ExcludeUrl $ExcludedUrl -PreferredUrl $selectedEnvironment.Url
            if (-not $resolvedEnvironment) {
                throw "No Dataverse environment selected for existing deployment stage '$($selectedEnvironment.ShortName)'."
            }

            $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $resolvedEnvironment.Endpoints['WebApplication']
            $resolvedFriendlyName = $resolvedEnvironment.FriendlyName
        }

        if ($resolvedEnvironmentUrl -eq $normalizedExcludedUrl) {
            Write-Warning "Skipping deployment environment '$($selectedEnvironment.ShortName)' because it points at the selected DEV environment URL."
            continue
        }

        $needsConfiguration = (
            ($selectedEnvironment.PSObject.Properties.Name -contains 'ConfigurationPending' -and $selectedEnvironment.ConfigurationPending) -or
            ($null -eq $selectedEnvironment.Credentials) -or
            [string]::IsNullOrWhiteSpace($selectedEnvironment.ServiceAccountUPN)
        )

        if ($needsConfiguration) {
            Write-Host "Completing configuration for existing deployment environment '$($selectedEnvironment.ShortName)'..." -ForegroundColor Yellow
            $completedEnvironment = Get-AzDoEnvironmentConfiguration `
                -EnvironmentName $selectedEnvironment.ShortName `
                -EnvironmentUrl $resolvedEnvironmentUrl `
                -FriendlyName $resolvedFriendlyName `
                -ExistingCredentials $credentialsForReuse `
                -ExistingServiceAccounts $serviceAccountsForReuse `
                -TenantId $TenantId `
                -ProjectName $ProjectName `
                -OrganizationId $OrganizationId `
                -OrganizationName $OrganizationName `
                -UseAlm4DataverseExtension $UseAlm4DataverseExtension `
                -ExistingCredential $selectedEnvironment.Credentials `
                -ExistingServiceAccountUPN $selectedEnvironment.ServiceAccountUPN
        }
        else {
            $completedEnvironment = [pscustomobject]@{
                ShortName         = $selectedEnvironment.ShortName
                FriendlyName      = $resolvedFriendlyName
                Url               = $resolvedEnvironmentUrl
                Credentials       = $selectedEnvironment.Credentials
                ServiceAccountUPN = $selectedEnvironment.ServiceAccountUPN
            }
        }

        $completedEnvironments += $completedEnvironment
        if ($completedEnvironment.Credentials -and -not ($credentialsForReuse | Where-Object { $_.ApplicationId -eq $completedEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $completedEnvironment.Credentials.TenantId })) {
            $credentialsForReuse += $completedEnvironment.Credentials
        }
        if (-not [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN) -and $serviceAccountsForReuse -notcontains $completedEnvironment.ServiceAccountUPN) {
            $serviceAccountsForReuse += $completedEnvironment.ServiceAccountUPN
        }
    }

    return @($completedEnvironments)
}

function Update-DeployPipelineInWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Environments,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    if ($Environments.Count -eq 0) { return $false }

    $deployYamlName = "DEPLOY-$Branch.yml"
    $deployYamlPath = Join-Path $RepoRoot "pipelines\$deployYamlName"
    if (-not (Test-Path $deployYamlPath)) {
        throw "pipelines\$deployYamlName not found"
    }

    $originalContent = Get-Content -LiteralPath $deployYamlPath -Raw
    $contentLines = Get-Content -LiteralPath $deployYamlPath
    $cleanedContent = @()
    $i = 0
    while ($i -lt $contentLines.Count) {
        $line = $contentLines[$i]
        if ($line.Trim() -eq '- template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse') {
            $i++
            if ($i -lt $contentLines.Count -and $contentLines[$i].Trim() -eq 'parameters:') {
                $i++
                while ($i -lt $contentLines.Count -and $contentLines[$i] -match '^\s{6}\S') {
                    $i++
                }
            }
        }
        else {
            $cleanedContent += $line
            $i++
        }
    }

    $newStages = "`n"
    foreach ($env in $Environments) {
        $newStages += "  - template: pipelines/templates/stages/deploy-environment.yml@ALM4Dataverse`n"
        $newStages += "    parameters:`n"
        $newStages += "      environmentName: $($env.ShortName)`n"
        $newStages += "      useAlm4DataverseExtension: $($UseAlm4DataverseExtension.ToString().ToLowerInvariant())`n"
    }

    $updatedContent = (($cleanedContent -join [Environment]::NewLine).TrimEnd() + $newStages).TrimEnd() + [Environment]::NewLine
    if ($updatedContent -eq $originalContent) {
        Write-Host "$deployYamlName already matches the selected deployment environments." -ForegroundColor Green
        return $false
    }

    Set-Content -LiteralPath $deployYamlPath -Value $updatedContent -NoNewline
    Write-Host "$deployYamlName updated in the working tree." -ForegroundColor Green
    return $true
}

function New-AzDoPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryId,
        [Parameter(Mandatory)][string]$SourceBranch,
        [Parameter(Mandatory)][string]$TargetBranch,
        [Parameter(Mandatory)][string]$Title,
        [Parameter()][string]$Description
    )

    $body = @{
        sourceRefName = "refs/heads/$SourceBranch"
        targetRefName = "refs/heads/$TargetBranch"
        title         = $Title
        description   = $Description
    }

    return Invoke-VSTeamRequest -Method POST -Resource "git/repositories/$RepositoryId/pullrequests" -Body ($body | ConvertTo-Json -Depth 10) -ContentType 'application/json' -Version '7.1'
}

function Publish-AzDoRepoChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][object]$Repository
    )

    Push-Location $RepoRoot
    try {
        & git add -A
        if ($LASTEXITCODE -ne 0) {
            throw 'Git add failed.'
        }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)
        if (-not $hasChanges) {
            Write-Host 'No changes to commit; main repo already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup' 2>$null
        & git config user.email 'setup@alm4dataverse.local' 2>$null

        & git commit -m $PublishPlan.CommitMessage 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw 'Git commit failed.'
        }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git -c "http.extraheader=AUTHORIZATION: bearer $AccessToken" push -u origin $PublishPlan.BranchName 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw 'Git push failed.'
        }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
            $pullRequest = New-AzDoPullRequest `
                -RepositoryId $Repository.Id `
                -SourceBranch $PublishPlan.BranchName `
                -TargetBranch $PublishPlan.TargetBranch `
                -Title $PublishPlan.PullRequestTitle `
                -Description $PublishPlan.PullRequestDescription

            if ($pullRequest -and $pullRequest._links -and $pullRequest._links.web -and $pullRequest._links.web.href) {
                $pullRequestUrl = $pullRequest._links.web.href
            }
            elseif ($pullRequest -and $pullRequest.url) {
                $pullRequestUrl = $pullRequest.url
            }
        }

        Write-Host 'Main repository updated successfully.' -ForegroundColor Green
        return [pscustomobject]@{
            HasChanges     = $true
            BranchName     = $PublishPlan.BranchName
            TargetBranch   = $PublishPlan.TargetBranch
            PullRequestUrl = $pullRequestUrl
            Mode           = $PublishPlan.Mode
        }
    }
    finally {
        Pop-Location
    }
}

function Apply-AzDoEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$OrganizationName,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter()][object]$ExportPipeline,
        [Parameter()][object]$DeployPipeline,
        [Parameter()][bool]$UseAlm4DataverseExtension = $true
    )

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN
    $pipelineForPermissions = if ($EnvironmentConfiguration.IsDevelopmentEnvironment) { $ExportPipeline } else { $DeployPipeline }

    $endpoint = $null
    if (-not $creds.IsExistingServiceConnection) {
        $endpointParams = @{
            ProjectName         = $ProjectName
            ServiceEndpointName = $EnvironmentConfiguration.ShortName
            EnvironmentUrl      = $EnvironmentConfiguration.Url
            ApplicationId       = $creds.ApplicationId
            TenantId            = $creds.TenantId
        }

        if ($creds.AuthType -eq 'WIF') {
            $endpointParams.AuthType = 'WIF'
        }
        else {
            $endpointParams.ClientSecret = $creds.ClientSecret
            $endpointParams.AuthType = 'Secret'
        }

        $endpoint = Ensure-AzDoServiceEndpoint @endpointParams

        if ($creds.AuthType -eq 'WIF') {
            $wifIssuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer
            $wifSubject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
            if ($wifIssuer -and $wifSubject) {
                $appObjectId = $creds.ApplicationObjectId
                if (-not $appObjectId) {
                    $graphToken = Get-AuthToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $creds.TenantId
                    $gHeaders = @{ Authorization = "Bearer $($graphToken.AccessToken)" }
                    $gUri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($creds.ApplicationId)'&`$select=id,appId"
                    $gResult = Invoke-RestMethod -Uri $gUri -Headers $gHeaders -Method Get
                    if ($gResult.value.Count -gt 0) { $appObjectId = $gResult.value[0].id }
                }
                if ($appObjectId) {
                    $safeOrgName = ConvertTo-UrlSafeName -Name $OrganizationName
                    $safeProjectName = ConvertTo-UrlSafeName -Name $ProjectName
                    $safeSCName = ConvertTo-UrlSafeName -Name $EnvironmentConfiguration.ShortName
                    [void](Add-EntraIdFederatedCredential `
                        -ApplicationObjectId $appObjectId `
                        -TenantId $creds.TenantId `
                        -Issuer $wifIssuer `
                        -Subject $wifSubject `
                        -CredentialName "AzDO-$safeOrgName-$safeProjectName-$safeSCName")
                }
                else {
                    Write-Warning 'Could not determine Application Object ID. Federated credential not added - add it manually in Entra ID.'
                }
            }
            else {
                Write-Warning 'Service connection does not expose WIF issuer/subject properties. Federated credential not added - add it manually in Entra ID.'
            }
        }
    }
    else {
        $endpoints = @(Get-VSTeamServiceEndpoint -ProjectName $ProjectName -ErrorAction SilentlyContinue)
        $endpoint = $endpoints | Where-Object { $_.name -eq $EnvironmentConfiguration.ShortName } | Select-Object -First 1
    }

    if ($endpoint -and $endpoint.id -and $pipelineForPermissions) {
        Ensure-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'endpoint' -ResourceId $endpoint.id -PipelineId $pipelineForPermissions.id
    }

    if (-not $EnvironmentConfiguration.IsDevelopmentEnvironment) {
        $azDoEnv = Ensure-AzDoEnvironment -Organization $OrganizationName -Project $ProjectName -EnvironmentName $EnvironmentConfiguration.ShortName -Description "Deployment environment for $($EnvironmentConfiguration.ShortName)"
        if ($azDoEnv -and $DeployPipeline) {
            Ensure-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'environment' -ResourceId $azDoEnv.id -PipelineId $DeployPipeline.id
        }
    }

    Ensure-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $creds.TenantId
    Ensure-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $creds.TenantId

    $groupName = "Environment-$($EnvironmentConfiguration.ShortName)"
    $variables = @{
        'CONNREF_example_uniquename' = 'connectionid'
        'ENVVAR_example_uniquename'  = 'value'
        'DataverseServiceAccountUPN' = $serviceAccountUPN
    }

    $varGroup = $null
    if ($EnvironmentConfiguration.IsDevelopmentEnvironment) {
        $varGroup = Ensure-AzDoVariableGroupExists -Organization $OrganizationName -Project $ProjectName -ProjectId $ProjectId -GroupName $groupName -Variables $variables
    }
    else {
        $varGroup = Ensure-AzDoVariableGroupExists -Organization $OrganizationName -Project $ProjectName -ProjectId $ProjectId -GroupName $groupName -Variables $variables
    }

    if ($varGroup -and $varGroup.id -and $pipelineForPermissions) {
        Ensure-AzDoPipelinePermission -Organization $OrganizationName -Project $ProjectName -ResourceType 'variablegroup' -ResourceId $varGroup.id -PipelineId $pipelineForPermissions.id
    }
}

Write-Section "Selecting Dataverse solution(s) to manage"

Write-SetupGuidance -Lines @(
    "Select the unmanaged solutions from your DEV environment that belong in source control.",
    "Best practice: keep them in dependency order because that is the order written into alm-config.psd1."
) -DocRelativePath 'docs/config/alm-config.md' -Ref $ALM4DataverseRef

$existingDevEnvironmentState = Get-AzDoExistingEnvironmentState -ProjectName $selectedProject.Name -EnvironmentName $script:devEnvironmentShortName -TenantId $adoAuthResult.TenantId

$solutionData = Invoke-WithErrorHandling -OperationName "Selecting Dataverse Solutions" -ScriptBlock {
    $existingConfigPath = Join-Path $mainRepoWorkingRoot 'alm-config.psd1'
    $result = Get-DataverseSolutionsSelection -ExistingConfigPath $existingConfigPath -ExistingEnvironmentUrl $existingDevEnvironmentState.Url
    return $result
}

$solutions = $solutionData.Solutions
$devEnvUrl = $solutionData.EnvironmentUrl
$devEnvFriendlyName = $solutionData.EnvironmentFriendlyName

if ($solutions.Count -gt 0) {
    Invoke-WithErrorHandling -OperationName "Updating alm-config.psd1 with Solutions" -AllowSkip -ScriptBlock {
        $configUpdated = Update-AlmConfigInWorkingTree -Solutions $solutions -RepoRoot $mainRepoWorkingRoot
        if ($configUpdated) {
            Write-Host "Updated alm-config.psd1 with $($solutions.Count) solution(s) in the working tree."
        }
    } | Out-Null
}

$devEnvironmentConfiguration = $null
if ($devEnvUrl) {
    Write-Section "Configure DEV environment access"
    Write-SetupGuidance -Lines @(
        "The DEV environment uses the fixed short name '$script:devEnvironmentShortName' so EXPORT and BUILD always target the branch-specific development slot.",
        'Choose the service principal and Dataverse service account now so the later review table includes the full environment configuration instead of only the URLs.',
        'Best practice: use a dedicated service account for automation ownership and a separate service principal per environment where practical.'
    ) -DocRelativePath 'docs/config/azdo-environment-service-connection.md' -Ref $ALM4DataverseRef

    $devEnvironmentConfiguration = Invoke-WithErrorHandling -OperationName 'Selecting DEV environment credentials' -ScriptBlock {
        Get-AzDoEnvironmentConfiguration `
            -EnvironmentName $script:devEnvironmentShortName `
            -EnvironmentUrl $devEnvUrl `
            -FriendlyName $devEnvFriendlyName `
            -ExistingCredentials $credentialsCache `
            -ExistingServiceAccounts $serviceAccountsCache `
            -TenantId $adoAuthResult.TenantId `
            -ProjectName $selectedProject.Name `
            -OrganizationId $orgId `
            -OrganizationName $orgName `
            -UseAlm4DataverseExtension $script:useAlm4DataverseExtension `
                -ExistingCredential $existingDevEnvironmentState.Credentials `
                -ExistingServiceAccountUPN $existingDevEnvironmentState.ServiceAccountUPN `
            -IsDevelopmentEnvironment $true
    }

    if (-not ($credentialsCache | Where-Object { $_.ApplicationId -eq $devEnvironmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $devEnvironmentConfiguration.Credentials.TenantId })) {
        $credentialsCache += $devEnvironmentConfiguration.Credentials
    }
    if ($serviceAccountsCache -notcontains $devEnvironmentConfiguration.ServiceAccountUPN) {
        $serviceAccountsCache += $devEnvironmentConfiguration.ServiceAccountUPN
    }
}

Write-Section "Selecting Deployment Environments"

Write-SetupGuidance -Lines @(
    "Select Dataverse environments to deploy to in the required order and choose the corresponding authentication + service-account details as you add each one.",
    "Best practice: list lower environments first because DEPLOY stages will be generated in that sequence and the summary table should mirror your intended promotion path."
) -DocRelativePath 'docs/setup/azdo-manual-setup.md' -Ref $ALM4DataverseRef

$environments = Invoke-WithErrorHandling -OperationName "Selecting Deployment Environments" -ScriptBlock {
    return Get-DataverseEnvironmentsSelection `
        -ExcludedUrl $devEnvUrl `
        -RepoRoot $mainRepoWorkingRoot `
        -Branch $script:mainRepoBranch `
        -ProjectName $selectedProject.Name `
        -ExistingCredentials $credentialsCache `
        -ExistingServiceAccounts $serviceAccountsCache `
        -TenantId $adoAuthResult.TenantId `
        -OrganizationId $orgId `
        -OrganizationName $orgName `
        -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
}

if ($environments.Count -gt 0) {
    Invoke-WithErrorHandling -OperationName 'Updating Deployment Pipeline' -AllowSkip -ScriptBlock {
        Update-DeployPipelineInWorkingTree -Environments $environments -RepoRoot $mainRepoWorkingRoot -Branch $script:mainRepoBranch -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
    } | Out-Null
}

$allConfiguredEnvironments = @()
if ($devEnvironmentConfiguration) {
    $allConfiguredEnvironments += $devEnvironmentConfiguration
}
$allConfiguredEnvironments += $environments

Write-Section 'Review Dataverse environment configuration'
Show-EnvironmentConfigurationTable -EnvironmentConfigurations $allConfiguredEnvironments
Write-Host ''
if (-not (Read-YesNo -Prompt 'Proceed with these Dataverse environment settings?')) {
    throw 'Setup cancelled so you can revise the environment configuration selections.'
}

$repoPublishResult = Invoke-WithErrorHandling -OperationName 'Publishing main repository changes' -ScriptBlock {
    Publish-AzDoRepoChanges -RepoRoot $mainRepoWorkingRoot -PublishPlan $repoPublishPlan -AccessToken $azDevOpsAccessToken -Repository $mainRepo
}

Invoke-WithErrorHandling -OperationName 'Setting Up Build Service Permissions' -ScriptBlock {
    Write-Section 'Ensuring Build Service has Contribute on main repo'
    Ensure-AzDoBuildServiceHasContributeOnRepo -Organization $orgName -ProjectName $selectedProject.Name -ProjectId $selectedProject.Id -RepositoryId $mainRepo.Id
} | Out-Null

Invoke-WithErrorHandling -OperationName 'Creating Pipeline Definitions' -ScriptBlock {
    Ensure-AzDoPipelinesForMainRepo -Organization $orgName -Project $selectedProject.Name -Repository $mainRepo -YamlFiles $script:yamlFiles -FolderPath "\$($mainRepo.Name)"
} | Out-Null

Invoke-WithErrorHandling -OperationName 'Authorizing Pipelines for Repositories' -AllowSkip -ScriptBlock {
    Write-Section 'Authorizing pipelines for repositories'
    $pipelineNames = $script:yamlFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) }
    $allPipelines = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name
    $pipelineFolder = "\$($mainRepo.Name)"

    foreach ($name in $pipelineNames) {
        $pipeline = $allPipelines | Where-Object { $_.name -eq $name -and $_.path -eq $pipelineFolder } | Select-Object -First 1
        if ($pipeline) {
            $mainRepoResourceId = "$($selectedProject.Id).$($mainRepo.Id)"
            Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'repository' -ResourceId $mainRepoResourceId -PipelineId $pipeline.id

            $sharedRepoResourceId = "$($selectedProject.Id).$($repo.Id)"
            Ensure-AzDoPipelinePermission -Organization $orgName -Project $selectedProject.Name -ResourceType 'repository' -ResourceId $sharedRepoResourceId -PipelineId $pipeline.id
        }
    }
} | Out-Null

$pipelineFolder = "\$($mainRepo.Name)"
$exportPipeline = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name | Where-Object { $_.name -eq 'EXPORT' -and $_.path -eq $pipelineFolder } | Select-Object -First 1
$deployPipeline = Get-VSTeamBuildDefinition -ProjectName $selectedProject.Name | Where-Object { $_.name -eq "DEPLOY-$script:mainRepoBranch" -and $_.path -eq $pipelineFolder } | Select-Object -First 1

if (-not $exportPipeline) { Write-Warning 'EXPORT pipeline not found. Skipping some DEV authorizations.' }
if (-not $deployPipeline) { Write-Warning "DEPLOY-$script:mainRepoBranch pipeline not found. Skipping some deployment authorizations." }

foreach ($env in $allConfiguredEnvironments) {
    Invoke-WithErrorHandling -OperationName "Applying environment configuration for '$($env.ShortName)'" -AllowSkip -ScriptBlock {
        Write-Section "Applying environment configuration for '$($env.ShortName)'"
        Apply-AzDoEnvironmentConfiguration `
            -EnvironmentConfiguration $env `
            -OrganizationName $orgName `
            -ProjectName $selectedProject.Name `
            -ProjectId $selectedProject.Id `
            -ExportPipeline $exportPipeline `
            -DeployPipeline $deployPipeline `
            -UseAlm4DataverseExtension $script:useAlm4DataverseExtension
    } | Out-Null
}

#endregion

if ($mainRepoWorkingRoot -and (Test-Path $mainRepoWorkingRoot)) {
    try { Remove-Item -LiteralPath $mainRepoWorkingRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Clear-Host
Write-Host "Setup completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Access your Azure DevOps project at" -ForegroundColor Green
Write-Host "https://dev.azure.com/$orgName/$($selectedProject.Name)/_build" -ForegroundColor Green
Write-Host ""
if ($repoPublishResult -and $repoPublishResult.Mode -eq 'PullRequest' -and -not [string]::IsNullOrWhiteSpace($repoPublishResult.PullRequestUrl)) {
    Write-Host "Repository changes were pushed to branch '$($repoPublishResult.BranchName)' and a pull request was created:" -ForegroundColor Green
    Write-Host $repoPublishResult.PullRequestUrl -ForegroundColor Green
    Write-Host ""
}
elseif ($repoPublishResult -and $repoPublishResult.HasChanges) {
    Write-Host "Repository changes were committed directly to '$($repoPublishResult.BranchName)'." -ForegroundColor Green
    Write-Host ""
}

Write-Host "Next steps:" -ForegroundColor Green
Write-Host (Get-Alm4DataverseDocUrl -RelativePath 'docs/setup/azdo-automated-setup.md' -Ref $ALM4DataverseRef) -ForegroundColor Green
Write-Host (Get-Alm4DataverseDocUrl -RelativePath 'docs/config/azdo-environment-variable-group.md' -Ref $ALM4DataverseRef) -ForegroundColor Green
