# GitHub Actions Setup Guide

This guide describes how to set up ALM4Dataverse for use with GitHub Actions.

> **Azure DevOps users**: if you are using Azure DevOps, follow the [Azure DevOps setup guide](manual-setup.md) instead.

---

## Overview

ALM4Dataverse provides four reusable workflows hosted in the ALM4Dataverse repository.
You call them from your own repository's workflow files, which you copy from the
`copy-to-your-repo/.github/workflows/` folder.

| Your workflow | Reusable workflow called | Purpose |
|---|---|---|
| `BUILD.yml` | `build-reusable.yml` | Pack solutions, upload artifacts, tag commit |
| `EXPORT.yml` | `export-reusable.yml` | Export from dev Dataverse, commit to repo |
| `IMPORT.yml` | `import-reusable.yml` | Build from source, import into dev Dataverse |
| `DEPLOY-main.yml` | `deploy-environment-reusable.yml` | Deploy artifacts to each environment |

---

## Prerequisites

### 1. GitHub repository

Create or use an existing GitHub repository for your Dataverse application source code.

### 2. App Registration in Entra ID

For each Dataverse environment (Dev, Test, UAT, Production…), create an App Registration
in Entra ID to act as a service principal.

1. Navigate to the [Azure Portal](https://portal.azure.com) > **Entra ID** > **App registrations**
2. Click **New registration**
3. Name: `{ProjectName} - {EnvironmentName} - deployment` (e.g. `MyProject - PROD - deployment`)
4. Select "Accounts in this organizational directory only"
5. Click **Register**
6. Note the **Application (client) ID** and **Directory (tenant) ID**

You do not need to create a client secret if you use Workload Identity Federation (see below).
If you prefer client secret authentication, go to **Certificates & secrets** > **New client secret**
and copy the **Value** immediately after creation.

📖 **Reference**: [Register an app with Entra ID](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app)

### 3. Configure authentication for the App Registration

Choose one of the following authentication methods.

#### Option A: Workload Identity Federation / OIDC (recommended)

Workload Identity Federation lets GitHub Actions authenticate to Azure using short-lived
OIDC tokens with no secrets to manage or rotate.

1. In the App Registration, go to **Certificates & secrets** > **Federated credentials**
2. Click **Add credential**
3. Select **Other issuer**
4. Fill in:
   - **Issuer**: `https://token.actions.githubusercontent.com`
   - **Subject identifier**: depends on how the workflow runs (see below)
   - **Name**: e.g. `github-{environment-name}` (alphanumeric and hyphens only)
   - **Audience**: `api://AzureADTokenExchange`
5. Click **Add**

**Subject identifier format for GitHub Actions:**

| Workflow scenario | Subject identifier |
|---|---|
| Targets a GitHub environment (recommended) | `repo:{owner}/{repo}:environment:{environment-name}` |
| Branch-based (no GitHub environment) | `repo:{owner}/{repo}:ref:refs/heads/{branch-name}` |
| Manual dispatch (no environment) | `repo:{owner}/{repo}:ref:refs/heads/{branch-name}` |

> **Example** for an environment named `TEST-main` in the repo `MyOrg/MyApp`:
> `repo:MyOrg/MyApp:environment:TEST-main`

Since the ALM4Dataverse reusable workflows always declare an `environment:`, the
environment-based subject format is the recommended choice.  Create one federated
credential per GitHub environment (Dev-main, TEST-main, PROD, etc.) pointing to the
same or separate App Registrations.

📖 **References**:
- [Workload identity federation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation)
- [GitHub OIDC with Azure](https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure)

#### Option B: Client secret (traditional)

1. In the App Registration, go to **Certificates & secrets** > **New client secret**
2. Add a description and expiry period
3. Copy the **Value** immediately — you cannot view it again

### 4. Application user in each Dataverse environment

1. Go to the [Power Platform Admin Center](https://admin.powerplatform.microsoft.com)
2. Select the environment > **Settings** > **Users + permissions** > **Application users**
3. Click **New app user** > add your App Registration
4. Assign the **System Administrator** security role
5. Click **Create**

📖 **Reference**: [Create an application user](https://learn.microsoft.com/en-us/power-platform/admin/manage-application-users)

---

## Repository Setup

### Copy workflow templates to your repository

Copy all files from `copy-to-your-repo/` in the ALM4Dataverse repository into the root
of your application repository, preserving the folder structure:

```
your-repo/
├── .github/
│   └── workflows/
│       ├── BUILD.yml
│       ├── EXPORT.yml
│       ├── IMPORT.yml
│       └── DEPLOY-main.yml
├── alm-config.psd1
└── data/
```

### Configure `alm-config.psd1`

Edit `alm-config.psd1` to list the solutions you want to manage:

```powershell
@{
    solutions = @(
        @{ name = 'YourSolutionUniqueName' }
        @{ name = 'AnotherSolution' }
    )
}
```

### Configure deployment environments in `DEPLOY-main.yml`

Open `.github/workflows/DEPLOY-main.yml` and uncomment the deployment job blocks for
each environment you want to deploy to. Choose one of the two credential approaches
described in the next section.

If your default branch is not `main`:
- Rename the file to `DEPLOY-{branchname}.yml`
- Update the `branches:` filter in the `workflow_run` trigger

---

## Credential Configuration

ALM4Dataverse supports three approaches for per-environment credentials.
They can be mixed: use whichever fits each environment.

See [GitHub Secrets & Variables Reference](../config/github-secrets.md) for the full
list of secrets and variables required for each approach.

---

### Approach 1: Workload Identity Federation / OIDC (recommended)

WIF lets the workflow authenticate to Azure using a short-lived OIDC token issued by
GitHub — no secrets to store or rotate.

> **Prerequisite**: configure a federated credential on each App Registration as
> described in [Prerequisites → Workload Identity Federation](#option-a-workload-identity-federation--oidc-recommended).

#### 1.1 Create GitHub Environments

For each Dataverse environment:

1. Go to **Settings** > **Environments** in your GitHub repository
2. Click **New environment**
3. Name it to match your deployment target (e.g. `Dev-main`, `TEST-main`, `PROD`)
4. Click **Configure environment**

#### 1.2 Add variables (no client secret needed)

Inside each environment, add:

| Name | Type | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | Secret | App registration client ID |
| `AZURE_TENANT_ID` | Secret | Entra ID tenant ID |
| `DATAVERSESERVICEACCOUNTUPN` | Secret or Variable | UPN of the service account for activating processes |
| `DATAVERSE_URL` | Variable | Dataverse environment URL (e.g. `https://yourorg-test.crm.dynamics.com`) |

> **Do NOT set `AZURE_CLIENT_SECRET`** — when it is absent the workflows automatically
> obtain an OIDC token via GitHub's built-in token endpoint.

For connection references and environment variables, add individual entries:

| Name | Type | Value |
|------|------|-------|
| `DataverseConnRef_<schema_name>` | Variable | Connection ID GUID |
| `DataverseEnvVar_<schema_name>` | Variable | Environment variable value |

#### 1.3 Add protection rules (optional)

In the environment settings, you can add:
- **Required reviewers** — users or teams who must approve before deployment starts
- **Wait timer** — a delay (in minutes) before deployment runs
- **Deployment branches** — restrict which branches can deploy to this environment

> ⚠️ **Licence requirement**: Environment protection rules (required reviewers, wait timer,
> deployment branches) require **GitHub Pro, Team, or Enterprise** for private repositories.
> Public repositories can use protection rules on any plan.
> See [GitHub licence limitations](#github-licence-limitations) below.

#### 1.4 Configure your DEPLOY workflow (WIF)

In `DEPLOY-main.yml`, use the "Approach 1/2" blocks (uncomment and adjust):

```yaml
jobs:
  deploy-test:
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
    uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/deploy-environment-reusable.yml@stable
    with:
      environment-name: TEST-main
      build-run-id: >-
        ${{ github.event_name == 'workflow_dispatch'
              && inputs.build-run-id
              || github.event.workflow_run.id }}
    secrets: inherit   # passes AZURE_CLIENT_ID, AZURE_TENANT_ID (no client secret needed)

  deploy-prod:
    needs: deploy-test
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
    uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/deploy-environment-reusable.yml@stable
    with:
      environment-name: PROD
      build-run-id: >-
        ${{ github.event_name == 'workflow_dispatch'
              && inputs.build-run-id
              || github.event.workflow_run.id }}
    secrets: inherit
```

---

### Approach 2: GitHub Environments with client secret

Use this approach if you prefer or require client secret authentication while still
using GitHub Environments for approval gates.

#### 2.1 Create GitHub Environments

Follow the same steps as Approach 1.

#### 2.2 Add secrets and variables (including client secret)

Inside each environment, add:

| Name | Type | Value |
|------|------|-------|
| `AZURE_CLIENT_ID` | Secret | App registration client ID |
| `AZURE_CLIENT_SECRET` | Secret | App registration client secret |
| `AZURE_TENANT_ID` | Secret | Entra ID tenant ID |
| `DATAVERSESERVICEACCOUNTUPN` | Secret or Variable | UPN of the service account for activating processes |
| `DATAVERSE_URL` | Variable | Dataverse environment URL (e.g. `https://yourorg-test.crm.dynamics.com`) |

For connection references and environment variables, add individual entries:

| Name | Type | Value |
|------|------|-------|
| `DataverseConnRef_<schema_name>` | Variable | Connection ID GUID |
| `DataverseEnvVar_<schema_name>` | Variable | Environment variable value |

Example:

| Name | Value |
|------|-------|
| `DataverseConnRef_contoso_sharedsharepointonline` | `12345678-1234-1234-1234-123456789abc` |
| `DataverseEnvVar_contoso_APIEndpoint` | `https://api.test.contoso.com` |

#### 2.3 Configure your DEPLOY workflow (client secret)

The YAML is identical to Approach 1 — `secrets: inherit` passes both
`AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` (see [1.4](#14-configure-your-deploy-workflow-wif)).

---

### Approach 3: Prefixed global secrets

Store all credentials as repository-level secrets/variables using a naming convention
that includes the environment name as a prefix.  This approach works on **all GitHub
licence levels** including GitHub Free on private repositories.

> ⚠️ **No approval gates**: Without environment protection rules there is no built-in
> approval mechanism.  Anyone who can trigger the DEPLOY workflow can deploy to any
> environment.  For production environments, consider restricting who can trigger the
> workflow by using branch protection rules on `main` and limiting merge permissions.

#### 3.1 Add secrets and variables

In **Settings** > **Secrets and variables** > **Actions**, add:

| Name | Type | Value |
|------|------|-------|
| `TEST_MAIN_AZURE_CLIENT_ID` | Secret | App registration client ID |
| `TEST_MAIN_AZURE_CLIENT_SECRET` | Secret | Client secret (omit if using WIF) |
| `TEST_MAIN_AZURE_TENANT_ID` | Secret | Tenant ID |
| `TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN` | Secret | Service account UPN |
| `TEST_MAIN_DATAVERSE_URL` | Variable | Dataverse URL |
| `TEST_MAIN_DATAVERSE_CONN_REFS` | Variable | JSON — see below |
| `TEST_MAIN_DATAVERSE_ENV_VARS` | Variable | JSON — see below |

Repeat with a `PROD_` prefix for production (and similar for other environments).

For dev environments used in EXPORT/IMPORT, use a prefix like `DEV_MAIN_`.

**Connection references JSON format** (variable `TEST_MAIN_DATAVERSE_CONN_REFS`):

```json
{
  "contoso_sharedsharepointonline": "12345678-1234-1234-1234-123456789abc",
  "contoso_sharedcommondataserviceforapps": "98765432-9876-9876-9876-987654321xyz"
}
```

**Environment variables JSON format** (variable `TEST_MAIN_DATAVERSE_ENV_VARS`):

```json
{
  "contoso_APIEndpoint": "https://api.test.contoso.com",
  "contoso_BatchSize": "50"
}
```

#### 3.2 Configure your DEPLOY workflow (prefixed secrets)

In `DEPLOY-main.yml`, use the "Approach 3" blocks (uncomment and adjust):

```yaml
jobs:
  deploy-test:
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
    uses: ALM4Dataverse/ALM4Dataverse/.github/workflows/deploy-environment-reusable.yml@stable
    with:
      environment-name: TEST-main
      build-run-id: >-
        ${{ github.event_name == 'workflow_dispatch'
              && inputs.build-run-id
              || github.event.workflow_run.id }}
      dataverse-url:             ${{ vars.TEST_MAIN_DATAVERSE_URL }}
      dataverse-connection-refs: ${{ vars.TEST_MAIN_DATAVERSE_CONN_REFS }}
      dataverse-env-vars:        ${{ vars.TEST_MAIN_DATAVERSE_ENV_VARS }}
    secrets:
      azure-client-id:               ${{ secrets.TEST_MAIN_AZURE_CLIENT_ID }}
      azure-client-secret:           ${{ secrets.TEST_MAIN_AZURE_CLIENT_SECRET }}
      azure-tenant-id:               ${{ secrets.TEST_MAIN_AZURE_TENANT_ID }}
      dataverse-service-account-upn: ${{ secrets.TEST_MAIN_DATAVERSE_SERVICE_ACCOUNT_UPN }}
```

---

## GitHub Licence Limitations

| Feature | Free (public) | Free (private) | Pro | Team | Enterprise |
|---------|:---:|:---:|:---:|:---:|:---:|
| GitHub Actions | ✅ | ✅ | ✅ | ✅ | ✅ |
| GitHub Environments (secrets/vars) | ✅ | ✅ | ✅ | ✅ | ✅ |
| Environment protection rules (approvals, wait timers) | ✅ | ❌ | ✅ | ✅ | ✅ |
| Deployment branches restriction | ✅ | ❌ | ✅ | ✅ | ✅ |
| Actions minutes included | Unlimited | 2 000/month | 3 000/month | 3 000/month | 50 000/month |

### Impact on private repository deployments (Free plan)

On a **private repository with GitHub Free**:

- You **can** store environment-specific secrets and variables in GitHub Environments.
- You **cannot** add protection rules to environments — deployments run immediately
  without waiting for approval.
- You **can** use Approach 2 (prefixed global secrets) with the same limitation: no
  approval gates.
- Workflow minutes are limited to 2,000/month for the repository. Windows runners
  (used by ALM4Dataverse) consume minutes at 2× the Linux rate, so the effective
  budget is 1,000 minutes of pipeline time per month on the Free plan.

**Workarounds for approval control on Free plan:**

- Use branch protection rules on `main` to restrict who can merge/push, which
  indirectly controls who can trigger deployments via the `workflow_run` trigger.
- Restrict `workflow_dispatch` permission using repository collaborator roles —
  only users with at least **Write** access can trigger manual workflows.
- Consider upgrading to GitHub Pro/Team for production workloads.

---

## Grant permissions for workflow operations

### Write access for EXPORT

The EXPORT workflow commits and pushes solution changes back to the repository.

1. Go to **Settings** > **Actions** > **General**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Click **Save**

Alternatively, this is handled per-workflow via `permissions: contents: write` in the
reusable workflow, which overrides the default.

### Actions read for DEPLOY (artifact download)

The DEPLOY workflow downloads artifacts from the BUILD workflow run.  The reusable
workflow declares `permissions: actions: read`, which is granted automatically by the
caller's `GITHUB_TOKEN` on all plans.

---

## Usage

Once configured:

- **BUILD** — runs automatically on every push. View run status in the **Actions** tab.
- **EXPORT** — go to **Actions** > **EXPORT** > **Run workflow**, enter a commit message, and click **Run workflow**.
- **IMPORT** — go to **Actions** > **IMPORT** > **Run workflow** and click **Run workflow**.
- **DEPLOY** — runs automatically when BUILD succeeds on `main`, or go to **Actions** > **DEPLOY-main** > **Run workflow** and provide a BUILD run ID.

### Finding a BUILD run ID for manual deploy

1. Go to **Actions** and select the **BUILD** workflow
2. Click the run you want to deploy
3. The run ID is visible in the URL: `github.com/{owner}/{repo}/actions/runs/{run-id}`

---

## References

- [GitHub Actions reusable workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [GitHub Environments and deployment protection rules](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [GitHub Actions billing and usage limits](https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions)
- [GitHub Secrets & Variables Reference](../config/github-secrets.md)
