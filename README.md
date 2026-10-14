# Microsoft Copilot for Security

This repository contains an Azure Bicep file for deploying a `Microsoft.SecurityCopilot/capacities` resource, along with GitHub Actions workflows for automated deployment and destruction of resources.

## Azure Bicep

The `main.bicep` file in this repository deploys a `Microsoft.SecurityCopilot/capacities` resource with the following properties:

- `capacityName`: The name of the capacity.
- `geo`: The geographical location code. This can be one of the following: 'EU', 'ANZ', 'US', 'UK'.
- `location`: The Azure location is automatically filled in and determined when you choose `geo` (geographical location), see bicep code for logic.
- `numberOfUnits`: The number of units.
- `crossGeoCompute`: Whether cross-geo compute is allowed. This can be either 'Allowed' or 'NotAllowed'.

The `main.bicepparam` file contains the parameter values for the `main.bicep` file. You can update the parameter values in this file as necessary.

## GitHub Actions

There are two GitHub Actions workflows in this repository:

1. **Deployment Workflow (`deploy.yml`)**: Deploys the Bicep file to the `JLCopilot` resource group in `westeurope`. It is started manually (Actions → Deploy SecCopilot → Run workflow). The resource group is created if it does not exist, and `az deployment group what-if` runs before the deployment. Tick **whatIfOnly** to preview the changes without deploying anything.

2. **Destruction Workflow (`destroy.yml`)**: Destroys the deployed resources by deleting the resource group in Azure. It runs every day at midnight UTC and can also be started manually.

Both workflows log in to Azure with OpenID Connect (federated credentials), so no client secret is stored in GitHub.

## Usage

To use this repository, you need to do the following:

1. Fork this repository to your own GitHub account.
2. Create (or reuse) an app registration in Entra ID and give its service principal the **Contributor** role on the subscription. Subscription scope is needed because the resource group is deleted and recreated.
   ```bash
   appId=$(az ad app create --display-name {app-name} --query appId -o tsv)
   az ad sp create --id $appId
   az role assignment create --assignee $appId --role Contributor --scope /subscriptions/{subscription-id}
   ```
   No client secret is needed.
3. Run the setup script with PowerShell 7 (needs the `Microsoft.Graph.Applications` and `Az.Accounts` modules) after signing in with `Connect-AzAccount` to the right subscription:
   `./scripts/Setup-GitHubOidc.ps1 -AppId {app-id} -GitHubOrg {github-org} -GitHubRepo {repo-name}`
   It adds a federated credential for `repo:{org}/{repo}:ref:refs/heads/main` to the app registration. Add `-RemoveExpiredSecrets` to also clean up expired client secrets.
4. Set the three values the script prints as repository **variables** (not secrets) under Settings → Secrets and variables → Actions → Variables, or run the `gh variable set` commands it prints:
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`
5. Update the parameters in the `main.bicepparam` file and the resource group name and location in the workflows as necessary.

The federated credential only trusts the `main` branch, so run the workflows from `main`.

Please note that deleting a resource group will delete all resources within that group. Make sure this is what you want before running the destruction workflow.

## Contributing

Contributions are welcome! Please feel free to submit a pull request.

## License

This project is licensed under the terms of the MIT license.
