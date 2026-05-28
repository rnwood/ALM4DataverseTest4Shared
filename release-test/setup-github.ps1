
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
        throw "This script appears to be running in development mode but alm-config-defaults.psd1 was not found at $configPath. Please download the released version from https://github.com/ALM4Dataverse/ALM4Dataverse/releases/latest/download/setup-github.ps1"
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

# Verify GitHub CLI is available
$ghCmd = Get-Command gh -ErrorAction SilentlyContinue
if (-not $ghCmd) {
    Write-Host ""
    Write-Host "GitHub CLI (gh) is required but was not found." -ForegroundColor Red
    Write-Host "Please install it from https://cli.github.com/ and re-run this script." -ForegroundColor Red
    Write-Host ""
    throw "GitHub CLI (gh) not found."
}

# Verify Git is available
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Host ""
    Write-Host "Git is required but was not found." -ForegroundColor Red
    Write-Host "Please install it from https://git-scm.com/ and re-run this script." -ForegroundColor Red
    Write-Host ""
    throw "Git not found."
}

Write-Host "GitHub CLI: $($ghCmd.Source)"
Write-Host "Git: $($gitCmd.Source)"

if ($resolveDevRefAfterGitIsAvailable) {
    $ALM4DataverseRef = Resolve-DevelopmentDefaultAlm4DataverseRef -PrimaryRepositoryPath $upstreamRepo -FallbackRef $ALM4DataverseRef
    Write-Host "Development mode: Resolved ALM4DataverseRef to '$ALM4DataverseRef'" -ForegroundColor Yellow
}

#region GitHub CLI Operations

function Invoke-GhApi {
    <#
    .SYNOPSIS
        Calls the GitHub REST API using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter()][string]$Method = 'GET',
        [Parameter()][object]$Body,
        [Parameter()][switch]$AllowNotFound
    )

    $ghArgs = @('api', '--method', $Method, $Endpoint)
    
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 10 -Compress
        $ghArgs += @('--input', '-')
        
        $result = $json | & gh @ghArgs 2>&1
    }
    else {
        $result = & gh @ghArgs 2>&1
    }
    
    if ($LASTEXITCODE -ne 0) {
        $errText = $result -join "`n"
        if ($AllowNotFound -and ($errText -match '404' -or $errText -match 'Not Found')) {
            return $null
        }
        throw "gh api call failed (HTTP $LASTEXITCODE): $errText"
    }
    
    if ($result) {
        try {
            return $result | ConvertFrom-Json
        }
        catch {
            return $result
        }
    }
    return $null
}

function Ensure-GitHubEnvironment {
    <#
    .SYNOPSIS
        Ensures a GitHub repository environment exists and optionally configures approvals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][int[]]$RequiredReviewerIds,
        [Parameter()][switch]$EnableApprovals
    )

    Write-Host "Ensuring GitHub environment '$EnvironmentName'..." -ForegroundColor DarkGray

    # Check if environment already exists
    $existing = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -AllowNotFound

    $body = $null
    $appliedApprovals = $false
    if ($EnableApprovals) {
        $reviewers = @()
        foreach ($reviewerId in @($RequiredReviewerIds)) {
            if ($reviewerId -gt 0) {
                $reviewers += @{ type = 'User'; id = $reviewerId }
            }
        }

        if ($reviewers.Count -gt 0) {
            $body = @{ reviewers = $reviewers }
            $appliedApprovals = $true
        }
        else {
            Write-Host "Approvals were requested but no valid reviewer IDs were supplied; configuring environment without required reviewers." -ForegroundColor Yellow
        }
    }

    $action = if ($existing) { 'Updating' } else { 'Creating' }
    Write-Host "$action environment '$EnvironmentName'..." -ForegroundColor Yellow
    if ($body) {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT' -Body $body
    }
    else {
        $updated = Invoke-GhApi -Endpoint "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($EnvironmentName))" -Method 'PUT'
    }

    if ($appliedApprovals) {
        Write-Host "Configured environment '$EnvironmentName' with required reviewers." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Configured environment '$EnvironmentName'." -ForegroundColor DarkGray
    }

    return $updated
}

function Set-GitHubEnvironmentSecret {
    <#
    .SYNOPSIS
        Sets a secret in a GitHub repository environment using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )

    Write-Host "Setting secret '$SecretName' in environment '$EnvironmentName'..." -ForegroundColor DarkGray

    # Avoid piping to native commands here: PowerShell appends a trailing newline
    # when sending strings over stdin, which would corrupt client secret values.
    $normalizedSecretValue = ($SecretValue -replace "[\r\n]+$", "")

    $result = & gh secret set $SecretName `
        --repo "$Owner/$Repo" `
        --env $EnvironmentName `
        --body $normalizedSecretValue 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set secret '$SecretName': $($result -join "`n")"
    }
    Write-Host "Set secret '$SecretName'." -ForegroundColor DarkGray
}

function Set-GitHubEnvironmentVariable {
    <#
    .SYNOPSIS
        Sets a variable in a GitHub repository environment using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$VariableValue
    )

    Write-Host "Setting variable '$VariableName' in environment '$EnvironmentName'..." -ForegroundColor DarkGray

    $result = & gh variable set $VariableName `
        --repo "$Owner/$Repo" `
        --env $EnvironmentName `
        --body $VariableValue 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set variable '$VariableName'." -ForegroundColor DarkGray
}

function Set-GitHubRepoSecret {
    <#
    .SYNOPSIS
        Sets a repository-level secret using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter(Mandatory)][string]$SecretValue
    )

    Write-Host "Setting repo-level secret '$SecretName'..." -ForegroundColor DarkGray

    # Avoid piping to native commands here: PowerShell appends a trailing newline
    # when sending strings over stdin, which would corrupt client secret values.
    $normalizedSecretValue = ($SecretValue -replace "[\r\n]+$", "")

    $result = & gh secret set $SecretName `
        --repo "$Owner/$Repo" `
        --body $normalizedSecretValue 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set repo secret '$SecretName': $($result -join "`n")"
    }
    Write-Host "Set repo-level secret '$SecretName'." -ForegroundColor DarkGray
}

function Set-GitHubRepoVariable {
    <#
    .SYNOPSIS
        Sets a repository-level variable using the gh CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$VariableValue
    )

    Write-Host "Setting repo-level variable '$VariableName'..." -ForegroundColor DarkGray

    $result = & gh variable set $VariableName `
        --repo "$Owner/$Repo" `
        --body $VariableValue 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set repo variable '$VariableName': $($result -join "`n")"
    }
    Write-Host "Set repo-level variable '$VariableName'." -ForegroundColor DarkGray
}

function Get-GitHubEnvironmentCapabilities {
    <#
    .SYNOPSIS
        Detects whether GitHub environments and environment approval rules are available for a repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter()][int]$ApprovalReviewerId
    )

    $probeName = "alm4dataverse-setup-probe-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
    $probeEndpoint = "repos/$Owner/$Repo/environments/$([Uri]::EscapeDataString($probeName))"

    $result = [ordered]@{
        EnvironmentsAvailable = $false
        ApprovalsAvailable    = $false
        Message               = ''
    }

    try {
        try {
            # Probe base environment availability without optional protection rules.
            [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'PUT')
            $result.EnvironmentsAvailable = $true
        }
        catch {
            $result.Message = "GitHub environments are not available for this repository: $($_.Exception.Message)"
        }

        if ($result.EnvironmentsAvailable) {
            if ($ApprovalReviewerId -gt 0) {
                try {
                    # Probe required-reviewer availability separately from base environments support.
                    [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'PUT' -Body @{ reviewers = @(@{ type = 'User'; id = $ApprovalReviewerId }) })
                    $result.ApprovalsAvailable = $true
                    $result.Message = 'GitHub environments and required reviewers are available.'
                }
                catch {
                    $result.Message = "GitHub environments are available, but required reviewers are not available for this repository: $($_.Exception.Message)"
                }
            }
            else {
                $result.Message = 'GitHub environments are available, but required-reviewer support could not be probed because no reviewer id was provided.'
            }
        }
    }
    finally {
        try {
            [void](Invoke-GhApi -Endpoint $probeEndpoint -Method 'DELETE' -AllowNotFound)
        }
        catch {
            # ignore probe cleanup errors
        }
    }

    return [pscustomobject]$result
}

function Get-GitHubEnvironmentPrefix {
    <#
    .SYNOPSIS
        Derives a repository-level prefix from an environment name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $normalized = ($EnvironmentName.Trim().ToUpperInvariant() -replace '[^A-Z0-9]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "Could not derive a prefix from environment name '$EnvironmentName'."
    }

    return "${normalized}_"
}

function Set-GitHubPrefixedEnvironmentCredentials {
    <#
    .SYNOPSIS
        Stores per-environment credentials as prefixed repository-level variables/secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][object]$Credentials,
        [Parameter(Mandatory)][string]$DataverseUrl,
        [Parameter(Mandatory)][string]$ServiceAccountUPN
    )

    $prefix = Get-GitHubEnvironmentPrefix -EnvironmentName $EnvironmentName
    Write-Host "Setting prefixed repo-level credentials for '$EnvironmentName' using prefix '$prefix'..." -ForegroundColor DarkGray

    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_CLIENT_ID" -VariableValue $Credentials.ApplicationId
    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_TENANT_ID" -VariableValue $Credentials.TenantId

    if ($Credentials.AuthType -eq 'Secret' -and $Credentials.ClientSecret) {
        Set-GitHubRepoSecret -Owner $Owner -Repo $Repo -SecretName "${prefix}AZURE_CLIENT_SECRET" -SecretValue $Credentials.ClientSecret
    }

    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_URL" -VariableValue $DataverseUrl
    Set-GitHubRepoVariable -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN" -VariableValue $ServiceAccountUPN
}

function Get-GitHubRepoList {
    <#
    .SYNOPSIS
        Returns a list of repos the authenticated user has write access to.
    #>
    [CmdletBinding()]
    param()

    $result = & gh repo list --json nameWithOwner,name,owner,defaultBranchRef --limit 100 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list repositories: $($result -join "`n")"
    }
    return $result | ConvertFrom-Json
}

function Get-GitHubRepo {
    <#
    .SYNOPSIS
        Returns repository details for a single GitHub repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo
    )

    $result = & gh repo view "$Owner/$Repo" --json nameWithOwner,name,owner,defaultBranchRef 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get repository '$Owner/$Repo': $($result -join "`n")"
    }
    return $result | ConvertFrom-Json
}

function Get-GitHubActionsVariableValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter()][string]$EnvironmentName
    )

    $encodedVariableName = [Uri]::EscapeDataString($VariableName)
    $endpoint = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        "repos/$Owner/$Repo/actions/variables/$encodedVariableName"
    }
    else {
        $encodedEnvironmentName = [Uri]::EscapeDataString($EnvironmentName)
        "repos/$Owner/$Repo/environments/$encodedEnvironmentName/variables/$encodedVariableName"
    }

    $result = Invoke-GhApi -Endpoint $endpoint -AllowNotFound
    if ($null -eq $result) {
        return $null
    }

    if ($result.PSObject.Properties.Name -contains 'value') {
        return [string]$result.value
    }

    return $null
}

function Test-GitHubActionsSecretExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SecretName,
        [Parameter()][string]$EnvironmentName
    )

    $encodedSecretName = [Uri]::EscapeDataString($SecretName)
    $endpoint = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        "repos/$Owner/$Repo/actions/secrets/$encodedSecretName"
    }
    else {
        $encodedEnvironmentName = [Uri]::EscapeDataString($EnvironmentName)
        "repos/$Owner/$Repo/environments/$encodedEnvironmentName/secrets/$encodedSecretName"
    }

    $result = Invoke-GhApi -Endpoint $endpoint -AllowNotFound
    return ($null -ne $result)
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

function Get-GitHubWorkflowReferenceFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $candidateFiles = @(
        (Join-Path $RepoRoot '.github/workflows/BUILD.yml'),
        (Join-Path $RepoRoot ".github/workflows/DEPLOY-$DefaultBranch.yml"),
        (Join-Path $RepoRoot '.github/workflows/EXPORT.yml'),
        (Join-Path $RepoRoot '.github/workflows/IMPORT.yml')
    )

    foreach ($candidateFile in $candidateFiles) {
        if (-not (Test-Path -LiteralPath $candidateFile)) {
            continue
        }

        $content = Get-Content -LiteralPath $candidateFile -Raw
        $match = [regex]::Match($content, 'uses:\s*([^/\s]+/[^/\s]+)/\.github/workflows/[A-Za-z0-9._-]+@([^\s''"`]+)')
        if ($match.Success) {
            return [pscustomobject]@{
                Repository = $match.Groups[1].Value
                Reference  = $match.Groups[2].Value
            }
        }
    }

    return $null
}

function Get-GitHubDeploymentEnvironmentNamesFromRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$DefaultBranch
    )

    $deployFilePath = Join-Path $RepoRoot ".github/workflows/DEPLOY-$DefaultBranch.yml"
    if (-not (Test-Path -LiteralPath $deployFilePath)) {
        return @()
    }

    $content = Get-Content -LiteralPath $deployFilePath -Raw
    $environmentNameMatches = [regex]::Matches($content, '(?m)^\s*environment-name:\s*["'']?([^"''\r\n]+)["'']?\s*$')
    $names = @()
    foreach ($environmentNameMatch in $environmentNameMatches) {
        $name = $environmentNameMatch.Groups[1].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and $names -notcontains $name) {
            $names += $name
        }
    }

    return @($names)
}

