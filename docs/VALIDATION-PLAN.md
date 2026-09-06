# Master Validation Plan

This is the single consolidated testing procedure across every phase of
this project. Run top to bottom, in order - later sections assume earlier
ones passed.

Run all `kubectl`/`az` commands from the jumpbox unless a step
says otherwise.

---

## Prerequisites

Nothing in Section 0 onward can run at all until this exists - every
workflow (`terraform.yml`, `build-and-push.yml`) authenticates to Azure
via OIDC, which requires a real Microsoft Entra Application, a Service
Principal, and federated credentials trusting GitHub's OIDC issuer for
this specific repo. One-time, manual, done from your own machine (or
Cloud Shell) with `az login` as yourself.

### Create the App Registration and Service Principal

```bash
az ad app create --display-name "aks-container-platform-github-actions"
APP_ID=$(az ad app list --display-name "aks-container-platform-github-actions" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
```

### Three federated credentials - not one

**A real, non-obvious detail worth getting right the first time:** the
`apply` job in `terraform.yml` declares `environment: production` -
which changes the OIDC subject claim GitHub issues for that specific
job, compared to a job with no environment declared. One federated
credential covering only the "push to main" case leaves the `plan` job
(triggered on `pull_request`) and the `apply` job (using the
`environment` claim) both unable to authenticate - each needs its own.

