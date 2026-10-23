# Windows app signing from GitHub Actions

Use Azure Artifact Signing (formerly Trusted Signing) to sign Windows releases
under your verified publisher identity. GitHub authenticates through OIDC and
Azure holds the signing keys. No PFX download or client secret is needed.

## What to reuse for your other apps

Reuse this signing account and active certificate profile for apps you publish
under the same identity:

| Setting | Existing value |
|---|---|
| Signing account | `theo-gibbons` |
| Account URI | `https://eus.codesigning.azure.net/` |
| Active Public Trust profile | `windows-app-signing-v3` |
| Tenant ID | `ed7b52d5-a4f8-4c29-bed1-b5c6cf7655dd` |
| Subscription ID | `99f62251-76d3-40ec-9bb3-70857da462f6` |
| GitHub owner | `TheoGibbons` |
| GitHub owner ID | `1817181` |

For each new repository, create its own Entra app registration and GitHub
federated credential using the steps below. This keeps each repository's Azure
access independently manageable. You do not need to repeat identity validation
or create another certificate profile for each app.

The existing `remote-desktop-github` registration belongs to this app. Its client
ID is `66d5c967-c366-4024-b695-ab4d3f473201`; use the new registration's client ID
for your other app. These IDs and account names are not passwords.

## 1. Check the signing account in Azure

1. In the Azure portal's top search, find **Artifact Signing Accounts** (older UI:
   **Trusted Signing**). This is separate from App Service Certificates.
2. Open **theo-gibbons**. On **Overview**, confirm the **Account URI** above.
3. Under **Objects > Identity validations**, confirm your Public identity is
   **Completed** and unexpired.
4. Under **Objects > Certificate profiles**, confirm
   **windows-app-signing-v3** is **Active** and **Public Trust**.

If you need a replacement profile: choose **Create > Public Trust**, give it an
internal name, select the verified identity, and leave **Program type: None**.
Copy the exact new name into the workflow. The earlier `windows-app-signing`
profile failed; do not use that name for this account.