function Get-GitHubExistingEnvironmentState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter()][string]$TenantId
    )

    $environmentClientId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'AZURE_CLIENT_ID'
    $environmentTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'AZURE_TENANT_ID'
    $environmentUrl = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'DATAVERSE_URL'
    $environmentServiceAccount = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -VariableName 'DATAVERSESERVICEACCOUNTUPN'
    $environmentSecretExists = Test-GitHubActionsSecretExists -Owner $Owner -Repo $Repo -EnvironmentName $EnvironmentName -SecretName 'AZURE_CLIENT_SECRET'

    $storageScope = $null
    $applicationId = $environmentClientId
    $resolvedTenantId = $environmentTenantId
    $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $environmentUrl
    $serviceAccountUPN = $environmentServiceAccount
    $hasExistingSecret = $environmentSecretExists

    if (-not [string]::IsNullOrWhiteSpace($environmentClientId) -or -not [string]::IsNullOrWhiteSpace($environmentUrl) -or -not [string]::IsNullOrWhiteSpace($environmentServiceAccount) -or $environmentSecretExists) {
        $storageScope = 'Environment'
    }
    else {
        $prefix = Get-GitHubEnvironmentPrefix -EnvironmentName $EnvironmentName
        $applicationId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_CLIENT_ID"
        $resolvedTenantId = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}AZURE_TENANT_ID"
        $environmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url (Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_URL")
        $serviceAccountUPN = Get-GitHubActionsVariableValue -Owner $Owner -Repo $Repo -VariableName "${prefix}DATAVERSE_SERVICE_ACCOUNT_UPN"
        $hasExistingSecret = Test-GitHubActionsSecretExists -Owner $Owner -Repo $Repo -SecretName "${prefix}AZURE_CLIENT_SECRET"

        if (-not [string]::IsNullOrWhiteSpace($applicationId) -or -not [string]::IsNullOrWhiteSpace($environmentUrl) -or -not [string]::IsNullOrWhiteSpace($serviceAccountUPN) -or $hasExistingSecret) {
            $storageScope = 'RepositoryPrefix'
        }
    }

    if (-not $storageScope) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($resolvedTenantId)) {
        $resolvedTenantId = $TenantId
    }

    $existingCredential = $null
    if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
        $application = Resolve-EntraIdApplicationByAppId -ApplicationId $applicationId -TenantId $resolvedTenantId
        $existingCredential = [pscustomobject]@{
            Name                = $(if ($application -and -not [string]::IsNullOrWhiteSpace($application.displayName)) { $application.displayName } else { "Existing-$EnvironmentName" })
            ApplicationId       = $applicationId
            ApplicationObjectId = $(if ($application) { $application.id } else { $null })
            ClientSecret        = $null
            TenantId            = $resolvedTenantId
            AuthType            = $(if ($hasExistingSecret) { 'Secret' } else { 'WIF' })
            HasExistingSecret   = $hasExistingSecret
            IsExistingCredential = $true
        }
    }

    return [pscustomobject]@{
        ShortName         = $EnvironmentName
        FriendlyName      = $EnvironmentName
        Url               = $environmentUrl
        Credentials       = $existingCredential
        ServiceAccountUPN = $serviceAccountUPN
        StorageScope      = $storageScope
    }
}

function Get-GitHubRepositoryExistingSetupState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$DefaultBranch,
        [Parameter()][string]$TenantId
    )

    $workflowReference = Get-GitHubWorkflowReferenceFromRepoClone -RepoRoot $RepoRoot -DefaultBranch $DefaultBranch
    $devEnvironmentName = "Dev-$DefaultBranch"
    $devEnvironment = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $devEnvironmentName -TenantId $TenantId
    $deploymentEnvironments = @()
    $storageScope = $null

    foreach ($environmentName in @(Get-GitHubDeploymentEnvironmentNamesFromRepoClone -RepoRoot $RepoRoot -DefaultBranch $DefaultBranch)) {
        $environmentState = Get-GitHubExistingEnvironmentState -Owner $RepoOwner -Repo $RepoName -EnvironmentName $environmentName -TenantId $TenantId
        if ($environmentState) {
            $deploymentEnvironments += $environmentState
            if (-not $storageScope -and $environmentState.StorageScope) {
                $storageScope = $environmentState.StorageScope
            }
        }
        else {
            $deploymentEnvironments += [pscustomobject]@{
                ShortName         = $environmentName
                FriendlyName      = $environmentName
                Url               = $null
                Credentials       = $null
                ServiceAccountUPN = $null
                StorageScope      = $null
            }
        }
    }

    if (-not $storageScope -and $devEnvironment -and $devEnvironment.StorageScope) {
        $storageScope = $devEnvironment.StorageScope
    }

    return [pscustomobject]@{
        SharedWorkflowRepository = $(if ($workflowReference) { $workflowReference.Repository } else { $null })
        SharedWorkflowReference  = $(if ($workflowReference) { $workflowReference.Reference } else { $null })
        CredentialStorageScope   = $storageScope
        DevEnvironment           = $devEnvironment
        DeploymentEnvironments   = @($deploymentEnvironments)
    }
}

function Get-GitHubOwnedReposForOwner {
    <#
    .SYNOPSIS
        Returns repositories owned by the specified GitHub account.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner
    )

    $repos = Invoke-GhApi -Endpoint "users/$Owner/repos?type=owner&sort=updated&per_page=100"
    if (-not $repos) {
        return @()
    }

    $normalized = @()
    foreach ($repo in @($repos)) {
        $repoFullName = $null

        if ($repo.PSObject.Properties.Name -contains 'full_name' -and -not [string]::IsNullOrWhiteSpace($repo.full_name)) {
            $repoFullName = [string]$repo.full_name
        }
        elseif (
            ($repo.PSObject.Properties.Name -contains 'owner') -and $repo.owner -and
            ($repo.owner.PSObject.Properties.Name -contains 'login') -and -not [string]::IsNullOrWhiteSpace($repo.owner.login) -and
            ($repo.PSObject.Properties.Name -contains 'name') -and -not [string]::IsNullOrWhiteSpace($repo.name)
        ) {
            $repoFullName = "$($repo.owner.login)/$($repo.name)"
        }

        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            continue
        }

        $normalized += [pscustomobject]@{
            full_name = $repoFullName
        }
    }

    return @($normalized | Sort-Object -Property full_name -Unique)
}

function Resolve-GitHubRepoFullNameFromSource {
    <#
    .SYNOPSIS
        Resolves a GitHub repository full name (owner/repo) from URL, owner/repo text, or a local git repository path.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$Source,
        [Parameter()][string]$Fallback = 'ALM4Dataverse/ALM4Dataverse'
    )

    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $trimmed = $Source.Trim()

        if ($trimmed -match '^[^/\s]+/[^/\s]+$') {
            return $trimmed
        }

        if ($trimmed -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
            return "$($Matches[1])/$($Matches[2])"
        }

        if (Test-Path -LiteralPath $trimmed) {
            try {
                $originUrl = (& git -C $trimmed config --get remote.origin.url 2>$null).Trim()
                if (-not [string]::IsNullOrWhiteSpace($originUrl) -and $originUrl -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
                    return "$($Matches[1])/$($Matches[2])"
                }
            }
            catch {
                # Fall through to fallback
            }
        }
    }

    return $Fallback
}

function Resolve-UpstreamGitRemoteSource {
    <#
    .SYNOPSIS
        Resolves an upstream git remote source usable by `git fetch`/`git clone`.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string]$ConfiguredSource,
        [Parameter(Mandatory)][string]$GitHubFullName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredSource)) {
        $trimmed = $ConfiguredSource.Trim()

        if (Test-Path -LiteralPath $trimmed) {
            return $trimmed
        }

        if ($trimmed -match '^https?://' -or $trimmed -match '^git@') {
            return $trimmed
        }

        if ($trimmed -match '^[^/\s]+/[^/\s]+$') {
            return "https://github.com/$trimmed.git"
        }

        if ($trimmed -match 'github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$') {
            return "https://github.com/$($Matches[1])/$($Matches[2]).git"
        }
    }

    return "https://github.com/$GitHubFullName.git"
}

function Resolve-GitTargetRefFromRemote {
    <#
    .SYNOPSIS
        Resolves a branch/tag/commit ref against a remote to a local git ref for checkout/merge operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$Ref
    )

    & git ls-remote --exit-code $RemoteName $Ref | Out-Null
    if ($LASTEXITCODE -eq 2) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-remote failed for '$RemoteName' with exit code $LASTEXITCODE"
    }

    $lsRemoteOutput = (& git ls-remote $RemoteName $Ref | Select-Object -First 1)
    if (-not $lsRemoteOutput) {
        throw "Could not resolve reference '$Ref' from remote '$RemoteName'."
    }

    if ($lsRemoteOutput -match '^([a-f0-9]+)\s+(.+)$') {
        $commitSha = $Matches[1]
        $fullRef = $Matches[2]

        if ($fullRef -match '^refs/heads/(.+)$') {
            return "$RemoteName/$($Matches[1])"
        }
        elseif ($fullRef -match '^refs/tags/') {
            return $commitSha
        }
        else {
            return $Ref
        }
    }

    return $Ref
}

function Get-GitHubForksOfRepositoryForOwner {
    <#
    .SYNOPSIS
        Lists repositories owned by a user that are forks of the specified upstream repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$UpstreamFullName
    )

    $ownedRepos = Invoke-GhApi -Endpoint "users/$Owner/repos?type=owner&sort=updated&per_page=100"
    if (-not $ownedRepos) {
        return @()
    }

    $matchingForks = @()

    foreach ($repo in @($ownedRepos)) {
        $isFork = $false
        if ($repo.PSObject.Properties.Name -contains 'fork') {
            $isFork = [bool]$repo.fork
        }
        if (-not $isFork) {
            continue
        }

        $repoFullName = $null
        if ($repo.PSObject.Properties.Name -contains 'full_name' -and -not [string]::IsNullOrWhiteSpace($repo.full_name)) {
            $repoFullName = [string]$repo.full_name
        }
        elseif (
            ($repo.PSObject.Properties.Name -contains 'owner') -and $repo.owner -and
            ($repo.owner.PSObject.Properties.Name -contains 'login') -and -not [string]::IsNullOrWhiteSpace($repo.owner.login) -and
            ($repo.PSObject.Properties.Name -contains 'name') -and -not [string]::IsNullOrWhiteSpace($repo.name)
        ) {
            $repoFullName = "$($repo.owner.login)/$($repo.name)"
        }

        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            continue
        }

        # Some API responses do not include 'parent'. Resolve using repo details when required.
        $parentFullName = $null
        if (
            ($repo.PSObject.Properties.Name -contains 'parent') -and $repo.parent -and
            ($repo.parent.PSObject.Properties.Name -contains 'full_name') -and -not [string]::IsNullOrWhiteSpace($repo.parent.full_name)
        ) {
            $parentFullName = [string]$repo.parent.full_name
        }
        else {
            $repoDetails = Invoke-GhApi -Endpoint "repos/$repoFullName" -AllowNotFound
            if (
                $repoDetails -and
                ($repoDetails.PSObject.Properties.Name -contains 'parent') -and $repoDetails.parent -and
                ($repoDetails.parent.PSObject.Properties.Name -contains 'full_name') -and -not [string]::IsNullOrWhiteSpace($repoDetails.parent.full_name)
            ) {
                $parentFullName = [string]$repoDetails.parent.full_name
            }
        }

        if ($parentFullName -ieq $UpstreamFullName) {
            $matchingForks += [pscustomobject]@{
                full_name = $repoFullName
            }
        }
    }

    return @($matchingForks)
}

