#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Applications, Az.Accounts

<#
.SYNOPSIS
    Configures an Entra ID app registration so GitHub Actions can log in to Azure with OIDC.

.DESCRIPTION
    Adds a federated identity credential to an existing app registration that trusts GitHub
    Actions tokens for a single repository branch:

        Issuer:   https://token.actions.githubusercontent.com
        Subject:  repo:<GitHubOrg>/<GitHubRepo>:ref:refs/heads/<Branch>
        Audience: api://AzureADTokenExchange

    Creation is skipped if a credential with the same issuer, subject and audience already exists.

    Afterwards the script prints the values for the AZURE_CLIENT_ID, AZURE_TENANT_ID and
    AZURE_SUBSCRIPTION_ID repository variables, together with matching `gh variable set` commands.

    Optionally lists the app's client secrets (metadata only - secret values are never read or
    printed) and removes the expired ones when -RemoveExpiredSecrets is passed.

    Tenant and subscription are taken from the current Az context (Connect-AzAccount). Use
    -SubscriptionId to pick a different subscription than the one currently selected.

.PARAMETER AppId
    Application (client) ID of the app registration used by the workflow.

.PARAMETER GitHubOrg
    GitHub organization or user that owns the repository.

.PARAMETER GitHubRepo
    GitHub repository name.

.PARAMETER Branch
    Branch the workflow runs from. Defaults to "main".

.PARAMETER SubscriptionId
    Optional. Subscription to report as AZURE_SUBSCRIPTION_ID. Defaults to the current Az context.

.PARAMETER ListSecrets
    List the app's existing client secrets with their expiry dates.

.PARAMETER RemoveExpiredSecrets
    Remove client secrets whose end date has passed. Implies -ListSecrets. Supports -WhatIf/-Confirm.

.EXAMPLE
    ./scripts/Setup-GitHubOidc.ps1 -AppId <app-id> -GitHubOrg <org> -GitHubRepo DeployCopilotSec

    Adds the federated credential for the main branch and prints the repository variables to set.

.EXAMPLE
    ./scripts/Setup-GitHubOidc.ps1 -AppId <app-id> -GitHubOrg <org> -GitHubRepo DeployCopilotSec -RemoveExpiredSecrets -WhatIf

    Shows which expired client secrets would be removed without changing anything.

.NOTES
    Requires the Microsoft.Graph.Applications and Az.Accounts modules (Az.Resources is used, if
    installed, to show the service principal's role assignments). The signed-in user needs
    permission to update the app registration (owner, Application Administrator or similar).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ $null -ne ($_ -as [guid]) }, ErrorMessage = 'AppId must be a GUID.')]
    [string]$AppId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]+$')]
    [string]$GitHubOrg,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$GitHubRepo,

    [ValidateNotNullOrEmpty()]
    [string]$Branch = 'main',

    [ValidateScript({ $null -ne ($_ -as [guid]) }, ErrorMessage = 'SubscriptionId must be a GUID.')]
    [string]$SubscriptionId,

    [switch]$ListSecrets,

    [switch]$RemoveExpiredSecrets
)

$ErrorActionPreference = 'Stop'

$issuer   = 'https://token.actions.githubusercontent.com'
$audience = 'api://AzureADTokenExchange'
$subject  = "repo:$GitHubOrg/${GitHubRepo}:ref:refs/heads/$Branch"

# --- Azure context (tenant + subscription) --------------------------------------------------

$azContext = Get-AzContext
if (-not $azContext) {
    Write-Host 'No Azure context found, signing in...' -ForegroundColor Yellow
    Connect-AzAccount | Out-Null
    $azContext = Get-AzContext
}
if ($SubscriptionId -and $azContext.Subscription.Id -ne $SubscriptionId) {
    Write-Verbose "Switching Az context to subscription $SubscriptionId"
    $azContext = Set-AzContext -Subscription $SubscriptionId
}
if (-not $azContext.Subscription) {
    throw 'The current Az context has no subscription. Run Set-AzContext or pass -SubscriptionId.'
}

$tenantId       = $azContext.Tenant.Id
$subscriptionId = $azContext.Subscription.Id
Write-Verbose "Tenant: $tenantId"
Write-Verbose "Subscription: $($azContext.Subscription.Name) ($subscriptionId)"

# --- Microsoft Graph ------------------------------------------------------------------------

$mgContext = Get-MgContext
if (-not $mgContext -or $mgContext.TenantId -ne $tenantId -or $mgContext.Scopes -notcontains 'Application.ReadWrite.All') {
    Write-Verbose 'Connecting to Microsoft Graph with Application.ReadWrite.All'
    Connect-MgGraph -TenantId $tenantId -Scopes 'Application.ReadWrite.All' -NoWelcome
}