```bash
# For the plan job (terraform.yml) - pull_request, no environment
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-pull-request",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:GreatOmotayo/azure-aks-container-platform:pull_request",
  "audiences": ["api://AzureADTokenExchange"]
}'

# For the apply job (terraform.yml) - environment: production
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-environment-production",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:GreatOmotayo/azure-aks-container-platform:environment:production",
  "audiences": ["api://AzureADTokenExchange"]
}'

# For build-and-push.yml - push to main, no environment declared
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-main-branch",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:GreatOmotayo/azure-aks-container-platform:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

### RBAC on your subscription - Contributor alone is not enough

This project's Terraform creates dozens of `azurerm_role_assignment`
resources throughout (Workload Identity credentials, ACR push, Key
Vault/Storage RBAC, AKS admin, jumpbox AAD login) - `Contributor`
explicitly cannot create new role assignments. `User Access
Administrator` is required too:

```bash
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "Contributor" --scope "/subscriptions/$SUBSCRIPTION_ID"
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope "/subscriptions/$SUBSCRIPTION_ID"
```

**A genuine chicken-and-egg problem, solved here rather than worked
around later:** `Contributor`/`User Access Administrator` only cover
management-plane access - neither grants data-plane access to read or
write secret *values* inside an RBAC-mode Key Vault. The Key Vault
module's own role assignment would normally grant this dynamically to
whoever runs `apply`, scoped to the vault itself - but the vault doesn't
exist yet at this point in setup, so there's nothing to scope a grant
to. Granted broadly, temporarily, at the subscription level instead,
specifically so the very first `apply` (which both creates the vault
and needs to read the secret it creates) succeeds:

```bash
az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "Key Vault Secrets Officer" --scope "/subscriptions/$SUBSCRIPTION_ID"
```

**This gets narrowed down to the specific vault right after the first
build succeeds (Section 1.4) - it isn't meant to stay this broad.**

### GitHub repository secrets

```bash
echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)"
```
Add these, plus `AZURE_SUBSCRIPTION_ID`, in **Settings → Secrets and
variables → Actions** before anything in Section 0 onward is attempted
via CI.

### Allow GitHub Actions to create pull requests

**A required, one-time repo setting - not something any workflow YAML
can configure.** `build-and-push.yml` and `terraform.yml` both open a
pull request as part of their normal operation (the tag bump, and the
values-population step) - without this setting, those steps fail with
`Error: GitHub Actions is not permitted to create or approve pull
requests`, regardless of how correct the workflow's own `permissions:`
block is.

**Settings → Actions → General → Workflow permissions → check "Allow
GitHub Actions to create and approve pull requests" → Save.**

---

## 0. Initial access

### 0.1 - Connect to the jumpbox

No Bastion anymore - the jumpbox has its own public IP, with an NSG
restricting inbound SSH to exactly the one address in your own
`terraform.tfvars`'s `jumpbox_allowed_ssh_source_ip`. Get the actual
public IP:

```bash
terraform output -raw jumpbox_public_ip
```

Two ways to connect, depending on what you need:

**AAD-based (the method used throughout this document, whenever it
says "run from the jumpbox"):**
```bash
az ssh vm --ip <public-ip-from-above> --local-user azureuser
```
This authenticates using **your own logged-in Entra identity** - it
only works if you're a member of the admin group granted `Virtual
Machine Administrator Login` on this VM (`modules/jumpbox`'s
`jumpbox_aad_login` role assignment).

**Plain SSH key (the break-glass fallback):**
```bash
ssh -i ~/.ssh/<your-private-key> azureuser@<public-ip-from-above>
```

**If your own IP changes**, `jumpbox_allowed_ssh_source_ip` in
`terraform.tfvars` needs updating and a fresh `terraform apply` before
either connection method works again - this is the one real,
recurring friction point of replacing Bastion with a plain NSG
allowlist (see `docs/DECISIONS.md` Part 4).

**On a freshly-created jumpbox specifically**, if a tool this document
expects (`terraform`, `az`, `k6`, `velero`, `helm`) comes back
`command not found` right after connecting, the boot script may
simply still be running - check before assuming something's broken:

```bash
cloud-init status --wait
```

**This blocks until boot-time setup genuinely finishes**, then retry
the missing command. If it reports `status: done` and the tool is
still missing, that's a real gap worth checking
`/var/log/cloud-init-output.log` for, not just a timing issue.

---

## 1. Infrastructure validation (Terraform)

### 1.1 - Apply aks-platform/ (the only project now)

```bash
cd aks-platform
terraform apply
```
This can now run either manually from the jumpbox, or via CI - both
authenticate identically, since there's no VNet-access constraint left
on this project at all (see `docs/DECISIONS.md` Part 4).

### 1.2 - Private cluster has no public endpoint
```bash
az aks show -g rg-aks-app -n aks-production --query "apiServerAccessProfile"
az aks show -g rg-aks-app -n aks-production --query "privateFqdn" -o tsv
```
**Expected:** `enablePrivateCluster: true`, a real private FQDN
returned. This is the one piece of the original private-by-default
design kept intact by explicit choice.

### 1.3 - DNS resolution works from the jumpbox
```bash
nslookup <private_fqdn_from_1.2>
```

### 1.4 - Confirm the storage sub-resources and Key Vault secret exist

The Storage queue, container, and the Key Vault secret are all created
directly by Terraform (see `modules/storage/main.tf` and root
`main.tf`'s `azurerm_key_vault_secret` resource) - both the Storage
Account and the Key Vault are public now (see `docs/DECISIONS.md` Part
4), so there's no longer any network-location constraint on where
`apply` runs from at all; RBAC is the only real requirement.

**The table is the one exception - create it manually here.** This is a
genuine, documented `azurerm_storage_table` provider limitation,
entirely unrelated to the public/private network question: Shared Key
authentication is always required to set or retrieve a table's ACLs,
regardless of `storage_use_azuread` or which identity runs `apply` -
and this account has `shared_access_key_enabled = false`, so no key
exists at all. The two are structurally incompatible; there's no
Terraform configuration that resolves it.

```bash
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
VAULT_NAME=$(terraform output -raw key_vault_name)