function Ensure-GitHubForkForSharedWorkflows {
    <#
    .SYNOPSIS
        Ensures the user has a fork of the ALM4Dataverse shared workflow repository and optionally updates it from upstream.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UpstreamFullName,
        [Parameter(Mandatory)][string]$ForkOwner,
        [Parameter(Mandatory)][string]$UpstreamGitSource,
        [Parameter(Mandatory)][string]$Reference,
        [Parameter()][string]$PreferredRepositoryFullName
    )

    $existingForks = @(Get-GitHubForksOfRepositoryForOwner -Owner $ForkOwner -UpstreamFullName $UpstreamFullName)
    $ownedRepos = @(Get-GitHubOwnedReposForOwner -Owner $ForkOwner)

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName)) {
        $preferredOwnedRepo = $ownedRepos | Where-Object { $_.full_name -ieq $PreferredRepositoryFullName } | Select-Object -First 1
        if ($preferredOwnedRepo) {
            $menuItems += "Use current shared workflow repository: $($preferredOwnedRepo.full_name)"
            $menuActions += @{ Type = 'UseExisting'; FullName = $preferredOwnedRepo.full_name }

            $existingForks = @($existingForks | Where-Object { $_.full_name -ine $preferredOwnedRepo.full_name })
            $ownedRepos = @($ownedRepos | Where-Object { $_.full_name -ine $preferredOwnedRepo.full_name })
        }
    }

    foreach ($fork in $existingForks) {
        $menuItems += "Use existing fork: $($fork.full_name)"
        $menuActions += @{ Type = 'UseExisting'; FullName = $fork.full_name }
    }

    $forkFullNameMap = @{}
    foreach ($fork in $existingForks) {
        if ($fork.full_name) {
            $forkFullNameMap[$fork.full_name.ToLowerInvariant()] = $true
        }
    }

    $nonForkRepos = @($ownedRepos | Where-Object {
        $repoFullName = $_.full_name
        if ([string]::IsNullOrWhiteSpace($repoFullName)) {
            return $false
        }

        return -not $forkFullNameMap.ContainsKey($repoFullName.ToLowerInvariant())
    })

    foreach ($repo in $nonForkRepos) {
        $menuItems += "Use existing repository: $($repo.full_name)"
        $menuActions += @{ Type = 'UseExisting'; FullName = $repo.full_name }
    }

    $menuItems += 'Create a new repository'
    $menuActions += @{ Type = 'CreateNew' }

    $selection = Select-FromMenu -Title "Select shared workflow repository" -Items $menuItems
    if ($null -eq $selection) {
        throw "No shared workflow repository selected."
    }

    $selectedForkFullName = $null
    $createdNewFork = $false
    $selectedAction = $menuActions[$selection]
    if ($selectedAction.Type -eq 'UseExisting') {
        $selectedForkFullName = $selectedAction.FullName
    }

    if (-not $selectedForkFullName) {
        $upstreamParts = $UpstreamFullName.Split('/', 2)
        $defaultForkName = $upstreamParts[1]
        if (-not [string]::IsNullOrWhiteSpace($PreferredRepositoryFullName) -and $PreferredRepositoryFullName -match '^[^/]+/(.+)$') {
            $defaultForkName = $Matches[1]
        }

        while ($true) {
            $forkName = Read-Host "Fork repository name [$defaultForkName]"
            if ([string]::IsNullOrWhiteSpace($forkName)) {
                $forkName = $defaultForkName
            }

            if ($forkName -match '^[A-Za-z0-9._-]+$') {
                break
            }

            Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
        }

        $selectedForkFullName = "$ForkOwner/$forkName"
        Write-Host "Creating fork '$selectedForkFullName' from '$UpstreamFullName'..." -ForegroundColor Yellow

        $createArgs = @('repo', 'fork', $UpstreamFullName, '--clone=false', '--fork-name', $forkName)
        $createResult = & gh @createArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = $createResult -join "`n"
            if ($errText -match 'already exists') {
                Write-Host "Repository '$selectedForkFullName' already exists; continuing." -ForegroundColor Yellow
            }
            else {
                throw "Failed to create fork '$selectedForkFullName': $errText"
            }
        }
        else {
            $createdNewFork = $true
        }
    }

    $forkParts = $selectedForkFullName.Split('/', 2)
    $forkOwnerName = $forkParts[0]
    $forkRepoName = $forkParts[1]
    $forkRepo = Get-GitHubRepo -Owner $forkOwnerName -Repo $forkRepoName

    $defaultBranch = 'main'
    if ($forkRepo.defaultBranchRef -and $forkRepo.defaultBranchRef.name) {
        $defaultBranch = $forkRepo.defaultBranchRef.name
    }

    $workParent = Join-Path $env:TEMP ("ALM4Dataverse-ForkSync-" + [guid]::NewGuid().ToString('n'))
    $workRoot = Join-Path $workParent 'repo'
    New-DirectoryIfMissing -Path $workParent

    $didPushLocation = $false
    try {
        Write-Host "Checking fork '$selectedForkFullName' against upstream '$UpstreamFullName'..." -ForegroundColor DarkGray

        & gh repo clone $selectedForkFullName $workRoot 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone fork '$selectedForkFullName'."
        }

        Push-Location $workRoot
        $didPushLocation = $true

        & git checkout $defaultBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git checkout -b $defaultBranch "origin/$defaultBranch" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to check out fork default branch '$defaultBranch'."
            }
        }

        # Reset upstream remote to the configured source
        & git remote remove upstream 2>$null | Out-Null
        & git remote add upstream $UpstreamGitSource 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add upstream remote '$UpstreamGitSource'."
        }

        & git fetch upstream 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch upstream remote."
        }

        $upstreamRef = Resolve-GitTargetRefFromRemote -RemoteName 'upstream' -Ref $Reference

        $localHash = (& git rev-parse HEAD).Trim()
        $upstreamHash = (& git rev-parse $upstreamRef).Trim()
        $matchesCanonicalUpstreamDefault = $false

        $canonicalUpstreamSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $UpstreamFullName -GitHubFullName $UpstreamFullName
        if (-not [string]::IsNullOrWhiteSpace($canonicalUpstreamSource)) {
            & git remote remove upstream-github 2>$null | Out-Null
            & git remote add upstream-github $canonicalUpstreamSource 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & git fetch upstream-github $defaultBranch 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $canonicalUpstreamHash = (& git rev-parse "upstream-github/$defaultBranch").Trim()
                    $matchesCanonicalUpstreamDefault = ($localHash -eq $canonicalUpstreamHash)
                }
            }
        }

        if ($localHash -eq $upstreamHash) {
            Write-Host "Fork is already up to date for ref '$Reference'."
        }
        else {
            if ($createdNewFork -or $matchesCanonicalUpstreamDefault) {
                Write-Host "Fresh fork detected. Aligning '$selectedForkFullName' '$defaultBranch' to ref '$Reference'..." -ForegroundColor Yellow

                & git reset --hard $upstreamRef 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to align new fork '$selectedForkFullName' to ref '$Reference'."
                }

                & git push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "Git push failed." }

                Write-Host "Fork aligned successfully."
                return Get-GitHubRepo -Owner $forkOwnerName -Repo $forkRepoName
            }

            & git merge-base --is-ancestor HEAD $upstreamRef
            $canFastForward = ($LASTEXITCODE -eq 0)

            if ($canFastForward) {
                if (Read-YesNo -Prompt "Updates are available from upstream (fast-forward). Update '$selectedForkFullName'?" ) {
                    Write-Host "Fast-forwarding fork..." -ForegroundColor Yellow
                    & git merge --ff-only $upstreamRef 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "Git merge failed." }

                    & git push origin $defaultBranch 2>&1 | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "Git push failed." }

                    Write-Host "Fork updated successfully."
                }
            }
            else {
                & git merge-base --is-ancestor $upstreamRef HEAD
                $isAhead = ($LASTEXITCODE -eq 0)

                if ($isAhead) {
                    Write-Host "Fork is ahead of upstream for ref '$Reference'." -ForegroundColor Yellow
                }
                else {
                    $divergedMenuItems = @(
                        "Rebase '$selectedForkFullName' onto ref '$Reference'",
                        "Reset '$selectedForkFullName' '$defaultBranch' to ref '$Reference' (force push)",
                        "Leave '$selectedForkFullName' unchanged"
                    )
                    $divergedSelection = Select-FromMenu -Title "Fork '$selectedForkFullName' has diverged from upstream. Choose how to update it." -Items $divergedMenuItems

                    switch ($divergedSelection) {
                        0 {
                            Write-Host "Rebasing fork onto upstream ref..." -ForegroundColor Yellow
                            & git rebase $upstreamRef 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) {
                                throw "Git rebase failed - resolve conflicts manually in '$selectedForkFullName'."
                            }

                            Write-Host "Pushing rebased branch (force-with-lease)..." -ForegroundColor Yellow
                            & git push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) { throw "Git push failed." }

                            Write-Host "Fork updated successfully."
                        }
                        1 {
                            Write-Host "Resetting fork to ref '$Reference' and force pushing..." -ForegroundColor Yellow
                            & git reset --hard $upstreamRef 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) {
                                throw "Failed to reset fork '$selectedForkFullName' to ref '$Reference'."
                            }

                            & git push --force-with-lease origin $defaultBranch 2>&1 | Out-Host
                            if ($LASTEXITCODE -ne 0) { throw "Git push failed." }

                            Write-Host "Fork updated successfully."
                        }
                        default {
                            Write-Host "Leaving fork unchanged." -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
    }
    finally {
        if ($didPushLocation) {
            Pop-Location
        }
        try { Remove-Item -LiteralPath $workParent -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }

    return Get-GitHubRepo -Owner $forkOwnerName -Repo $forkRepoName
}

function New-GitHubRepositoryInteractive {
    <#
    .SYNOPSIS
        Interactively creates a new GitHub repository.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DefaultOwner
    )

    Write-Host ""
    Write-Host "Create a new GitHub repository" -ForegroundColor Green
    Write-Host ""

    $owner = Read-Host "Repository owner (user or org) [$DefaultOwner]"
    if ([string]::IsNullOrWhiteSpace($owner)) {
        $owner = $DefaultOwner
    }

    $repoName = $null
    while ($true) {
        $repoName = Read-Host "New repository name"
        if ([string]::IsNullOrWhiteSpace($repoName)) {
            Write-Warning "Repository name cannot be empty."
            continue
        }

        if ($repoName -match '^[A-Za-z0-9._-]+$') {
            break
        }

        Write-Warning "Repository name contains invalid characters. Use letters, numbers, dot (.), underscore (_), or hyphen (-)."
    }

    $visibilityItems = @('Private', 'Public')
    $visibilitySelection = Select-FromMenu -Title "Select repository visibility" -Items $visibilityItems
    if ($null -eq $visibilitySelection) {
        throw "No repository visibility selected."
    }

    $visibilityFlag = if ($visibilitySelection -eq 0) { '--private' } else { '--public' }
    $repoFullName = "$owner/$repoName"

    Write-Host "Creating repository '$repoFullName'..." -ForegroundColor Yellow
    $createArgs = @('repo', 'create', $repoFullName, $visibilityFlag, '--add-readme')
    $result = & gh @createArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create repository '$repoFullName': $($result -join "`n")"
    }

    Write-Host "Created repository '$repoFullName'." -ForegroundColor Green
    return Get-GitHubRepo -Owner $owner -Repo $repoName
}

#endregion

#region Entra ID Operations

function Ensure-EntraIdServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationId,
        [Parameter(Mandatory)][string]$TenantId
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ApplicationId'"
    $existing = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get

    if ($existing.value.Count -gt 0) {
        Write-Host "Service Principal for App '$ApplicationId' already exists."
        return $existing.value[0]
    }

    Write-Host "Creating Service Principal for App '$ApplicationId'..." -ForegroundColor Yellow
    $body = @{ appId = $ApplicationId }
    $sp = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
    Write-Host "Created Service Principal."
    return $sp
}

function Add-EntraIdFederatedCredential {
    <#
    .SYNOPSIS
        Adds a federated identity credential to an Entra ID application for Workload Identity Federation.
    
    .DESCRIPTION
        Creates a federated identity credential that allows GitHub Actions to authenticate to Azure
        without a client secret.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationObjectId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$CredentialName,
        [Parameter()][string]$Description = 'GitHub Actions WIF credential (created by setup-github.ps1)'
    )

    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
        "Content-Type" = "application/json"
    }

    Write-Host "Adding federated identity credential '$CredentialName'..." -ForegroundColor Yellow

    # Check if a credential with this name already exists
    $listUri = "https://graph.microsoft.com/beta/applications/$ApplicationObjectId/federatedIdentityCredentials"
    try {
        $existing = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Get
        $match = $existing.value | Where-Object { $_.name -eq $CredentialName } | Select-Object -First 1
        if ($match) {
            Write-Host "Federated credential '$CredentialName' already exists."
            return $match
        }
    }
    catch {
        Write-Warning "Failed to check for existing federated credentials: $($_.Exception.Message)"
    }

    # Create the federated credential
    $body = @{
        name      = $CredentialName
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $Subject
        audiences = @('api://AzureADTokenExchange')
        description = $Description
    }

    try {
        $result = Invoke-RestMethod -Uri $listUri -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created federated identity credential successfully."
        return $result
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
        [Parameter()][string]$AuthType = 'WIF'
    )
    
    # Get token for Graph
    $graphToken = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId
    $headers = @{
        Authorization  = "Bearer $($graphToken.AccessToken)"
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
            displayName    = $DisplayName
            signInAudience = "AzureADMyOrg"
        }
        $app = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/applications" -Headers $headers -Method Post -Body ($body | ConvertTo-Json)
        Write-Host "Created App Registration '$DisplayName' ($($app.appId))."
    }

    [void](Ensure-EntraIdServicePrincipal -ApplicationId $app.appId -TenantId $TenantId)

    $result = [pscustomobject]@{
        Name                = $DisplayName
        ApplicationId       = $app.appId
        ApplicationObjectId = $app.id
        ClientSecret        = $null
        TenantId            = $TenantId
        AuthType            = $AuthType
    }

    if ($AuthType -eq 'Secret') {
        # Create secret for traditional authentication
        Write-Host "Creating client secret..." -ForegroundColor Yellow
        $result.ClientSecret = New-EntraIdApplicationSecret -ApplicationObjectId $app.id -TenantId $TenantId
    }

    return $result
}