$app = Get-MgApplication -Filter "appId eq '$AppId'" -Property 'id,appId,displayName,passwordCredentials'
if (-not $app) {
    throw "No app registration with appId $AppId found in tenant $tenantId."
}
Write-Host "App registration: $($app.DisplayName) ($($app.AppId))" -ForegroundColor Cyan

# --- Federated identity credential ----------------------------------------------------------

$existing = @(Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -All)
Write-Verbose "Found $($existing.Count) existing federated credential(s)."

$match = $existing | Where-Object {
    $_.Issuer -eq $issuer -and
    $_.Subject -ceq $subject -and
    $_.Audiences.Count -eq 1 -and $_.Audiences[0] -eq $audience
} | Select-Object -First 1

if ($match) {
    Write-Host "Federated credential '$($match.Name)' already exists for $subject - skipping." -ForegroundColor Green
}
else {
    # Name: letters, digits, '-' and '_' only, max 120 chars.
    $fcName = ("github-$GitHubOrg-$GitHubRepo-$Branch" -replace '[^A-Za-z0-9_-]', '-')
    if ($fcName.Length -gt 120) { $fcName = $fcName.Substring(0, 120) }

    if ($existing.Name -contains $fcName) {
        throw "A federated credential named '$fcName' already exists with a different issuer/subject/audience. Review it in the portal before re-running."
    }

    if ($PSCmdlet.ShouldProcess("$($app.DisplayName) ($AppId)", "Add federated credential '$fcName' for $subject")) {
        $body = @{
            name        = $fcName
            issuer      = $issuer
            subject     = $subject
            audiences   = @($audience)
            description = "GitHub Actions OIDC for $GitHubOrg/$GitHubRepo ($Branch)"
        }
        New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $body | Out-Null
        Write-Host "Created federated credential '$fcName' for $subject" -ForegroundColor Green
    }
}

# --- Role assignments (informational) -------------------------------------------------------

if (Get-Module -ListAvailable -Name Az.Resources) {
    try {
        $roles = @(Get-AzRoleAssignment -ServicePrincipalName $AppId -ErrorAction Stop)
        if ($roles.Count -eq 0) {
            Write-Warning "The service principal has no role assignments in subscription $subscriptionId. The workflow needs e.g. Contributor at subscription scope to create the resource group."
        }
        else {
            Write-Host "`nRole assignments for the service principal:" -ForegroundColor Cyan
            $roles | Format-Table RoleDefinitionName, Scope -AutoSize | Out-String | Write-Host
        }
    }
    catch {
        Write-Verbose "Could not read role assignments: $($_.Exception.Message)"
    }
}

# --- Client secrets -------------------------------------------------------------------------

if ($ListSecrets -or $RemoveExpiredSecrets) {
    $now     = [datetime]::UtcNow
    $secrets = @($app.PasswordCredentials)

    if ($secrets.Count -eq 0) {
        Write-Host "`nThe app has no client secrets." -ForegroundColor Green
    }
    else {
        Write-Host "`nClient secrets (metadata only):" -ForegroundColor Cyan
        $secrets |
            Sort-Object EndDateTime |
            Select-Object DisplayName, KeyId, StartDateTime, EndDateTime,
                @{ Name = 'Status'; Expression = { if ($_.EndDateTime -lt $now) { 'Expired' } else { 'Valid' } } } |
            Format-Table -AutoSize | Out-String | Write-Host

        if ($RemoveExpiredSecrets) {
            $expired = @($secrets | Where-Object { $_.EndDateTime -lt $now })
            if ($expired.Count -eq 0) {
                Write-Host 'No expired client secrets to remove.' -ForegroundColor Green
            }
            foreach ($secret in $expired) {
                $label = "'$($secret.DisplayName)' ($($secret.KeyId)), expired $($secret.EndDateTime.ToString('u'))"
                if ($PSCmdlet.ShouldProcess($label, 'Remove expired client secret')) {
                    Remove-MgApplicationPassword -ApplicationId $app.Id -KeyId $secret.KeyId
                    Write-Host "Removed client secret $label" -ForegroundColor Yellow
                }
            }
        }
    }
}

# --- Repository variables -------------------------------------------------------------------

$repoFullName = "$GitHubOrg/$GitHubRepo"

Write-Host "`nSet these as repository VARIABLES (not secrets) in ${repoFullName}:" -ForegroundColor Cyan
Write-Host "  AZURE_CLIENT_ID       = $AppId"
Write-Host "  AZURE_TENANT_ID       = $tenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID = $subscriptionId"

Write-Host "`nOr with the GitHub CLI:" -ForegroundColor Cyan
Write-Host "  gh variable set AZURE_CLIENT_ID --repo $repoFullName --body `"$AppId`""
Write-Host "  gh variable set AZURE_TENANT_ID --repo $repoFullName --body `"$tenantId`""
Write-Host "  gh variable set AZURE_SUBSCRIPTION_ID --repo $repoFullName --body `"$subscriptionId`""
