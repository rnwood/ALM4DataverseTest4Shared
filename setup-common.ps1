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