function Get-GitHubCredentialsForEnvironment {
    <#
    .SYNOPSIS
        Interactively selects or creates Entra ID credentials for a GitHub environment.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][object]$ExistingCredential
    )

    # Build Menu
    $menuItems  = @()
    $menuActions = @()

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

    $menuItems  += "Create new App Registration (Entra ID)"
    $menuActions += @{ Type = 'CreateNew' }

    $menuItems  += "Enter existing App Registration details"
    $menuActions += @{ Type = 'Manual' }

    foreach ($c in $ExistingCredentials) {
        $menuItems  += "Reuse: $($c.Name) ($($c.ApplicationId))"
        $menuActions += @{ Type = 'Cached'; Creds = $c }
    }

    Write-Host ""
    Write-SetupGuidance -Lines @(
        "App Registration credentials are used to authenticate the workflow to Dataverse.",
        "Best practice: use a separate App Registration per environment and prefer Workload Identity Federation where possible."
    ) -DocRelativePath 'docs/config/github-secrets.md' -Ref $ALM4DataverseRef
    
    $selection = Select-FromMenu -Title "Select App Registration credentials for '$EnvironmentName'" -Items $menuItems
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
            }

            return $selectedCredential
        }

        return $selectedCredential
    }
    elseif ($action.Type -eq 'Cached') {
        return $action.Creds
    }
    elseif ($action.Type -eq 'CreateNew') {
        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Workload Identity Federation (recommended, no secrets)",
            "Service Principal with Secret (traditional)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type for the new App Registration" -Items $authTypeItems
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }
        
        $appName = "$RepoName - $EnvironmentName - deployment"
        
        return New-EntraIdApplication -DisplayName $appName -TenantId $TenantId -AuthType $authType
    }
    else { # Manual
        Write-Host "Enter App Registration details:" -ForegroundColor Cyan
        $name = Read-Host "Friendly name (for reuse reference)"
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

        while ($true) {
            $appObjectId = Read-Host "Application Object ID (from Entra ID > App registrations > Overview, NOT the 'Object ID' of the enterprise app)"
            if ($appObjectId -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                break
            }
            else {
                Write-Warning "The Application Object ID must be a valid GUID. Please try again."
            }
        }

        # Prompt for authentication type
        Write-Host ""
        $authTypeItems = @(
            "Workload Identity Federation (recommended, no secrets)",
            "Service Principal with Secret (traditional)"
        )
        $authTypeSelection = Select-FromMenu -Title "Select authentication type" -Items $authTypeItems
        if ($null -eq $authTypeSelection) { throw "No authentication type selected." }
        
        $authType = if ($authTypeSelection -eq 0) { 'WIF' } else { 'Secret' }
        
        $secret = $null
        if ($authType -eq 'Secret') {
            while ($true) {
                $secretSecure = Read-Host "Client Secret" -AsSecureString
                $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure)
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
            Name                = $name
            ApplicationId       = $appId
            ApplicationObjectId = $appObjectId
            ClientSecret        = $secret
            TenantId            = $TenantId
            AuthType            = $authType
        }
    }
}

#endregion

#region Dataverse Operations

function Get-GitHubExistingEnvironmentSelectionSummary {
    [CmdletBinding()]
    param(
        [Parameter()][object]$ExistingEnvironment
    )

    if (-not $ExistingEnvironment) {
        return $null
    }

    $summaryParts = @()
    if ($ExistingEnvironment.PSObject.Properties.Name -contains 'Credentials' -and $ExistingEnvironment.Credentials) {
        $summaryParts += (Get-CredentialSummaryText -Credentials $ExistingEnvironment.Credentials)
    }
    if ($ExistingEnvironment.PSObject.Properties.Name -contains 'ServiceAccountUPN' -and -not [string]::IsNullOrWhiteSpace($ExistingEnvironment.ServiceAccountUPN)) {
        $summaryParts += "Service account: $($ExistingEnvironment.ServiceAccountUPN)"
    }

    if ($summaryParts.Count -eq 0) {
        return $null
    }

    return ($summaryParts -join ' | ')
}

function Select-DataverseEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter()][string]$ExcludeUrl,
        [Parameter()][string]$PreferredUrl,
        [Parameter()][string]$PreferredSelectionSummary,
        [Parameter()][switch]$KeepPreferredInList
    )

    Write-Host ""
    Write-Host "Retrieving Dataverse environments..." -ForegroundColor Yellow
    
    $environments = @(Get-DataverseEnvironment -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    })

    if ($environments.Count -eq 0) {
        throw "No Dataverse environments found. Ensure the account has access to at least one environment."
    }

    $normalizedExcludeUrl = ConvertTo-NormalizedEnvironmentUrl -Url $ExcludeUrl
    $normalizedPreferredUrl = ConvertTo-NormalizedEnvironmentUrl -Url $PreferredUrl

    if (-not [string]::IsNullOrWhiteSpace($ExcludeUrl)) {
        $environments = @($environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints["WebApplication"]) -ne $normalizedExcludeUrl
        })
    }

    if ($environments.Count -eq 0) {
        throw "No selectable Dataverse environments found (all were excluded)."
    }

    $menuItems = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($normalizedPreferredUrl)) {
        $preferredEnvironment = $environments | Where-Object {
            (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -eq $normalizedPreferredUrl
        } | Select-Object -First 1

        if ($preferredEnvironment) {
            $preferredMenuItem = "Use existing environment: $($preferredEnvironment.FriendlyName) ($($preferredEnvironment.Endpoints['WebApplication']))"
            if (-not [string]::IsNullOrWhiteSpace($PreferredSelectionSummary)) {
                $preferredMenuItem += " | $PreferredSelectionSummary"
            }

            $menuItems += $preferredMenuItem
            $menuActions += [pscustomobject]@{
                Environment = [pscustomobject]@{
                    FriendlyName             = $preferredEnvironment.FriendlyName
                    UniqueName               = $preferredEnvironment.UniqueName
                    Endpoints                = $preferredEnvironment.Endpoints
                    UseExistingConfiguration = $true
                }
            }

            if (-not $KeepPreferredInList) {
                $environments = @($environments | Where-Object {
                    (ConvertTo-NormalizedEnvironmentUrl -Url $_.Endpoints['WebApplication']) -ne $normalizedPreferredUrl
                })
            }
        }
    }

    foreach ($environment in $environments) {
        $menuItems += "$($environment.FriendlyName) ($($environment.Endpoints['WebApplication']))"
        $menuActions += [pscustomobject]@{ Environment = $environment }
    }
    
    $index = Select-FromMenu -Title $Prompt -Items $menuItems
    if ($null -eq $index) { return $null }

    return $menuActions[$index].Environment
}

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
            "applicationid"  = $ApplicationId
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
            roleid       = $roleId
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

    if (-not $conn) { throw "Failed to connect to Dataverse." }

    $rootBu = Get-DataverseRecord -Connection $conn -TableName "businessunit" -FilterValues @{ parentbusinessunitid = $null } -Columns "businessunitid" | Select-Object -First 1
    if (-not $rootBu) { throw "Could not find root business unit." }
    $rootBuId = $rootBu.businessunitid

    $roleName = "System Administrator"
    $role = Get-DataverseRecord -Connection $conn -TableName "role" -FilterValues @{ name = $roleName; businessunitid = $rootBuId } -Columns "roleid" | Select-Object -First 1
    if (-not $role) { throw "Could not find '$roleName' role in root business unit." }
    $roleId = $role.roleid

    $user = Get-DataverseRecord -Connection $conn -TableName "systemuser" -FilterValues @{ domainname = $ServiceAccountUPN } -Columns "systemuserid","fullname" | Select-Object -First 1
    $userId = $null

    if ($user) {
        $userId = $user.systemuserid
        Write-Host "Found service account: $($user.fullname) (ID: $userId)"
    }
    else {
        Write-Host "Service account '$ServiceAccountUPN' not found. Creating..." -ForegroundColor Yellow
        $userAttributes = @{
            "domainname"           = $ServiceAccountUPN
            "businessunitid"       = $rootBuId
            "internalemailaddress" = $ServiceAccountUPN
            "firstname"            = "Service"
            "lastname"             = "Account"
        }
        $createdUser = $userAttributes | Set-DataverseRecord -Connection $conn -TableName "systemuser" -CreateOnly -PassThru
        $userId = $createdUser.Id
        Write-Host "Service account created. ID: $userId"
    }

    $existingAssociation = Get-DataverseRecord -Connection $conn -TableName "systemuserroles" -FilterValues @{ systemuserid = $userId; roleid = $roleId } -Top 1
    if (-not $existingAssociation) {
        Write-Host "Associating service account with '$roleName' role..."
        @{
            systemuserid = $userId
            roleid       = $roleId
        } | Set-DataverseRecord -Connection $conn -TableName "systemuserroles" -CreateOnly
        Write-Host "Association successful."
    }
    else {
        Write-Host "Service account is already associated with '$roleName' role."
    }
}

function Get-DataverseServiceAccountUPN {
    [CmdletBinding()]
    param(
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$EnvironmentName,
        [Parameter()][string]$ExistingValue
    )

    $menuItems  = @()
    $menuActions = @()

    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $menuItems  += "Use existing: $ExistingValue"
        $menuActions += @{ Type = 'Existing'; UPN = $ExistingValue }
    }

    $menuItems  += "Enter a new service account UPN"
    $menuActions += @{ Type = 'Manual' }

    foreach ($sa in $ExistingServiceAccounts) {
        if ($sa -ne $ExistingValue) {
            $menuItems  += "Reuse: $sa"
            $menuActions += @{ Type = 'Cached'; UPN = $sa }
        }
    }

    Write-Host ""
    Write-SetupGuidance -Lines @(
        "Service Account credentials are used for ownership and licensing of Cloud Flows.",
        "Use a licensed user account with System Administrator role.",
        "Best practice: keep this separate from your personal admin account so automation ownership stays stable."
    ) -DocRelativePath 'docs/config/github-secrets.md' -Ref $ALM4DataverseRef
    
    $selection = Select-FromMenu -Title "Select Dataverse Service Account for '$EnvironmentName'" -Items $menuItems
    if ($null -eq $selection) { throw "No service account selected." }

    $action = $menuActions[$selection]

    if ($action.Type -in @('Cached', 'Existing')) {
        return $action.UPN
    }
    else { # Manual
        Write-Host ""
        Write-Host "IMPORTANT: The service account must be licensed with an appropriate D365/PowerApps/etc licence." -ForegroundColor Yellow
        Write-Host ""
        
        while ($true) {
            $upn = Read-Host "Service Account UPN (e.g., serviceaccount@contoso.com)"
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-Warning "Service Account UPN cannot be empty."
                continue
            }
            if ($upn -match '^[^@]+@[^@]+\.[^@]+$') {
                return $upn
            }
            else {
                Write-Warning "The UPN does not appear to be in a valid format."
            }
        }
    }
}

function Get-DataverseSolutionsSelection {
    [CmdletBinding()]
    param(
        [Parameter()][string]$ExistingConfigPath,
        [Parameter()][string]$ExistingEnvironmentUrl,
        [Parameter()][object]$ExistingEnvironmentConfiguration
    )
    
    Write-Host ""
    Write-SetupGuidance -Lines @(
        "Select the Dataverse DEV environment that contains the unmanaged solutions you want ALM4Dataverse to export and build from source control.",
        "The selected environment becomes the source of truth for solution discovery during setup, so choose the DEV environment that your team actively customises in.",
        "Best practice: add solutions in dependency order because that is the order written into alm-config.psd1 and later reused by the automation."
    ) -DocRelativePath 'docs/config/alm-config.md' -Ref $ALM4DataverseRef

    $existingEnvironmentSummary = Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $ExistingEnvironmentConfiguration
    $selectedEnv = Select-DataverseEnvironment -Prompt "Select your DEV environment" -PreferredUrl $ExistingEnvironmentUrl -PreferredSelectionSummary $existingEnvironmentSummary -KeepPreferredInList
    if (-not $selectedEnv) { throw "No environment selected." }

    $reuseExistingConfiguration = ($selectedEnv.PSObject.Properties.Name -contains 'UseExistingConfiguration' -and $selectedEnv.UseExistingConfiguration)

    $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints["WebApplication"]
    Write-Host "Selected: $($selectedEnv.FriendlyName) ($devEnvUrl)" -ForegroundColor Cyan

    $connection = Get-DataverseConnection -Url $devEnvUrl -AccessToken { 
        param($resource)
        if (-not $resource) { $resource = 'https://globaldisco.crm.dynamics.com/' }
        try {
            $uri = [System.Uri]$resource
            $resource = $uri.GetLeftPart([System.UriPartial]::Authority)
        } catch {}
        $auth = Get-AuthToken -ResourceUrl $resource -TenantId $TenantId
        return $auth.AccessToken
    }
    
    if (-not $connection) { throw "Failed to connect to Dataverse environment." }
    
    Write-Host "Connected to: $($connection.ConnectedOrgFriendlyName)"
    Write-Host "Retrieving solutions..." -ForegroundColor Yellow
    
    $allSolutions = Get-DataverseRecord -Connection $connection -TableName 'solution' -Columns @('solutionid','uniquename','friendlyname','version','ismanaged') -FilterValues @{
        'isvisible' = $true
        'ismanaged' = $false
    }
    
    if (-not $allSolutions -or $allSolutions.Count -eq 0) {
        Write-Host "No unmanaged solutions found in the environment." -ForegroundColor Yellow
        return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl; ReuseExistingConfiguration = $reuseExistingConfiguration }
    }
    
    $userSolutions = @($allSolutions | Where-Object { 
        $_.uniquename -notmatch '^(Default|Active|Basic|msdyn_|ms|MicrosoftFlow|PowerPlatform)' -and 
        $_.uniquename -ne 'System' 
    } | Sort-Object friendlyname)
    
    if ($userSolutions.Count -eq 0) {
        Write-Host "No user-created solutions found." -ForegroundColor Yellow
        return @{ Solutions = @(); EnvironmentUrl = $devEnvUrl; ReuseExistingConfiguration = $reuseExistingConfiguration }
    }

    # Pre-populate from existing alm-config.psd1 if available
    $selectedSolutions = @()
    if ($ExistingConfigPath -and (Test-Path -LiteralPath $ExistingConfigPath)) {
        try {
            $existingConfig = Import-PowerShellDataFile -Path $ExistingConfigPath
            if ($existingConfig.solutions) {
                foreach ($existing in $existingConfig.solutions) {
                    $match = $userSolutions | Where-Object { $_.uniquename -eq $existing.name } | Select-Object -First 1
                    if ($match) { $selectedSolutions += $match }
                }
                if ($selectedSolutions.Count -gt 0) {
                    Write-Host "Pre-selected $($selectedSolutions.Count) solution(s) from existing configuration." -ForegroundColor Green
                    Start-Sleep -Seconds 2
                }
            }
        }
        catch { <# ignore #> }
    }

    $selectedSolutions = @(Select-OrderedSolutions -AvailableSolutions $userSolutions -InitiallySelectedSolutions $selectedSolutions)
    
    # Convert to alm-config.psd1 format
    $configSolutions = @()
    foreach ($sol in $selectedSolutions) {
        $configSolutions += @{ name = $sol.uniquename; deployUnmanaged = $false }
    }
    
    return @{ Solutions = $configSolutions; EnvironmentUrl = $devEnvUrl; EnvironmentFriendlyName = $selectedEnv.FriendlyName; ReuseExistingConfiguration = $reuseExistingConfiguration }
}