az storage queue exists --name jobs --account-name "$STORAGE_ACCOUNT" --auth-mode login
az storage table create --name jobs --account-name "$STORAGE_ACCOUNT" --auth-mode login
az storage container exists --name velero-backups --account-name "$STORAGE_ACCOUNT" --auth-mode login
az keyvault secret show --vault-name "$VAULT_NAME" --name storage-account-name --query value -o tsv
```

**Expected:** the queue/container/secret confirm existence -
`terraform apply` already created them, this step is verifying that,
not performing it. The table command actually creates it, since nothing
else in this project does.

**A separate, easy-to-miss gotcha, if you later query job status
manually** (`az storage entity query --table-name jobs ...`, outside
anything this section itself does): this needs a real
`Storage Table Data Reader` (or `Contributor`) role on your own
identity specifically - `Storage Blob Data Owner` and
`Storage Queue Data Contributor` do **not** cover Table operations at
all, even though all three sit on the same Storage Account. Azure
treats Blob/Queue/Table as three genuinely independent data-plane
grants, not a bundle. If you hit a permissions error here despite
already having broad-sounding roles, check specifically for a missing
Table-scoped one:

```bash
STORAGE_ID=$(az storage account show --name "$STORAGE_ACCOUNT" -g rg-aks-app --query id -o tsv)
MY_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --assignee-object-id "$MY_OBJECT_ID" --assignee-principal-type User --role "Storage Table Data Reader" --scope "$STORAGE_ID"
```

**Now that the vault exists, scope the `Key Vault Secrets Officer`
grant down to just this vault** - the broad subscription-level grant
from Prerequisites was only ever a temporary bootstrap measure:

```bash
KEY_VAULT_ID=$(az keyvault show --name "$VAULT_NAME" -g rg-aks-app --query id -o tsv)

az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "Key Vault Secrets Officer" --scope "$KEY_VAULT_ID"

az role assignment delete --assignee-object-id "$SP_OBJECT_ID" --role "Key Vault Secrets Officer" --scope "/subscriptions/$SUBSCRIPTION_ID"
```

---

## 2. GitOps validation (ArgoCD)

Here's the real, complete bootstrap sequence, in order. Most of this is
a one-time, manual procedure - GitOps takes over from Section 2.6
onward.

### 2.1 - Confirm every `REPLACE_WITH_TERRAFORM_OUTPUT` placeholder is populated

Every chart's `values.yaml` (`charts/aduke/values.yaml`,
`charts/worker/values.yaml`) and `gitops/apps/velero.yaml` need real
values, not literal placeholder strings - ArgoCD deploys *exactly* what's
committed, so a placeholder left in place means a cluster full of broken
pods referencing a registry and vault that don't exist.

**This is now fully automated as part of CI, not a manual step you need
to remember.** `.github/workflows/terraform.yml`'s `apply` job runs, in
order, right after `terraform apply` succeeds: `revert-values.sh` (resets
everything to a known placeholder state - genuinely necessary, not just
cautious, since `gitops/apps/velero.yaml`'s `sed`-based matching only
works correctly starting from placeholders, not stale values from a
prior run), then `populate-values.sh` (writes every real
`terraform output` value into the correct field), then opens a **pull
request** with the result - it never pushes directly to `main`.

**So the actual validation step here is simply:**

1. Confirm the CI-opened PR exists (titled `chore: populate values.yaml
   from terraform output`)
2. Review the diff - every `REPLACE_WITH_TERRAFORM_OUTPUT` should be gone,
   replaced with real values
3. Merge it

**Manual fallback**, only needed if running `apply` locally from the
jumpbox (Section 0.1) rather than through CI:
```bash
./scripts/revert-values.sh   # first - see reasoning above
./scripts/populate-values.sh
```
Review the diff, then `git add`/`commit`/`push` yourself, or open a PR
by hand - the script never commits on your own behalf either way.

### 2.2 - Set GitHub repository secrets and variables

**A vague version of this step is exactly how `ACR_LOGIN_SERVER` got
missed once already**, producing `invalid tag "/worker:<sha>"` - an
empty variable, not a code bug. Every one of these, by exact name,
before continuing:

**Secrets** (Settings → Secrets and variables → Actions → Secrets tab):

| Name | Where the value comes from |
|---|---|
| `AZURE_CLIENT_ID` | Prerequisites - `$APP_ID` |
| `AZURE_TENANT_ID` | Prerequisites - `az account show --query tenantId -o tsv` |
| `AZURE_SUBSCRIPTION_ID` | Your single subscription ID - this project no longer splits across Platform/Production |
| `AKS_ADMIN_GROUP_OBJECT_IDS` | `["<your-admin-group-object-id>"]` - full list syntax, brackets and quotes included (a real, separate gotcha - see below) |
| `JUMPBOX_SSH_PUBLIC_KEY` | Contents of your public key file, e.g. `cat ~/.ssh/id_ed25519.pub` |

**Variables** (same page, Variables tab):

| Name | Where the value comes from |
|---|---|
| `ACR_NAME` | `terraform output -raw registry_name` |
| `ACR_LOGIN_SERVER` | `terraform output -raw registry_login_server` |
| `KEY_VAULT_NAME` | `terraform output -raw key_vault_name` |
| `STORAGE_ACCOUNT_NAME` | `terraform output -raw storage_account_name` |
| `JUMPBOX_ALLOWED_SSH_SOURCE_IP` | Your own current public IP/CIDR (`curl -s ifconfig.me`) - the actual access control replacing Bastion. Update this and re-`apply` if your IP ever changes |

**On `AKS_ADMIN_GROUP_OBJECT_IDS` specifically** - this is a real, separate
gotcha this project already hit once: since it's a `list(string)`
variable, the secret's *value itself* needs to be the full list literal
as text, brackets and quotes included (`["00000000-..."]`), not a bare
GUID - otherwise Terraform fails with "Extra characters after
expression."

### 2.3 - Commit and push the repo

```bash
git add .
git commit -m "chore: fill in real Terraform outputs for GitOps bootstrap"
git push origin main
```

This is the point where `repoURL` in every `Application` manifest
actually needs to resolve to a real, reachable repo - if this is still
pointing at a placeholder URL from earlier in this project's build,
fix that now too.

### 2.4 - Install ArgoCD itself

This is the one step in the entire GitOps flow that isn't managed by
Git at all - ArgoCD has to exist before it can manage anything.

**A real, recurring gotcha worth handling first, on any machine/session
where `kubectl`/`helm` haven't been used against this cluster yet.**
Without a configured kubeconfig, `kubectl`/`helm` fall back to a
hardcoded `localhost:8080` and fail with `connection refused` - not a
network problem, `kubectl` simply doesn't know the cluster exists yet
in this session:

```bash
az aks get-credentials --resource-group rg-aks-app --name aks-production
```

**This cluster uses Azure AD-integrated RBAC**, which then commonly
produces a second, separate error: `The kubeconfig uses devicecode
authentication which requires kubelogin`. Fix it in the same step:

```bash
kubelogin convert-kubeconfig -l azurecli
```

**If `kubelogin: command not found`** - install both together (`sudo`
is required, since it writes into `/usr/local/bin`):
```bash
sudo az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin
```

Confirm before continuing:
```bash
kubectl get nodes
```

**This setup is scoped to the specific machine/session you're on** - it
isn't something that persists across a fresh SSH connection to the
jumpbox. Expect to repeat this once per new session, not just once for
the whole project.

Once `kubectl get nodes` succeeds:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace
```