Your Azure user needs Owner or Contributor to create profiles. The separate
Identity Verifier role manages identity validation; the Certificate Profile
Signer role permits signing. See [Azure's role table](https://learn.microsoft.com/en-us/azure/artifact-signing/tutorial-assign-roles).

## 2. Create an Azure identity for the new repository

1. Search Azure for **App registrations**, then select **New registration**.
2. Name it `<your-app>-github`.
3. Select **Accounts in this organizational directory only**.
4. Leave **Redirect URI** blank and click **Register**.
5. On its **Overview**, copy **Application (client) ID** and **Directory (tenant) ID**.
   Use the client ID, not Object ID, in the workflow login.

Do not create a client secret. The next step establishes GitHub's identity.

## 3. Add a federated credential in the Azure GUI

Inside the new app registration:

1. Open **Certificates & secrets > Federated credentials > Add credential**.
2. Choose **GitHub Actions deploying Azure resources**.
3. Fill in the following fields, using the new app's repository:

| Field | Value |
|---|---|
| Organization/owner | `TheoGibbons` (or the actual repository owner) |
| Organization ID | `1817181` for TheoGibbons, even though it is a personal account |
| Repository | The new repository's name |
| Repository ID | The new repository's numeric ID |
| Entity type | **Environment** |
| Environment name | `production` |
| Credential name | `github-production` |
| Audience | Keep `api://AzureADTokenExchange` |

4. Save the credential. Keep the issuer and generated subject supplied by the
   GitHub scenario. The environment must match the workflow exactly.

To look up numeric IDs for a public repository, open
`https://api.github.com/repos/OWNER/REPOSITORY` in your browser. The top-level
`id` is the repository ID; `owner.id` is the organization/user ID. For a private
repository, use an authenticated GitHub CLI session:

```powershell
gh api repos/OWNER/REPOSITORY --jq '{repositoryId: .id, ownerId: .owner.id}'
```

Do not reuse remote-desktop's repository ID for another app.

## 4. Give the app permission to sign

1. Return to **Artifact Signing Accounts > theo-gibbons > Access control (IAM)**.
2. Select **Add > Add role assignment**.
3. Select **Artifact Signing Certificate Profile Signer**, then **Next**.
4. Choose **User, group, or service principal > Select members**.
5. Search for the new `<your-app>-github` registration and select it.
6. Select **Review + assign**.
7. In **Role assignments**, verify the new app appears as a **Service principal**
   with that role at **This resource** scope.

Permission assigned to Theo Gibbons alone does not authorize GitHub Actions.
Allow a few minutes for a new assignment to propagate.

## 5. Configure the GitHub environment

In the new repository, open **Settings > Environments**:

1. Open the existing **production** environment, or create it if absent.
2. If deployment restrictions are enabled, allow **Tag** pattern `v*` for a
   tag-triggered release. Preserve existing branch rules and required reviewers.
3. Under **Environment variables**, add:

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | New app registration's Application (client) ID |
| `AZURE_TENANT_ID` | Tenant ID from step 2 |
| `AZURE_SUBSCRIPTION_ID` | Subscription containing the signing account |

This guide uses GitHub **variables**, referenced as `vars.*`, for portability.
The remote-desktop workflow instead embeds the same non-secret IDs directly;
both approaches work. Do not add PFX or Azure password secrets.

## 6. Update the app's release workflow

Edit the existing workflow under `.github/workflows/`. Keep the app's existing
checkout, tool setup, and build steps. The job that signs must use a Windows
runner, `environment: production`, and `id-token: write` permission.

Merge these job settings into that job (preserve any other permissions it needs):

```yaml
jobs:
  release:
    runs-on: windows-latest
    environment: production
    permissions:
      contents: write # Needed when this job publishes GitHub Releases.
      id-token: write
    steps:
      # Keep existing checkout, setup, and build steps here.
```

Insert the following steps **after building the final EXE and before calculating
checksums or uploading release files**. Replace both `dist/MyApp.exe` paths with
your app's actual output. The account and profile below can be reused as-is.

```yaml
      - name: Authenticate to Azure for signing
        uses: azure/login@v3
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Sign Windows app
        uses: azure/artifact-signing-action@v2
        with:
          endpoint: https://eus.codesigning.azure.net/
          signing-account-name: theo-gibbons
          certificate-profile-name: windows-app-signing-v3
          files: ${{ github.workspace }}\dist\MyApp.exe
          file-digest: SHA256
          timestamp-rfc3161: http://timestamp.acs.microsoft.com
          timestamp-digest: SHA256
          exclude-environment-credential: true
          exclude-azure-cli-credential: false

      - name: Verify Windows signature
        shell: pwsh
        run: |
          $signTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter signtool.exe |
            Where-Object FullName -Like '*\x64\signtool.exe' |
            Sort-Object FullName -Descending |
            Select-Object -First 1 -ExpandProperty FullName
          if (-not $signTool) { throw 'signtool.exe was not found.' }
          & $signTool verify /pa /v dist/MyApp.exe
          if ($LASTEXITCODE -ne 0) { throw 'Windows signature verification failed.' }
```

Remove old PFX import/signing steps and any fallback that silently publishes
unsigned files. Keep timestamping enabled. Leave signing and verification failures
fatal; do not add `continue-on-error`.

For multiple files, use a multiline `files: |` list of absolute paths and verify
each one. For installers, sign your app binaries first, build the installer from
those signed binaries, then sign and verify the final installer too. Build ZIPs
and checksums after signing. Adapt the packaging steps to your app's build tool;
signing only an installer does not sign the EXEs inside it.

For MSIX, the manifest Publisher must match the signing certificate subject.
See [Microsoft's MSIX signing guide](https://learn.microsoft.com/en-us/windows/msix/package/sign-msix-package-guide).

## 7. Publish and check the result

Commit the workflow change before creating the release tag. Follow your app's
versioning process, then push the commit and its new `v*` tag. This repository's
commands are in [RELEASING.md](RELEASING.md).

In GitHub Actions, confirm Azure login, signing, and verification all pass.
Download the published EXE and check **Properties > Digital Signatures**, or run:

```powershell
Get-AuthenticodeSignature .\MyApp.exe | Format-List Status, StatusMessage, SignerCertificate
```

Expect `Status: Valid` and your verified publisher identity. Signing does not
guarantee that SmartScreen will never show a reputation warning.

## Troubleshooting

| Symptom | Check |
|---|---|
| Signing returns `403 Forbidden` | Check the signing app's Signer role, exact active profile name, account name, endpoint region, and completed identity validation. |
| Log still says `windows-app-signing` | That run uses an old workflow. It must say `windows-app-signing-v3` for this account. |
| Azure login rejects the federated identity | Compare the token subject shown in the login error with the Azure credential: repository, environment, and numeric IDs must match. Older repositories may emit a different subject format; follow the linked federation guidance rather than guessing the subject. |
| Empty `AZURE_CLIENT_SECRET` in action logs | Expected for this OIDC setup; the signing action uses the preceding Azure CLI login. |
| Build waits for environment approval or rejects the tag | Check `production` reviewers and deployment tag rules. |
| Profile creation shows `UnknownError` | Confirm identity and creation permissions; signing out/in helped during this setup. If it persists, collect the Activity Log error and correlation ID for Azure support. |

For an IAM-only fix, wait for propagation and re-run the failed job. For a
workflow fix, create a new release from the corrected commit: re-running an old
tag's job still uses its original workflow. Do not repeatedly bump versions for
an Azure-only configuration change.

## References

- [Azure Artifact Signing setup](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
- [GitHub signing action and supported inputs](https://github.com/Azure/artifact-signing-action)
- [OIDC setup for the signing action](https://github.com/Azure/artifact-signing-action/blob/main/docs/OIDC.md)
- [Azure federated credential configuration](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust)
- [Artifact Signing troubleshooting](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)