function Get-GitHubEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter()][string]$FriendlyName,
        [Parameter()][array]$ExistingCredentials,
        [Parameter()][array]$ExistingServiceAccounts,
        [Parameter()][string]$TenantId,
        [Parameter()][string]$RepoName,
        [Parameter()][object]$ExistingCredential,
        [Parameter()][string]$ExistingServiceAccountUPN
    )

    $creds = Get-GitHubCredentialsForEnvironment `
        -ExistingCredentials $ExistingCredentials `
        -TenantId $TenantId `
        -RepoName $RepoName `
        -EnvironmentName $EnvironmentName `
        -ExistingCredential $ExistingCredential

    $serviceAccountUPN = Get-DataverseServiceAccountUPN `
        -ExistingServiceAccounts $ExistingServiceAccounts `
        -EnvironmentName $EnvironmentName `
        -ExistingValue $ExistingServiceAccountUPN

    return [pscustomobject]@{
        ShortName        = $EnvironmentName
        FriendlyName     = $(if ([string]::IsNullOrWhiteSpace($FriendlyName)) { $EnvironmentName } else { $FriendlyName })
        Url              = (ConvertTo-NormalizedEnvironmentUrl -Url $EnvironmentUrl)
        Credentials      = $creds
        ServiceAccountUPN = $serviceAccountUPN
    }
}

function Apply-GitHubEnvironmentConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$EnvironmentConfiguration,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$RepoOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$RepoFullName,
        [Parameter()][bool]$UseGitHubEnvironments = $true,
        [Parameter()][bool]$EnableApprovals = $false,
        [Parameter()][array]$RequiredReviewerIds = @()
    )

    $creds = $EnvironmentConfiguration.Credentials
    $serviceAccountUPN = $EnvironmentConfiguration.ServiceAccountUPN

    if ($creds.AuthType -eq 'WIF' -and $creds.ApplicationObjectId) {
        $credName = ConvertTo-UrlSafeName -Name "gha-$RepoName-env-$($EnvironmentConfiguration.ShortName)"
        [void](Add-EntraIdFederatedCredential `
            -ApplicationObjectId $creds.ApplicationObjectId `
            -TenantId $TenantId `
            -Subject "repo:${RepoFullName}:environment:$($EnvironmentConfiguration.ShortName)" `
            -CredentialName $credName)
    }

    if ($UseGitHubEnvironments) {
        [void](Ensure-GitHubEnvironment `
            -Owner $RepoOwner `
            -Repo $RepoName `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -EnableApprovals:$EnableApprovals `
            -RequiredReviewerIds $RequiredReviewerIds)

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'AZURE_CLIENT_ID' -VariableValue $creds.ApplicationId
        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'AZURE_TENANT_ID' -VariableValue $creds.TenantId

        if ($creds.AuthType -eq 'Secret' -and $creds.ClientSecret) {
            Set-GitHubEnvironmentSecret -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
                -SecretName 'AZURE_CLIENT_SECRET' -SecretValue $creds.ClientSecret
        }

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'DATAVERSE_URL' -VariableValue $EnvironmentConfiguration.Url

        Set-GitHubEnvironmentVariable -Owner $RepoOwner -Repo $RepoName -EnvironmentName $EnvironmentConfiguration.ShortName `
            -VariableName 'DATAVERSESERVICEACCOUNTUPN' -VariableValue $serviceAccountUPN
    }
    else {
        Set-GitHubPrefixedEnvironmentCredentials `
            -Owner $RepoOwner `
            -Repo $RepoName `
            -EnvironmentName $EnvironmentConfiguration.ShortName `
            -Credentials $creds `
            -DataverseUrl $EnvironmentConfiguration.Url `
            -ServiceAccountUPN $serviceAccountUPN
    }

    Ensure-DataverseApplicationUser -EnvironmentUrl $EnvironmentConfiguration.Url -ApplicationId $creds.ApplicationId -TenantId $TenantId
    Ensure-DataverseServiceAccountUser -EnvironmentUrl $EnvironmentConfiguration.Url -ServiceAccountUPN $serviceAccountUPN -TenantId $TenantId
}

#endregion

#region Repository Setup

function Copy-WorkflowTemplatesToRepo {
    <#
    .SYNOPSIS
        Copies ALM4Dataverse workflow templates into the user's GitHub repository clone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        throw "Source folder not found: $SourceRoot"
    }

    Write-Section "Syncing workflow files into repository"
    Write-Host "Source: $SourceRoot" -ForegroundColor DarkGray
    Write-Host "Target: $TargetRoot" -ForegroundColor DarkGray

    $allSourceFiles = Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force | Where-Object { -not $_.PSIsContainer }

    foreach ($file in $allSourceFiles) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $normalizedRelativePath = $relativePath -replace '\\','/'
        $destPath     = Join-Path $TargetRoot $relativePath

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
        $isTempFile      = $false

        # Patch all shared workflow references (build/export/import/deploy/etc.) to the selected repository/ref.
        if ($normalizedRelativePath -like '.github/workflows/*.yml') {
            $content = Get-Content -LiteralPath $sourceFileToUse -Raw
            $updatedContent = [Regex]::Replace(
                $content,
                'ALM4Dataverse/ALM4Dataverse/\.github/workflows/([A-Za-z0-9._-]+)@[A-Za-z0-9._/\-]+',
                {
                    param($m)
                    return "$SharedWorkflowRepository/.github/workflows/$($m.Groups[1].Value)@$SharedWorkflowRef"
                }
            )

            if ($updatedContent -ne $content) {
                if ($isTempFile) {
                    Set-Content -LiteralPath $sourceFileToUse -Value $updatedContent -NoNewline
                }
                else {
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    Set-Content -LiteralPath $tempFile -Value $updatedContent -NoNewline
                    $sourceFileToUse = $tempFile
                    $isTempFile      = $true
                }
            }
        }

        # Rename DEPLOY-main.yml to match the branch, and patch branch references
        if ($normalizedRelativePath -eq '.github/workflows/DEPLOY-main.yml') {
            $destPath = Join-Path $TargetRoot ".github/workflows/DEPLOY-$Branch.yml"
            
            $content = Get-Content -LiteralPath $sourceFileToUse -Raw
            $content = $content -replace "branches:\s*\[\s*main\s*\]", "branches: [ $Branch ]"
            $content = $content -replace 'workflow_name: ''BUILD''', "workflow_name: 'BUILD'"
            $content = $content -replace '\bTEST-main\b', 'TEST'

            if ($isTempFile) {
                Set-Content -LiteralPath $sourceFileToUse -Value $content -NoNewline
            }
            else {
                $tempFile = [System.IO.Path]::GetTempFileName()
                Set-Content -LiteralPath $tempFile -Value $content -NoNewline
                $sourceFileToUse = $tempFile
                $isTempFile      = $true
            }
        }

        try {
            if (Test-Path -LiteralPath $destPath) {
                $srcHash = Get-FileHash -LiteralPath $sourceFileToUse -Algorithm MD5
                $dstHash = Get-FileHash -LiteralPath $destPath        -Algorithm MD5

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

    Write-Host "Workflow files synced." -ForegroundColor Green
}

function Update-AlmConfigInRepoClone {
    <#
    .SYNOPSIS
        Updates the alm-config.psd1 file in a local clone with the selected solutions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Solutions,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $configPath = Join-Path $RepoRoot 'alm-config.psd1'
    $templatePath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'copy-to-your-repo\alm-config.psd1' } else { $null }
    [void](Set-AlmConfigSolutionsInFile -ConfigPath $configPath -Solutions $Solutions -CreateIfMissing -TemplatePath $templatePath)
    Write-Host "Updated alm-config.psd1 with $($Solutions.Count) solution(s)."
}

function Update-DeployWorkflowInRepoClone {
    <#
    .SYNOPSIS
        Rebuilds DEPLOY-{branch}.yml using selected deployment environments.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][array]$DeploymentEnvironments,
        [Parameter(Mandatory)][string]$SharedWorkflowRepository,
        [Parameter(Mandatory)][string]$SharedWorkflowRef,
        [Parameter()][ValidateSet('manual-gate-tag','environment-approval')][string]$PromotionMode = 'manual-gate-tag'
    )

    if (-not $DeploymentEnvironments -or $DeploymentEnvironments.Count -eq 0) {
        Write-Host "No deployment environments selected; keeping default DEPLOY workflow template." -ForegroundColor Yellow
        return
    }

    $deployFilePath = Join-Path $RepoRoot ".github/workflows/DEPLOY-$Branch.yml"
    if (-not (Test-Path -LiteralPath $deployFilePath)) {
        throw "Deploy workflow file not found: $deployFilePath"
    }

    $usesRef = "$SharedWorkflowRepository/.github/workflows/deploy.yml@$SharedWorkflowRef"

    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("name: DEPLOY-$Branch")
    if ($PromotionMode -eq 'environment-approval') {
        $lines.Add('run-name: ${{ github.event_name == ''workflow_dispatch'' && format(''Deploy {0} <- {1}'', github.event.inputs[''target-environment''] || ''auto'', github.event.inputs[''build-run-name''] || github.event.inputs[''build-run-id'']) || format(''Deploy auto <- {0}'', github.event.workflow_run.display_title || github.event.workflow_run.id) }}')
    }
    else {
        $lines.Add('run-name: ${{ github.event_name == ''workflow_dispatch'' && format(''Deploy {0} <- {1}'', github.event.inputs[''target-environment''], github.event.inputs[''build-run-name''] || github.event.inputs[''build-run-id'']) || format(''Deploy auto <- {0}'', github.event.workflow_run.display_title || github.event.workflow_run.id) }}')
    }
    $lines.Add("")
    $lines.Add('# Stage-per-environment deployment workflow (generated by setup-github.ps1).')
    $lines.Add('#')
    $lines.Add('# To add another environment later:')
    $lines.Add('#   1. Add it to workflow_dispatch target-environment options.')
    $lines.Add('#   2. Add a deploy-* job and chain needs to the previous stage.')
    $lines.Add('#   3. Set previous-environment-name to the previous stage short name.')
    $lines.Add('#   4. In environment-approval mode, keep the workflow_run trigger enabled.')
    $lines.Add('')
    $lines.Add('permissions:')
    $lines.Add('  actions: read')
    $lines.Add('  contents: write')
    $lines.Add('  id-token: write')
    $lines.Add('')
    $lines.Add('on:')
    if ($PromotionMode -eq 'environment-approval') {
        $lines.Add('  workflow_run:')
        $lines.Add("    workflows: ['BUILD']")
        $lines.Add('    types: [completed]')
        $lines.Add("    branches: [ '$Branch' ]")
    }
    $lines.Add('  workflow_dispatch:')
    $lines.Add('    inputs:')
    $lines.Add('      build-run-name:')
    $lines.Add("        description: 'Exact BUILD name to deploy (for example repo-main-2025-05-27T14:23:11Z-4). Numeric run IDs also work.'")
    $lines.Add('        required: true')
    $lines.Add('        type: string')
    $lines.Add('      target-environment:')
    if ($PromotionMode -eq 'environment-approval') {
        $validEnvironmentList = ($DeploymentEnvironments | ForEach-Object { $_.ShortName }) -join ', '
        $validEnvironmentListEscaped = $validEnvironmentList.Replace("'", "''")
        $lines.Add("        description: 'Optional target environment. Leave blank to start from the first configured stage. Valid values: $validEnvironmentListEscaped.'")
        $lines.Add('        required: false')
        $lines.Add('        type: string')
    }
    else {
        $lines.Add("        description: 'Target environment to deploy to'")
        $lines.Add('        required: true')
        $lines.Add('        type: choice')
        $lines.Add('        options:')

        foreach ($env in $DeploymentEnvironments) {
            $envNameEscaped = ([string]$env.ShortName).Replace("'", "''")
            $lines.Add("          - '$envNameEscaped'")
        }
    }

    $lines.Add('')
    $lines.Add('jobs:')

    $previousJobId = $null
    $previousEnvName = ''
    $jobIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $DeploymentEnvironments.Count; $i++) {
        $envName = [string]$DeploymentEnvironments[$i].ShortName
        $envNameEscaped = $envName.Replace("'", "''")

        $baseJobId = ('deploy-' + (($envName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')))
        if ([string]::IsNullOrWhiteSpace($baseJobId) -or $baseJobId -eq 'deploy-') {
            $baseJobId = "deploy-stage-$($i + 1)"
        }

        $jobId = $baseJobId
        $suffix = 2
        while ($jobIdSet.Contains($jobId)) {
            $jobId = "$baseJobId-$suffix"
            $suffix++
        }
        [void]$jobIdSet.Add($jobId)

        $lines.Add("  ${jobId}:")
        if ($i -eq 0) {
            $lines.Add('    # First stage in the chain.')
            if ($PromotionMode -eq 'manual-gate-tag') {
                $lines.Add('    # Manual-gate-tag mode requires an explicit workflow_dispatch, even for stage 1.')
            }
        }
        else {
            $lines.Add("    needs: $previousJobId")
            $lines.Add('    # Allow manual targeted deploys even when earlier jobs are skipped in this run,')
            $lines.Add('    # but do not bypass failed prerequisite stages on automatic runs.')
            if ($PromotionMode -eq 'environment-approval') {
                $lines.Add('    if: >-')
                $lines.Add('      (')
                $lines.Add("        github.event_name == 'workflow_dispatch' &&")
                $lines.Add(("        inputs.target-environment == '{0}'" -f $envNameEscaped))
                $lines.Add('      ) || (')
                $lines.Add(("        (github.event_name != 'workflow_dispatch' || inputs.target-environment == '') && needs['{0}'].result == 'success'" -f $previousJobId))
                $lines.Add('      )')
            }
            else {
                $lines.Add(('    if: ${{{{ github.event_name == ''workflow_dispatch'' || needs[''{0}''].result == ''success'' }}}}' -f $previousJobId))
            }
        }

        $lines.Add("    uses: $usesRef")
        $lines.Add('    permissions:')
        $lines.Add('      actions: read')
        $lines.Add('      contents: write')
        $lines.Add('      id-token: write')
        $lines.Add('    with:')
        $lines.Add("      environment-name: '$envNameEscaped'")
        if ($i -eq 0) {
            $lines.Add("      previous-environment-name: ''")
        }
        else {
            $prevEscaped = $previousEnvName.Replace("'", "''")
            $lines.Add("      previous-environment-name: '$prevEscaped'")
        }
        $lines.Add("      promotion-mode: $PromotionMode")
        $lines.Add('      github-context-json: ${{ toJSON(github) }}')
        $lines.Add('      caller-inputs-json: ${{ toJSON(inputs) }}')
        $lines.Add('      timeout-minutes: 360')
        $lines.Add('    secrets: inherit')
        $lines.Add('')

        $previousJobId = $jobId
        $previousEnvName = $envName
    }

    $output = ($lines -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
    Set-Content -LiteralPath $deployFilePath -Value $output -NoNewline

    $envList = ($DeploymentEnvironments | ForEach-Object { $_.ShortName }) -join ', '
    Write-Host "Updated DEPLOY workflow '$deployFilePath' with environments: $envList (promotion mode: $PromotionMode)" -ForegroundColor Green
}

function Publish-GitHubRepoChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][object]$PublishPlan
    )

    Push-Location $RepoRoot
    try {
        & git add -A
        if ($LASTEXITCODE -ne 0) { throw 'Git add failed.' }

        & git diff --cached --quiet
        $hasChanges = ($LASTEXITCODE -ne 0)

        if (-not $hasChanges) {
            Write-Host 'No changes to commit; repository already contains the required files.' -ForegroundColor Green
            return [pscustomobject]@{
                HasChanges     = $false
                BranchName     = $PublishPlan.BranchName
                TargetBranch   = $PublishPlan.TargetBranch
                PullRequestUrl = $null
                Mode           = $PublishPlan.Mode
            }
        }

        & git config user.name 'ALM4Dataverse Setup'
        & git config user.email 'setup@alm4dataverse.local'
        & git commit -m $PublishPlan.CommitMessage 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Git commit failed.' }

        Write-Host "Pushing to origin/$($PublishPlan.BranchName)..." -ForegroundColor Yellow
        & git push -u origin $PublishPlan.BranchName 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Git push failed.' }

        $pullRequestUrl = $null
        if ($PublishPlan.Mode -eq 'PullRequest') {
            $existingPrOutput = (& gh pr list --head $PublishPlan.BranchName --base $PublishPlan.TargetBranch --state open --json number,url 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to query existing pull requests.'
            }

            $existingPullRequests = @()
            if (-not [string]::IsNullOrWhiteSpace($existingPrOutput)) {
                $existingPullRequests = @($existingPrOutput | ConvertFrom-Json)
            }

            $existingPullRequest = $existingPullRequests | Select-Object -First 1
            if ($existingPullRequest) {
                Write-Host "Updating existing pull request #$($existingPullRequest.number)..." -ForegroundColor Yellow
                & gh pr edit $existingPullRequest.number --title $PublishPlan.PullRequestTitle --body $PublishPlan.PullRequestDescription 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to update the pull request.'
                }
                $pullRequestUrl = $existingPullRequest.url
            }
            else {
                Write-Host "Creating pull request into '$($PublishPlan.TargetBranch)'..." -ForegroundColor Yellow
                $pullRequestUrl = (& gh pr create --title $PublishPlan.PullRequestTitle --body $PublishPlan.PullRequestDescription --base $PublishPlan.TargetBranch --head $PublishPlan.BranchName 2>&1 | Out-String).Trim()
                if ($LASTEXITCODE -ne 0) {
                    throw 'Failed to create the pull request.'
                }
            }
        }

        Write-Host 'Repository updated successfully.' -ForegroundColor Green
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

#endregion

# ─────────────────────────────────────────────────────────────
#  MAIN SETUP FLOW
# ─────────────────────────────────────────────────────────────

Write-Section "Authenticating with GitHub"

Write-Host "Checking GitHub CLI authentication status..." -ForegroundColor Yellow
$ghStatus = & gh auth status --hostname github.com 2>&1
$hasExistingGitHubLogin = ($LASTEXITCODE -eq 0)

if ($hasExistingGitHubLogin) {
    $existingGhUser = (& gh api user --jq '.login' 2>&1 | Out-String).Trim()

    $ghMenuItems = @()
    if (-not [string]::IsNullOrWhiteSpace($existingGhUser)) {
        $ghMenuItems += "Use existing GitHub login: $existingGhUser"
    }
    else {
        $ghMenuItems += "Use existing GitHub login"
    }
    $ghMenuItems += "Sign in with a different GitHub account"

    $ghChoice = Select-FromMenu -Title "GitHub authentication" -Items $ghMenuItems
    if ($null -eq $ghChoice) {
        throw "No GitHub authentication option selected."
    }

    if ($ghChoice -eq 0) {
        Write-Host "Using existing GitHub login." -ForegroundColor Green
        Write-Host ($ghStatus -join "`n") -ForegroundColor DarkGray
    }
    else {
        Write-Host "Signing in with a different GitHub account..." -ForegroundColor Yellow
        & gh auth logout --hostname github.com 2>&1 | Out-Host
        & gh auth login --web --hostname github.com
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub authentication failed."
        }
    }
}
else {
    Write-Host "Not logged in to GitHub. Opening browser for authentication..." -ForegroundColor Yellow
    & gh auth login --web --hostname github.com
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub authentication failed."
    }
}