```bash
kubectl get pods -n argocd
```
**Expected:** all pods `Running` within a few minutes.

### 2.5 - Apply the App-of-Apps root manifest

The last manual `kubectl apply` in this entire project - everything
after this point is genuinely automated.

**A real, easy-to-miss prerequisite: this file only exists inside your
own repo, and a fresh jumpbox has nothing cloned onto it by default.**
Clone it first if you haven't already, on this specific jumpbox
session:

```bash
git clone https://github.com/GreatOmotayo/azure-aks-container-platform.git
cd azure-aks-container-platform
```

```bash
kubectl apply -f gitops/root-app.yaml
```

### 2.6 - Bootstrap succeeded
```bash
kubectl get pods -n argocd
```
**Expected:** all ArgoCD pods `Running`.

### 2.7 - root-app created all four children automatically
```bash
kubectl get applications -n argocd
```
**Expected:** `root-app`, `ingress-nginx`, `aduke`, `worker`, `velero` - five Applications total, none manually applied except `root-app` itself.

### 2.8 - Every Application is Synced and Healthy
```bash
kubectl get applications -n argocd -o wide
```
**Expected:** every row shows `Synced` + `Healthy`.

### 2.9 - selfHeal actually works (don't just trust the flag)
```bash
kubectl scale deployment aduke -n app --replicas=1
# wait ~1-2 min for ArgoCD's next reconciliation
kubectl get deployment aduke -n app
```
**Expected:** replica count reverts back to whatever's in `values.yaml`/HPA control, without you doing anything - this proves Git is genuinely authoritative, not just a deploy-once tool.

---

## 3. Application smoke test

### 3.1 - Submit a job