# Get the authenticated username
$script:ghUser = (& gh api user --jq '.login' 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Failed to determine GitHub username."
}

$script:ghUserId = $null
$ghUserIdRaw = (& gh api user --jq '.id' 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -eq 0 -and $ghUserIdRaw -match '^\d+$') {
    $script:ghUserId = [int]$ghUserIdRaw
}

Write-Host "Logged in as: $script:ghUser" -ForegroundColor Green
if ($script:ghUserId) {
    Write-Host "GitHub user id: $script:ghUserId" -ForegroundColor DarkGray
}

Write-Section "Authenticating with Azure"

Write-Host "To enable automated setup, we need to authenticate with Azure." -ForegroundColor Green
Write-Host ""
Write-Host "When prompted, please log in with an account that has access to:" -ForegroundColor Green
Write-Host "- Your Entra ID tenant (to manage App Registrations)" -ForegroundColor Green
Write-Host "- Your Dataverse DEV environment (SYSTEM ADMINISTRATOR role)" -ForegroundColor Green
Write-Host ""

$cachedAzureAccounts = @(Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId -ListAccountsOnly)
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
        Read-Host "Press Enter to open browser for Azure authentication..."
    }
}
else {
    Write-Host "No cached Azure login detected. Browser sign-in is required." -ForegroundColor Yellow
    Read-Host "Press Enter to open browser for Azure authentication..."
}

$script:azureAuthResult = Invoke-WithErrorHandling -OperationName "Azure Authentication" -ScriptBlock {
    # Request a Graph token to confirm authentication works
    $result = Get-AuthToken -ResourceUrl "https://graph.microsoft.com" -TenantId $TenantId -PreferredUsername $preferredAzureUsername -ForceInteractive:$forceAzureInteractive
    if (-not $result -or -not $result.AccessToken) {
        throw "Failed to acquire an Azure access token."
    }
    return $result
}

Write-Host "Authenticated as: $($script:azureAuthResult.Account.Username)" -ForegroundColor Green

# Resolve tenant ID from the token if not supplied
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    $TenantId = $script:azureAuthResult.TenantId
    Write-Host "Using tenant: $TenantId"
}

Assert-ValidTenantIdentifier -TenantIdentifier $TenantId -Source 'Resolved Azure tenant ID'

# ─────────────────────────────────────────────────────────────
Write-Section "Ensuring Shared Workflow Repository"

$upstreamWorkflowRepoFullName = Resolve-GitHubRepoFullNameFromSource -Source $upstreamRepo -Fallback 'ALM4Dataverse/ALM4Dataverse'
$upstreamGitSource = Resolve-UpstreamGitRemoteSource -ConfiguredSource $upstreamRepo -GitHubFullName $upstreamWorkflowRepoFullName

Write-Host "Upstream workflow source: $upstreamWorkflowRepoFullName" -ForegroundColor DarkGray
Write-Host "Using ALM4Dataverse ref: $ALM4DataverseRef" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────
Write-Section "Select GitHub Repository"

Write-Host "Fetching repositories you have write access to..." -ForegroundColor Yellow

$repos = @(Get-GitHubRepoList)
$selectedRepo = $null

$repos = @($repos | Sort-Object -Property nameWithOwner)
$repoMenuItems = @()
$repoMenuActions = @()

foreach ($repo in $repos) {
    $repoMenuItems += "Use existing repository: $($repo.nameWithOwner)"
    $repoMenuActions += @{ Type = 'UseExisting'; Repo = $repo }
}

$repoMenuItems += 'Create a new repository'
$repoMenuActions += @{ Type = 'CreateNew' }

$repoSelection = Select-FromMenu -Title "Select the repository to set up ALM4Dataverse in" -Items $repoMenuItems
if ($null -eq $repoSelection) {
    throw "No repository selected."
}

$repoAction = $repoMenuActions[$repoSelection]
if ($repoAction.Type -eq 'UseExisting') {
    $selectedRepo = $repoAction.Repo
}
else {
    $selectedRepo = Invoke-WithErrorHandling -OperationName "Creating GitHub repository" -ScriptBlock {
        New-GitHubRepositoryInteractive -DefaultOwner $script:ghUser
    }
}

$repoOwner    = $selectedRepo.owner.login
$repoName     = $selectedRepo.name
$repoFullName = $selectedRepo.nameWithOwner

Write-Host "Selected: $repoFullName" -ForegroundColor Cyan

# Determine default branch
$defaultBranch = 'main'
if ($selectedRepo.defaultBranchRef -and $selectedRepo.defaultBranchRef.name) {
    $defaultBranch = $selectedRepo.defaultBranchRef.name
}
Write-Host "Default branch: $defaultBranch"

$cloneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-GH-" + [guid]::NewGuid().ToString('n'))
New-DirectoryIfMissing -Path $cloneRoot

Write-Section "Cloning Repository"

Invoke-WithErrorHandling -OperationName "Cloning repository" -ScriptBlock {
    Write-Host "Cloning $repoFullName to $cloneRoot..." -ForegroundColor Yellow
    & gh repo clone $repoFullName $cloneRoot -- --depth 1 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "gh repo clone failed." }
}

Push-Location $cloneRoot
try {
    & git checkout $defaultBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & git checkout -b $defaultBranch 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to check out repository base branch '$defaultBranch'."
        }
    }
}
finally {
    Pop-Location
}

$existingSetupState = Get-GitHubRepositoryExistingSetupState `
    -RepoRoot $cloneRoot `
    -RepoOwner $repoOwner `
    -RepoName $repoName `
    -DefaultBranch $defaultBranch `
    -TenantId $TenantId

if ($existingSetupState.SharedWorkflowRepository) {
    Write-Host "Existing shared workflow repository detected: $($existingSetupState.SharedWorkflowRepository)" -ForegroundColor DarkGray
}
if ($existingSetupState.SharedWorkflowReference) {
    Write-Host "Existing shared workflow ref detected: $($existingSetupState.SharedWorkflowReference)" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────
Write-Section "Ensuring Shared Workflow Repository"

$sharedWorkflowRepo = Invoke-WithErrorHandling -OperationName "Ensuring shared workflow repository fork" -ScriptBlock {
    Ensure-GitHubForkForSharedWorkflows `
        -UpstreamFullName $upstreamWorkflowRepoFullName `
        -ForkOwner $script:ghUser `
        -UpstreamGitSource $upstreamGitSource `
        -Reference $ALM4DataverseRef `
        -PreferredRepositoryFullName $existingSetupState.SharedWorkflowRepository
}

$sharedWorkflowRepository = $sharedWorkflowRepo.nameWithOwner
$sharedWorkflowReference = 'main'
if ($sharedWorkflowRepo.defaultBranchRef -and $sharedWorkflowRepo.defaultBranchRef.name) {
    $sharedWorkflowReference = $sharedWorkflowRepo.defaultBranchRef.name
}

Write-Host "Shared workflow repository: $sharedWorkflowRepository" -ForegroundColor Green
Write-Host "Shared workflow reference (synced branch): $sharedWorkflowReference" -ForegroundColor Green

$useGitHubEnvironments = $false
$enableEnvironmentApprovals = $false
$environmentApprovalReviewerIds = @()
$deploymentPromotionMode = 'manual-gate-tag'

Write-Host "Checking GitHub environment and required-reviewer availability for '$repoFullName'..." -ForegroundColor Yellow
$environmentCapabilities = Get-GitHubEnvironmentCapabilities -Owner $repoOwner -Repo $repoName -ApprovalReviewerId $script:ghUserId

if ($existingSetupState.CredentialStorageScope -eq 'Environment' -and $environmentCapabilities.EnvironmentsAvailable) {
    $useGitHubEnvironments = $true
    if ($environmentCapabilities.ApprovalsAvailable) {
        $enableEnvironmentApprovals = $true
        $deploymentPromotionMode = 'environment-approval'
        if ($script:ghUserId) {
            $environmentApprovalReviewerIds = @($script:ghUserId)
        }
    }

    Write-Host 'Existing repository configuration already uses GitHub environments, so setup will preserve that as the baseline.' -ForegroundColor Green
}
elseif ($existingSetupState.CredentialStorageScope -eq 'RepositoryPrefix') {
    $useGitHubEnvironments = $false
    $enableEnvironmentApprovals = $false
    $deploymentPromotionMode = 'manual-gate-tag'
    Write-Host 'Existing repository configuration uses prefixed repo-level credentials, so setup will preserve that as the baseline.' -ForegroundColor Green
}
elseif ($environmentCapabilities.EnvironmentsAvailable) {
    $useGitHubEnvironments = $true
    if ($environmentCapabilities.ApprovalsAvailable) {
        $enableEnvironmentApprovals = $true
        $deploymentPromotionMode = 'environment-approval'
        if ($script:ghUserId) {
            $environmentApprovalReviewerIds = @($script:ghUserId)
        }

        Write-Host "GitHub environments and required reviewers are available. Setup will configure environment credentials and approval gates." -ForegroundColor Green
    }
    else {
        Write-Host "GitHub environments are available, but required reviewers are unavailable. Setup will use environment-scoped credentials and tag-based promotion." -ForegroundColor Yellow
    }
}
else {
    Write-Host "GitHub environments are unavailable for this repository. Setup will use prefixed repo-level credentials and tag-based promotion." -ForegroundColor Yellow
}

if (-not [string]::IsNullOrWhiteSpace($environmentCapabilities.Message)) {
    Write-Host $environmentCapabilities.Message -ForegroundColor DarkGray
}

Write-Host "DEPLOY workflow promotion mode: $deploymentPromotionMode" -ForegroundColor DarkGray

$deploymentModeGuidance = @()
if ($useGitHubEnvironments) {
    $deploymentModeGuidance += "Setup will store credentials in GitHub environments for each selected Dataverse environment."
    if ($enableEnvironmentApprovals) {
        $deploymentModeGuidance += "Required reviewers are available, so DEPLOY stages can auto-chain using environment approvals."
    }
    else {
        $deploymentModeGuidance += "Required reviewers are unavailable, so DEPLOY will use manual-gate-tag promotion even though environment-scoped credentials are available."
    }
}
else {
    $deploymentModeGuidance += "Setup will fall back to prefixed repository-level credentials because GitHub environments are unavailable for this repository."
    $deploymentModeGuidance += "That keeps the workflows usable on lower GitHub plans, but promotion remains manual with gate tags."
}
Write-SetupGuidance -Lines $deploymentModeGuidance -DocRelativePath 'docs/setup/github-setup.md' -Ref $ALM4DataverseRef

$script:cachedCredentials = @()
$script:cachedServiceAccounts = @()