**The `Host` header is required, not optional** - `aduke.local` isn't a
real, publicly-registered domain, so NGINX has nothing to route on
without it; a request missing this header simply hangs, confirmed via
real debugging. The app also expects a JSON body, even if empty.

```bash
curl -X POST -H "Host: aduke.local" -H "Content-Type: application/json" -d '{}' http://<ingress-public-ip-or-hostname>/jobs
```
**Expected:** `202` with a `jobId` in the response body.

### 3.2 - Confirm it completes

**Same `Host` header requirement applies here too** - NGINX's routing
depends on it for every request, `GET` included, not just `POST`.

```bash
curl -H "Host: aduke.local" http://<ingress-public-ip-or-hostname>/jobs/<jobId-from-3.1>
```
Run this a few times over ~30 seconds.
**Expected:** `status` transitions from `queued` to `done`, with a `result` field populated.

---

## 4. NetworkPolicy validation

Full procedure already written in `docs/networkpolicy-validation.md` - run all 7 tests there now. Screenshot markers are already embedded in that document; capture each one as you go, particularly:

---

## 5. HPA + Cluster Autoscaler + load test

### 5.1 - Baseline, before load
```bash
kubectl get hpa -n app
kubectl get nodes
```

### 5.2 - Run the load test
From the jumpbox (or your own machine now that Ingress is public):
```bash
k6 run --env TARGET_HOST=http://<ingress-host> k6/load-test.js
```
While this runs (in a second terminal):
```bash
watch kubectl get hpa,nodes -n app
```

### 5.3 - Final k6 summary

### 5.4 - Confirm scale-down actually happens
```bash
watch kubectl get hpa,nodes -n app
```
Keep watching through the load test's final low-sustain stage (~5 more minutes after k6 exits).

---

## 6. Resilience / chaos testing

Run `chaos/pod-kill-test.sh` and `chaos/node-cordon-test.sh` in full - both scripts already print PASS criteria at each step.

---

## 7. Velero backup validation

### 7.0 - If Velero never becomes healthy at all, read this first

**A genuinely deep, multi-layered incident hit exactly once so far -
worth checking each layer in order if `velero` sits `OutOfSync`/
`Missing` for more than a few minutes, rather than assuming a simple
timing issue:**

1. **A real, external image brownout - not a bug in this project.**
   The chart auto-computes `bitnami/kubectl:<cluster-k8s-version>` for
   its CRD-upgrade hook - Bitnami removed most versioned tags from that
   free namespace in 2025, so this tag frequently doesn't exist anymore.
   Confirm via `kubectl describe pod -n velero -l
   job-name=velero-upgrade-crds | grep Image:` - if it shows
   `bitnami/kubectl` (not `bitnamilegacy`), the fix is already in
   `gitops/apps/velero.yaml`'s `kubectl.image` override; confirm it's
   actually been pushed and merged.
2. **App-of-Apps propagation lag.** This file is watched by `root-app`,
   not by `velero` directly - a values change doesn't reach `velero`'s
   own spec until `root-app` itself syncs. Check with: `kubectl get
   application velero -n argocd -o jsonpath='{.spec.source.helm.values}'
   | grep -A3 kubectl` - if this doesn't show the corrected image, sync
   `root-app` first: `kubectl patch application root-app -n argocd
   --type merge -p '{"operation":{"sync":{}}}'`.
3. **A stale repo-server render cache.** Test the exact same override
   with plain Helm, completely bypassing ArgoCD: `helm template
   test-velero vmware-tanzu/velero --version 8.1.0 --set
   kubectl.image.repository=docker.io/bitnamilegacy/kubectl --set
   kubectl.image.tag=1.33.4 | grep -A2 kubectl:` - if this renders
   correctly but the actual cluster still shows the old image, restart
   `argocd-repo-server`: `kubectl rollout restart deployment
   argocd-repo-server -n argocd`.
4. **A sync operation stuck indefinitely, ignoring every fix
   underneath it.** Check `kubectl describe application velero -n
   argocd` for `Operation State: Started At` - if this timestamp is old
   (hours, not minutes) and every manual sync reports "(no change),"
   ArgoCD is still retrying its *original* operation, not a fresh one.
   Remove it directly: `kubectl patch application velero -n argocd
   --type json -p '[{"op": "remove", "path": "/operation"}]'`.