$repoPublishPlan = Get-RepoChangePublishPlan `
    -ProviderName 'GitHub' `
    -RepositoryName $repoFullName `
    -BaseBranch $defaultBranch `
    -DefaultCommitMessage 'Add ALM4Dataverse GitHub Actions workflows' `
    -DefaultPullRequestTitle 'Add ALM4Dataverse GitHub Actions workflows' `
    -DefaultPullRequestDescription "This pull request adds or updates the ALM4Dataverse GitHub Actions workflows and repository configuration generated by setup-github.ps1." `
    -GuidanceLines @(
        'If branch protection or required reviews apply, choose the pull-request path so the generated workflow and config changes can be reviewed before they become active.',
        'If you commit directly, the selected branch is updated immediately and the workflows on that branch can be used as soon as the push completes.'
    ) `
    -DocRelativePath 'docs/setup/github-setup.md' `
    -Ref $ALM4DataverseRef

$deploymentEnvironments = @()
$repoPublishResult = $null

# ─────────────────────────────────────────────────────────────
Push-Location $cloneRoot
try {
    # Ensure we are on the right branch
    & git checkout $defaultBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & git checkout -b $defaultBranch 2>&1 | Out-Null
    }

    if ($repoPublishPlan.BranchName -ne $defaultBranch) {
        & git checkout -B $repoPublishPlan.BranchName 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create or switch to working branch '$($repoPublishPlan.BranchName)'."
        }
    }

    # ─────────────────────────────────────────────────────────
    Write-Section "Copy Workflow Templates"

    $copyRoot = $null
    if ($PSScriptRoot) {
        $copyRoot = Join-Path $PSScriptRoot 'copy-to-your-repo'
    }

    if (-not $copyRoot -or -not (Test-Path $copyRoot)) {
        # Fetch templates from upstream
        Write-Host "Fetching workflow templates from ALM4Dataverse release..." -ForegroundColor Yellow
        $upstreamClone = Join-Path ([System.IO.Path]::GetTempPath()) ("ALM4Dataverse-Templates-" + [guid]::NewGuid().ToString('n'))
        New-DirectoryIfMissing -Path $upstreamClone

        try {
            & git clone --depth 1 --branch $ALM4DataverseRef `
                $upstreamGitSource `
                $upstreamClone 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Failed to clone ALM4Dataverse templates." }
            $copyRoot = Join-Path $upstreamClone 'copy-to-your-repo'
        }
        finally {
            # We clean up $upstreamClone after usage
        }
    }

    Invoke-WithErrorHandling -OperationName "Copying workflow templates" -ScriptBlock {
        Copy-WorkflowTemplatesToRepo `
            -SourceRoot $copyRoot `
            -TargetRoot $cloneRoot `
            -Branch $defaultBranch `
            -SharedWorkflowRepository $sharedWorkflowRepository `
            -SharedWorkflowRef $sharedWorkflowReference
    } | Out-Null

    # ─────────────────────────────────────────────────────────
    Write-Section "Configure Solutions (alm-config.psd1)"

    $solutionResult = Invoke-WithErrorHandling -OperationName "Selecting solutions" -ScriptBlock {
        $existingConfigPath = Join-Path $cloneRoot 'alm-config.psd1'
        Get-DataverseSolutionsSelection -ExistingConfigPath $existingConfigPath -ExistingEnvironmentUrl $existingSetupState.DevEnvironment.Url -ExistingEnvironmentConfiguration $existingSetupState.DevEnvironment
    }

    if ($solutionResult -and $solutionResult.Solutions.Count -gt 0) {
        Invoke-WithErrorHandling -OperationName "Updating alm-config.psd1" -ScriptBlock {
            Update-AlmConfigInRepoClone -Solutions $solutionResult.Solutions -RepoRoot $cloneRoot
        } | Out-Null
    }

    $devEnvUrl = if ($solutionResult) { $solutionResult.EnvironmentUrl } else { $null }
    $devEnvFriendlyName = if ($solutionResult) { $solutionResult.EnvironmentFriendlyName } else { $null }
    $reuseExistingDevEnvironmentConfiguration = if ($solutionResult) { [bool]$solutionResult.ReuseExistingConfiguration } else { $false }

    # ─────────────────────────────────────────────────────────
    Write-Section "Configure Deployment Workflow"

    $initialDeploymentEnvironments = @()
    foreach ($existingDeploymentEnvironment in @($existingSetupState.DeploymentEnvironments)) {
        if ([string]::IsNullOrWhiteSpace($existingDeploymentEnvironment.ShortName)) {
            continue
        }

        $existingEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $existingDeploymentEnvironment.Url
        if ($existingEnvironmentUrl -and $existingEnvironmentUrl -ieq $devEnvUrl) {
            Write-Warning "Skipping existing deployment stage '$($existingDeploymentEnvironment.ShortName)' because it points at the selected DEV environment URL."
            continue
        }

        $initialDeploymentEnvironments += [pscustomobject]@{
            ShortName            = $existingDeploymentEnvironment.ShortName
            FriendlyName         = $existingDeploymentEnvironment.FriendlyName
            Url                  = $existingEnvironmentUrl
            Credentials          = $existingDeploymentEnvironment.Credentials
            ServiceAccountUPN    = $existingDeploymentEnvironment.ServiceAccountUPN
            ConfigurationPending = (($null -eq $existingDeploymentEnvironment.Credentials) -or [string]::IsNullOrWhiteSpace($existingDeploymentEnvironment.ServiceAccountUPN))
        }
    }

    $deploymentEnvironments = Invoke-WithErrorHandling -OperationName "Selecting deployment environments" -ScriptBlock {
        Select-ConfiguredDeploymentEnvironments `
            -InitialEnvironments $initialDeploymentEnvironments `
            -Heading 'Target Deployment Environments' `
            -Title 'Manage deployment environments' `
            -GuidanceLines @(
                "Add each target Dataverse environment together with the App Registration and service account that will be used for that stage.",
                "The table shows the full deployment configuration before DEPLOY-$defaultBranch.yml is regenerated, so you can verify URLs, authentication choices, and service-account ownership in one place.",
                'Best practice: keep short names stable and list environments in promotion order (for example TEST, UAT, PROD) because that sequence becomes the deployment stage chain.'
            ) `
            -DocRelativePath 'docs/setup/github-setup.md' `
            -Ref $ALM4DataverseRef `
            -AddEnvironmentScriptBlock {
                param($currentSelections)

                $selectedEnv = Select-DataverseEnvironment -Prompt 'Select a Dataverse environment for deployment' -ExcludeUrl $devEnvUrl
                if (-not $selectedEnv) {
                    return $null
                }

                $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
                if ($currentSelections | Where-Object { $_.Url -ieq $url }) {
                    Write-Host 'An environment with that URL is already selected.' -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    return $null
                }

                Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
                $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue ''
                if ($currentSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host 'An environment with that short name is already selected.' -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    return $null
                }

                $environmentConfiguration = Get-GitHubEnvironmentConfiguration `
                    -EnvironmentName $shortName `
                    -EnvironmentUrl $url `
                    -FriendlyName $selectedEnv.FriendlyName `
                    -ExistingCredentials $script:cachedCredentials `
                    -ExistingServiceAccounts $script:cachedServiceAccounts `
                    -TenantId $TenantId `
                    -RepoName $repoName

                if (-not ($script:cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                    $script:cachedCredentials += $environmentConfiguration.Credentials
                }
                if ($script:cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                    $script:cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                }

                return [pscustomobject]@{
                    ShortName            = $environmentConfiguration.ShortName
                    FriendlyName         = $environmentConfiguration.FriendlyName
                    Url                  = $environmentConfiguration.Url
                    Credentials          = $environmentConfiguration.Credentials
                    ServiceAccountUPN    = $environmentConfiguration.ServiceAccountUPN
                    ConfigurationPending = $false
                }
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
                $selectedEnv = Select-DataverseEnvironment -Prompt "Select the Dataverse environment for '$($environmentToEdit.ShortName)'" -ExcludeUrl $devEnvUrl -PreferredUrl $currentUrl
                if (-not $selectedEnv) {
                    return $null
                }

                $url = ConvertTo-NormalizedEnvironmentUrl -Url $selectedEnv.Endpoints['WebApplication']
                if ($otherSelections | Where-Object { $_.Url -ieq $url }) {
                    Write-Host 'An environment with that URL is already selected.' -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    return $null
                }

                Write-Host 'Use a short deployment environment name (for example: TEST, UAT, PROD).' -ForegroundColor DarkGray
                $shortName = Read-TextWithDefault -Prompt 'Enter a short name for this environment' -DefaultValue $environmentToEdit.ShortName
                if ($otherSelections | Where-Object { $_.ShortName -ieq $shortName }) {
                    Write-Host 'An environment with that short name is already selected.' -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    return $null
                }

                $currentCredentials = @($script:cachedCredentials)
                $currentCredentials += @($otherSelections | ForEach-Object { $_.Credentials } | Where-Object { $null -ne $_ })
                $currentServiceAccounts = @($script:cachedServiceAccounts)
                $currentServiceAccounts += @($otherSelections | ForEach-Object { $_.ServiceAccountUPN } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

                $environmentConfiguration = Get-GitHubEnvironmentConfiguration `
                    -EnvironmentName $shortName `
                    -EnvironmentUrl $url `
                    -FriendlyName $selectedEnv.FriendlyName `
                    -ExistingCredentials $currentCredentials `
                    -ExistingServiceAccounts $currentServiceAccounts `
                    -TenantId $TenantId `
                    -RepoName $repoName `
                    -ExistingCredential $environmentToEdit.Credentials `
                    -ExistingServiceAccountUPN $environmentToEdit.ServiceAccountUPN

                if (-not ($script:cachedCredentials | Where-Object { $_.ApplicationId -eq $environmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $environmentConfiguration.Credentials.TenantId })) {
                    $script:cachedCredentials += $environmentConfiguration.Credentials
                }
                if ($script:cachedServiceAccounts -notcontains $environmentConfiguration.ServiceAccountUPN) {
                    $script:cachedServiceAccounts += $environmentConfiguration.ServiceAccountUPN
                }

                return [pscustomobject]@{
                    ShortName            = $environmentConfiguration.ShortName
                    FriendlyName         = $environmentConfiguration.FriendlyName
                    Url                  = $environmentConfiguration.Url
                    Credentials          = $environmentConfiguration.Credentials
                    ServiceAccountUPN    = $environmentConfiguration.ServiceAccountUPN
                    ConfigurationPending = $false
                }
            }
    }

    $resolvedDeploymentEnvironments = @()
    foreach ($selectedDeploymentEnvironment in @($deploymentEnvironments)) {
        if ([string]::IsNullOrWhiteSpace($selectedDeploymentEnvironment.ShortName)) {
            continue
        }

        $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $selectedDeploymentEnvironment.Url
        $resolvedFriendlyName = if ([string]::IsNullOrWhiteSpace($selectedDeploymentEnvironment.FriendlyName)) { $selectedDeploymentEnvironment.ShortName } else { $selectedDeploymentEnvironment.FriendlyName }

        if ([string]::IsNullOrWhiteSpace($resolvedEnvironmentUrl)) {
            $resolvedEnvironment = Select-DataverseEnvironment -Prompt "Resolve the Dataverse environment for existing deployment stage '$($selectedDeploymentEnvironment.ShortName)'" -ExcludeUrl $devEnvUrl -PreferredUrl $selectedDeploymentEnvironment.Url
            if (-not $resolvedEnvironment) {
                throw "No Dataverse environment selected for existing deployment stage '$($selectedDeploymentEnvironment.ShortName)'."
            }

            $resolvedEnvironmentUrl = ConvertTo-NormalizedEnvironmentUrl -Url $resolvedEnvironment.Endpoints['WebApplication']
            $resolvedFriendlyName = $resolvedEnvironment.FriendlyName
        }

        if ($resolvedEnvironmentUrl -and $resolvedEnvironmentUrl -ieq $devEnvUrl) {
            Write-Warning "Skipping deployment environment '$($selectedDeploymentEnvironment.ShortName)' because it points at the selected DEV environment URL."
            continue
        }

        $needsConfiguration = (
            ($selectedDeploymentEnvironment.PSObject.Properties.Name -contains 'ConfigurationPending' -and $selectedDeploymentEnvironment.ConfigurationPending) -or
            ($null -eq $selectedDeploymentEnvironment.Credentials) -or
            [string]::IsNullOrWhiteSpace($selectedDeploymentEnvironment.ServiceAccountUPN)
        )

        if ($needsConfiguration) {
            Write-Host "Completing configuration for existing deployment environment '$($selectedDeploymentEnvironment.ShortName)'..." -ForegroundColor Yellow
            $completedEnvironment = Get-GitHubEnvironmentConfiguration `
                -EnvironmentName $selectedDeploymentEnvironment.ShortName `
                -EnvironmentUrl $resolvedEnvironmentUrl `
                -FriendlyName $resolvedFriendlyName `
                -ExistingCredentials $script:cachedCredentials `
                -ExistingServiceAccounts $script:cachedServiceAccounts `
                -TenantId $TenantId `
                -RepoName $repoName `
                -ExistingCredential $selectedDeploymentEnvironment.Credentials `
                -ExistingServiceAccountUPN $selectedDeploymentEnvironment.ServiceAccountUPN
        }
        else {
            $completedEnvironment = [pscustomobject]@{
                ShortName         = $selectedDeploymentEnvironment.ShortName
                FriendlyName      = $resolvedFriendlyName
                Url               = $resolvedEnvironmentUrl
                Credentials       = $selectedDeploymentEnvironment.Credentials
                ServiceAccountUPN = $selectedDeploymentEnvironment.ServiceAccountUPN
            }
        }

        $resolvedDeploymentEnvironments += $completedEnvironment
        if ($completedEnvironment.Credentials -and -not ($script:cachedCredentials | Where-Object { $_.ApplicationId -eq $completedEnvironment.Credentials.ApplicationId -and $_.TenantId -eq $completedEnvironment.Credentials.TenantId })) {
            $script:cachedCredentials += $completedEnvironment.Credentials
        }
        if (-not [string]::IsNullOrWhiteSpace($completedEnvironment.ServiceAccountUPN) -and $script:cachedServiceAccounts -notcontains $completedEnvironment.ServiceAccountUPN) {
            $script:cachedServiceAccounts += $completedEnvironment.ServiceAccountUPN
        }
    }

    $deploymentEnvironments = @($resolvedDeploymentEnvironments)

    Invoke-WithErrorHandling -OperationName "Updating DEPLOY workflow" -ScriptBlock {
        Update-DeployWorkflowInRepoClone `
            -RepoRoot $cloneRoot `
            -Branch $defaultBranch `
            -DeploymentEnvironments $deploymentEnvironments `
            -SharedWorkflowRepository $sharedWorkflowRepository `
            -SharedWorkflowRef $sharedWorkflowReference `
            -PromotionMode $deploymentPromotionMode
    } | Out-Null

    # ─────────────────────────────────────────────────────────
    # Commit and push the workflow template + config changes
    $repoPublishResult = Publish-GitHubRepoChanges -RepoRoot $cloneRoot -PublishPlan $repoPublishPlan
}
finally {
    Pop-Location
    try { Remove-Item -LiteralPath $cloneRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

# ─────────────────────────────────────────────────────────────
Write-Section "Configure Dev Environment Credentials"

$devEnvShortName = "Dev-$defaultBranch"
if ($useGitHubEnvironments) {
    Write-Host "Setting up GitHub environment '$devEnvShortName' for the DEV Dataverse environment." -ForegroundColor Green
}
else {
    Write-Host "Setting up prefixed repo-level credentials for DEV environment '$devEnvShortName'." -ForegroundColor Green
}
Write-Host ""

if (-not $devEnvUrl) {
    $existingDevEnvironmentSummary = Get-GitHubExistingEnvironmentSelectionSummary -ExistingEnvironment $existingSetupState.DevEnvironment
    $devEnvSelection = Select-DataverseEnvironment -Prompt "Select your DEV Dataverse environment" -PreferredUrl $existingSetupState.DevEnvironment.Url -PreferredSelectionSummary $existingDevEnvironmentSummary -KeepPreferredInList
    if ($devEnvSelection) {
        $devEnvUrl = ConvertTo-NormalizedEnvironmentUrl -Url $devEnvSelection.Endpoints["WebApplication"]
        $devEnvFriendlyName = $devEnvSelection.FriendlyName
        $reuseExistingDevEnvironmentConfiguration = ($devEnvSelection.PSObject.Properties.Name -contains 'UseExistingConfiguration' -and $devEnvSelection.UseExistingConfiguration)
    }
}

if ($devEnvUrl) {
    $canReuseExistingDevConfiguration = (
        $reuseExistingDevEnvironmentConfiguration -and
        $existingSetupState.DevEnvironment -and
        $existingSetupState.DevEnvironment.Credentials -and
        -not [string]::IsNullOrWhiteSpace($existingSetupState.DevEnvironment.ServiceAccountUPN)
    )

    if ($canReuseExistingDevConfiguration) {
        Write-Host 'Using the existing DEV environment credentials and service account you selected from the menu.' -ForegroundColor Green
        $devEnvironmentConfiguration = [pscustomobject]@{
            ShortName         = $devEnvShortName
            FriendlyName      = $(if ([string]::IsNullOrWhiteSpace($devEnvFriendlyName)) { $devEnvShortName } else { $devEnvFriendlyName })
            Url               = (ConvertTo-NormalizedEnvironmentUrl -Url $devEnvUrl)
            Credentials       = $existingSetupState.DevEnvironment.Credentials
            ServiceAccountUPN = $existingSetupState.DevEnvironment.ServiceAccountUPN
        }
    }
    else {
        if ($reuseExistingDevEnvironmentConfiguration -and -not $canReuseExistingDevConfiguration) {
            Write-Warning 'The existing DEV environment entry is missing either credentials or service account information, so setup needs to ask for the missing details.'
        }

        $devEnvironmentConfiguration = Invoke-WithErrorHandling -OperationName "Selecting DEV credentials" -ScriptBlock {
            Get-GitHubEnvironmentConfiguration `
                -EnvironmentName $devEnvShortName `
                -EnvironmentUrl $devEnvUrl `
                -FriendlyName $devEnvFriendlyName `
                -ExistingCredentials $script:cachedCredentials `
                -ExistingServiceAccounts $script:cachedServiceAccounts `
                -TenantId $TenantId `
                    -RepoName $repoName `
                    -ExistingCredential $existingSetupState.DevEnvironment.Credentials `
                    -ExistingServiceAccountUPN $existingSetupState.DevEnvironment.ServiceAccountUPN
        }
    }

    if (-not ($script:cachedCredentials | Where-Object { $_.ApplicationId -eq $devEnvironmentConfiguration.Credentials.ApplicationId -and $_.TenantId -eq $devEnvironmentConfiguration.Credentials.TenantId })) {
        $script:cachedCredentials += $devEnvironmentConfiguration.Credentials
    }
    if ($script:cachedServiceAccounts -notcontains $devEnvironmentConfiguration.ServiceAccountUPN) {
        $script:cachedServiceAccounts += $devEnvironmentConfiguration.ServiceAccountUPN
    }

    Invoke-WithErrorHandling -OperationName "Setting up DEV credentials" -ScriptBlock {
        Apply-GitHubEnvironmentConfiguration `
            -EnvironmentConfiguration $devEnvironmentConfiguration `
            -TenantId $TenantId `
            -RepoOwner $repoOwner `
            -RepoName $repoName `
            -RepoFullName $repoFullName `
            -UseGitHubEnvironments $useGitHubEnvironments `
            -EnableApprovals:$false
    } | Out-Null
}

# ─────────────────────────────────────────────────────────────
Write-Section "Configure Deployment Environment Credentials"

if ($useGitHubEnvironments) {
    Write-Host "Configuring GitHub environment credentials for deployment stages." -ForegroundColor Green
}
else {
    Write-Host "Configuring prefixed repo-level credentials for deployment stages." -ForegroundColor Green
}
Write-Host ""

if ($deploymentEnvironments.Count -gt 0) {
    Write-Host "Using deployment environments selected earlier: $($deploymentEnvironments.ShortName -join ', ')" -ForegroundColor DarkGray
}

if ($deploymentEnvironments.Count -eq 0) {
    Write-Host "No deployment environments selected. You can run this script again to add them later." -ForegroundColor Yellow
}
else {
    foreach ($env in $deploymentEnvironments) {
        Write-Section "Applying environment configuration: $($env.ShortName)"
        Write-Host "Dataverse URL: $($env.Url)" -ForegroundColor DarkGray
        Write-Host ""

        Invoke-WithErrorHandling -OperationName "Applying environment configuration for $($env.ShortName)" -AllowSkip -ScriptBlock {
            Apply-GitHubEnvironmentConfiguration `
                -EnvironmentConfiguration $env `
                -TenantId $TenantId `
                -RepoOwner $repoOwner `
                -RepoName $repoName `
                -RepoFullName $repoFullName `
                -UseGitHubEnvironments $useGitHubEnvironments `
                -EnableApprovals:$enableEnvironmentApprovals `
                -RequiredReviewerIds $environmentApprovalReviewerIds
        } | Out-Null
    }
}

# ─────────────────────────────────────────────────────────────
Clear-Host
Write-Host "Setup completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Access your GitHub repository at" -ForegroundColor Green
Write-Host "https://github.com/$repoFullName/actions" -ForegroundColor Green
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
Write-Host (Get-Alm4DataverseDocUrl -RelativePath 'docs/setup/github-setup.md' -Ref $ALM4DataverseRef) -ForegroundColor Green
Write-Host (Get-Alm4DataverseDocUrl -RelativePath 'docs/config/github-secrets.md' -Ref $ALM4DataverseRef) -ForegroundColor Green