5. **A Kubernetes finalizer stuck on the hook Job.** Confirm with
   `kubectl get job velero-upgrade-crds -n velero -o
   jsonpath='{.metadata.finalizers}'` - if `argocd.argoproj.io/hook-
   finalizer` shows up alongside a populated `deletionTimestamp`, a
   plain `kubectl delete` will report success without actually removing
   the object (confirm via an unchanged `metadata.uid`). Clear it
   directly: `kubectl patch job velero-upgrade-crds -n velero -p
   '{"metadata":{"finalizers":[]}}' --type=merge`, then also restart
   `argocd-application-controller` - the component that actually owns
   finalizer release, distinct from the repo-server above.
6. **`velero backup-location get` shows `PHASE: Unavailable` and
   `BUCKET/PREFIX: null`.** A genuinely different, separate problem
   from the sync issues above - this means `gitops/apps/velero.yaml`'s
   `bucket` value is still a placeholder, or was populated as the
   literal string `"null"`. The second case happens if
   `scripts/populate-values.sh` ran while the root `outputs.tf`'s
   `velero_backup_container_name` output didn't yet exist in state
   (`jq -r` prints the literal text `null` for a genuinely null JSON
   value, not an empty string). Confirm the output actually exists
   first: `terraform output -raw velero_backup_container_name` - if
   this errors with "Output not found," the output block itself may
   have been accidentally commented out, or no fully successful
   `apply` has run since it was added. Once confirmed real, `sed`-based
   substitution only matches the *original* placeholder text, not an
   already-wrong value - revert before re-populating:
   `./scripts/revert-values.sh && ./scripts/populate-values.sh`.

See `docs/DECISIONS.md` Part 2 for the full account of how each of
these was actually found and confirmed, not just guessed.

### 7.1 - Confirm Velero is healthy
```bash
kubectl get pods -n velero
velero backup-location get
```
**Expected:** the `default` BackupStorageLocation shows `Available`.

### 7.2 - Take a real backup
```bash
velero backup create smoke-test-backup --include-namespaces app
velero backup describe smoke-test-backup --details
```
**Expected:** `Phase: Completed`.

### 7.3 - Confirm the backup actually landed in Blob Storage
```bash
az storage blob list --account-name <storage_account_name> --container-name velero-backups --auth-mode login -o table
```

### 7.4 - (Optional, more convincing) - an actual restore test
```bash
kubectl delete deployment aduke -n app
velero restore create --from-backup smoke-test-backup
kubectl get pods -n app -w
```

**Note:** if you run 7.4, ArgoCD's `selfHeal` will likely also try to recreate the deleted Deployment on its own reconciliation cycle - worth doing this test with ArgoCD's `aduke` Application temporarily paused (`argocd app set aduke --sync-policy none`), so the restore, not ArgoCD, is what's actually being tested.

---

## 8. Image scanning validation (Trivy)

Previously a known gap in this document - the original project spec
called for image scanning before deployment, but it was never actually
built into `build-and-push.yml` until now. This section replaces that
gap with a real validation procedure.

### 8.1 - Confirm the scan step actually runs and gates the push

Push a small, harmless change to `apps/aduke/**` or `apps/worker/**` to
trigger the workflow, then watch the Actions run in GitHub.

**Expected:** the run shows five steps in order - `Build image`, `Scan
image for vulnerabilities (Trivy)`, `Push image`, `Update chart's image
tag` (plus the earlier checkout/login steps) - and the scan step
completes *before* the push step starts, not in parallel.

### 8.2 - Confirm a real HIGH/CRITICAL finding actually blocks the push

This is the test that actually proves the gate works, not just that the
step exists. The cleanest way to trigger this deliberately: temporarily
change the base image in one Dockerfile to an old, known-vulnerable tag
(e.g. `node:18.0.0-alpine` instead of `node:20-alpine`), push it, then
revert once you've captured the result.

**Expected:** the `Scan image for vulnerabilities` step fails
(`exit-code: '1'` on any HIGH/CRITICAL finding), the workflow run shows
red/failed, and - critically - the `Push image` step never runs at all
(shown as skipped, not failed).

Revert the Dockerfile change and confirm a normal push succeeds cleanly
afterward.

---

## 9. CI/CD failure runbook: state drift after a broken `apply`

This section is different from everything above it - it's not a step to
run once during setup, it's a **reference procedure** for a real failure
mode this project's own deployment repeatedly hit. Worth documenting
properly rather than treating as tribal knowledge, since `terraform.yml`'s
apply job is fully unattended (`terraform apply -auto-approve`) and will
hit this identically in CI, not just during manual runs.

### 9.1 - Recognize the failure signature

Two distinct error shapes, both meaning the same underlying thing -
**Azure has a resource that Terraform's state doesn't know about**:

- `Error: a resource with the ID "..." already exists - to be imported into the State`
- `Error: ... unexpected status 409 (409 Conflict) with error: RoleAssignmentExists: ...`

**Why this happens, and why it's not a code bug:** Terraform only writes
a newly-created resource into its state file *after* the overall `apply`
completes successfully. If a run creates a real resource in Azure but
then fails on a *later*, unrelated resource, that earlier resource exists
in Azure with no matching entry in state - a genuine split-brain, not a
mistake anyone made.

### 9.2 - Do NOT just re-run the pipeline

Re-triggering `terraform apply` without fixing the drift first hits the
**identical** conflict again, every time - re-running changes nothing
about the fact that Azure has something Terraform doesn't know about. A
failed CI run of this shape needs a human to intervene once, manually,
before any re-run can succeed.

### 9.3 - The recovery procedure

Connect to the jumpbox (Section 0.1), then:

```bash
cd aks-platform

# The error message itself contains everything needed - the exact
# resource address (e.g. module.jumpbox.azurerm_virtual_machine_extension.aad_login)
# and the exact resource ID to import.
terraform import '<resource address from the error>' '<resource ID from the error>'
```

**One extra step, specific to a VM extension that was created but whose
install script then failed** (like `AADSSHLoginForLinux` hitting a
connectivity error): importing alone tells Terraform the resource
*exists*, but not that it needs to be *retried*. Since nothing in the
extension's own configuration changed, Terraform has no reason to touch
it again on its own:

```bash
terraform apply -replace="<resource address>"
```

`-replace` forces a destroy-and-recreate of that one specific resource
even with unchanged config - the only way to force a genuine retry of a
previously-failed extension install, now that the actual root cause
(the Firewall connectivity gap) is fixed.

### 9.4 - Confirm recovery, then re-trigger CI normally

```bash
terraform plan
```
**Expected:** no remaining drift for the imported resource - it should
show as already up to date, not proposed for creation.

### 9.5 - Worth considering, not yet implemented: a manual approval gate

`terraform.yml` currently applies straight to `main` with no human review
of the plan first - only the `plan` job runs on pull requests. Adding a
GitHub Environment protection rule (requiring a specific reviewer to
approve the `apply` job before it proceeds) would let a human catch a
likely conflict by reading the plan, before it becomes a failed run at
all. Flagged here as a real, honest gap - not yet built into this
project's actual pipeline.

### 9.6 - When Terraform's state itself is wrong, not just behind

Every case above assumes Terraform's state is *incomplete* (missing a
resource that's really there). A rarer, more serious variant: state
claims a resource exists and is correct, when the real object in Azure
either doesn't exist or belongs to something else entirely - confirmed
once, when two role assignments (`aduke_table` and `worker_table`)
independently caused `AuthorizationPermissionMismatch` errors while both
apps' own Terraform code was already correct, and `terraform state show`
reported both as fine.

**The only way this was actually caught: querying Azure directly,
bypassing Terraform's state entirely.**

```bash
az role assignment list --assignee <principal-id> --scope <resource-id> -o table
```

If a role you know should be there is missing from this real, live list
- despite `terraform state show` insisting it exists - state and reality
have diverged, most likely from two resources having been imported
against the same real Azure object at some point. Fix with the same
`state rm` + fresh `apply` pattern as Section 9.3, but confirm the result
against this same `az role assignment list` command afterward, not just
against `terraform plan` showing no changes - a clean plan only proves
state agrees with itself, not that it agrees with Azure.

