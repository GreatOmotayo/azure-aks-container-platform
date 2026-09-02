# Master Validation Plan

This is the single consolidated testing procedure across every phase of
this project. Run top to bottom, in order - later sections assume earlier
ones passed.

Run all `kubectl`/`az` commands from the Bastion jumpbox unless a step
says otherwise.

---

## Prerequisites

Nothing in Section 0 onward can run at all until this exists - every
workflow (`terraform.yml`, `bootstrap.yml`, `build-and-push.yml`)
authenticates to Azure via OIDC, which requires a real Microsoft Entra
Application, a Service Principal, and federated credentials trusting
GitHub's OIDC issuer for this specific repo. One-time, manual, done from
your own machine (or Cloud Shell) with `az login` as yourself.

### Create the App Registration and Service Principal

```bash
az ad app create --display-name "aks-container-platform-github-actions"
APP_ID=$(az ad app list --display-name "aks-container-platform-github-actions" --query "[0].appId" -o tsv)
az ad sp create --id "$APP_ID"
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
```

### Three federated credentials - not one

**A real, non-obvious detail worth getting right the first time:** the
`apply` jobs in `terraform.yml` and `bootstrap.yml` both declare
`environment: production` - which changes the OIDC subject claim GitHub
issues for those specific jobs, compared to jobs with no environment
declared. One federated credential covering only the "push to main"
case leaves the `plan` jobs (triggered on `pull_request`) and the
`apply` jobs (using the `environment` claim) both unable to
authenticate - each needs its own.

```bash
# For the `plan` jobs (terraform.yml, bootstrap.yml) - pull_request, no environment
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "github-pull-request",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:GreatOmotayo/azure-aks-container-platform:pull_request",
  "audiences": ["api://AzureADTokenExchange"]
}'

# For the `apply` jobs (terraform.yml, bootstrap.yml) - environment: production
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

### RBAC on both subscriptions - Contributor alone is not enough

This project's Terraform creates dozens of `azurerm_role_assignment`
resources throughout (Workload Identity credentials, ACR push, Key
Vault/Storage RBAC, AKS admin, jumpbox AAD login) - `Contributor`
explicitly cannot create new role assignments. `User Access
Administrator` is required too, on both subscriptions:

```bash
for SUB in "$PRODUCTION_SUBSCRIPTION_ID" "$PLATFORM_SUBSCRIPTION_ID"; do
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "Contributor" --scope "/subscriptions/$SUB"
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope "/subscriptions/$SUB"
done
```

### GitHub repository secrets

```bash
echo "AZURE_CLIENT_ID=$APP_ID"
echo "AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)"
```
Add these, plus `AZURE_PRODUCTION_SUBSCRIPTION_ID` and
`AZURE_PLATFORM_SUBSCRIPTION_ID`, in **Settings → Secrets and variables
→ Actions** before anything in Section 0 onward is attempted via CI.

---

## 0. Bootstrap and initial access

### 0.1 - Apply bootstrap/ first

```bash
cd bootstrap
terraform apply
```
This has no dependency on the self-hosted runner at all, since every
resource it creates is management-plane - exactly why it can run from
anywhere, including a genuinely fresh environment with nothing else
built yet.

The jumpbox and runner now exist. Both sit in the hub's shared-services
subnet, reachable only through Bastion - but they use **different
authentication methods**, since only the jumpbox got the AAD login
extension (`modules/jumpbox`'s `azurerm_virtual_machine_extension.aad_login`).
The runner (`modules/github-runner`) was never given that extension, so
it's SSH-key-only.

### 0.2 - Connect to the jumpbox (AAD-based - the method used throughout this document)

```bash
az network bastion ssh \
  --name <bastion-name> \
  --resource-group rg-hub-network \
  --target-resource-id $(az vm show -g rg-hub-network -n vm-jumpbox-production --query id -o tsv) \
  --auth-type AAD
```

This authenticates using **your own logged-in Entra identity** - it only
works if you're a member of the admin group granted `Virtual Machine
Administrator Login` on this VM (`modules/jumpbox`'s
`jumpbox_aad_login` role assignment). No SSH key is involved in this path
at all - this is the intended, day-to-day access method; the SSH key
baked into the VM is a break-glass fallback only, per the design decision
made when this module was built.

**Every step in this document that says "run from the jumpbox" means
this connection.**

### 0.3 - Connect to the runner VM (SSH-key-based - different from the jumpbox)

The runner has no AAD login extension, so it needs Bastion's tunnel mode
plus your actual SSH private key (the one whose public half is in
`bootstrap/terraform.tfvars`'s `ssh_public_key` - this moved here during
the bootstrap/aks-platform restructuring, see DECISIONS.md Part 2).

**Terminal 1 - open the tunnel:**
```bash
az network bastion tunnel \
  --name <bastion-name> \
  --resource-group rg-hub-network \
  --target-resource-id $(az vm show -g rg-hub-network -n vm-gha-runner-production --query id -o tsv) \
  --resource-port 22 \
  --port 2222
```
Leave this running - it stays open, forwarding local port 2222 through
Bastion to the runner's SSH port.

**Terminal 2 - actually connect, through that tunnel:**
```bash
ssh -i ~/.ssh/<your-private-key> azureuser@127.0.0.1 -p 2222
```

**Needed for registering the runner (0.4 next), and later for the
Section 8.3 troubleshooting step** - this is the only way to reach the
runner directly, for either purpose.

### 0.4 - Register the runner

The runner VM exists, but it isn't yet a real GitHub Actions runner
until you register it against this repo - connect directly to the
runner VM using the SSH-key method in **0.3** above (not the jumpbox -
the runner needs its own connection).

In GitHub: **Settings → Actions → Runners → New self-hosted runner**,
copy the generated `./config.sh --url ... --token ...` command, then on
the runner VM (once connected via 0.3):

```bash
mkdir actions-runner && cd actions-runner
# paste the download + config.sh commands GitHub's UI gave you
./svc.sh install
./svc.sh start
```

Confirm it shows **Idle** in GitHub's Runners list before moving on -
**only past this point can `aks-platform/`'s own CI (`terraform.yml`)
actually run**, since that workflow requires this exact runner to
already exist and be listening.

---

## 1. Infrastructure validation (Terraform)

### 1.1 - Apply aks-platform/ (the main project)

```bash
cd aks-platform
terraform apply
```
This can now run either manually from the jumpbox, or via CI - the
runner it depends on genuinely exists at this point.

### 1.2 - Private cluster has no public endpoint
```bash
az aks show -g rg-production-network -n aks-production --query "apiServerAccessProfile"
az aks show -g rg-production-network -n aks-production --query "privateFqdn" -o tsv
```
**Expected:** `enablePrivateCluster: true`, a real private FQDN returned.

### 1.3 - DNS resolution works from the jumpbox
```bash
nslookup <private_fqdn_from_1.2>
```

### 1.4 - All private endpoints are Approved
```bash
az network private-endpoint list -g rg-aks-app -o table
```
**Expected:** 5 endpoints (Key Vault, ACR, Storage Queue, Storage Table, Storage Blob), all showing `Succeeded`/`Approved` connection state.

### 1.5 - Firewall rule collection groups landed correctly
```bash
az network firewall policy rule-collection-group list --policy-name <firewall-policy-name> -g rg-hub-network -o table
```
**Expected:** `rcg-aks-production` (from `aks-platform/`) and
`rcg-shared-services-egress` (from `bootstrap/`), both present - the
same underlying Firewall Policy, populated by two separate applies.

### 1.6 - Confirm the storage sub-resources and Key Vault secret exist

The Storage queue/table/container and the Key Vault secret are all
created directly by Terraform (see `modules/storage/main.tf` and root
`main.tf`'s `azurerm_key_vault_secret` resource) - these are data-plane
operations against resources with `public_network_access_enabled =
false`, so `terraform apply` must run from inside the VNet: always from
the jumpbox (Section 0.2), or via CI, never from your own laptop.

This check simply confirms `apply` actually created all four:

```bash
STORAGE_ACCOUNT=$(terraform output -raw storage_account_name)
VAULT_NAME=$(terraform output -raw key_vault_name)

az storage queue exists --name jobs --account-name "$STORAGE_ACCOUNT" --auth-mode login
az storage table list --account-name "$STORAGE_ACCOUNT" --auth-mode login -o table
az storage container exists --name velero-backups --account-name "$STORAGE_ACCOUNT" --auth-mode login
az keyvault secret show --vault-name "$VAULT_NAME" --name storage-account-name --query value -o tsv
```

**Expected:** all four confirm existence - `terraform apply` already
created them; this step is verifying that, not performing it.

**If any of these come back missing**, despite a successful `apply`: check
which identity actually ran `apply` (CI's self-hosted runner, or a human
from the jumpbox) - if it was run from anywhere outside the VNet, that's
the likely cause, and re-running from the jumpbox or via CI should
resolve it.

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
jumpbox (Section 0.2) rather than through CI:
```bash
./scripts/revert-values.sh   # first - see reasoning above
./scripts/populate-values.sh
```
Review the diff, then `git add`/`commit`/`push` yourself, or open a PR
by hand - the script never commits on your own behalf either way.

### 2.2 - Set GitHub repository secrets and variables

`build-and-push.yml` references `vars.ACR_NAME` and `vars.ACR_LOGIN_SERVER`;
`terraform.yml` and `bootstrap.yml` reference several `secrets.*` and
`vars.*` entries each. In GitHub: **Settings → Secrets and variables →
Actions**, add each one using the real values from `terraform output`
(both `bootstrap/` and `aks-platform/`) and your Entra ID setup
(subscription IDs, the admin group's object ID, the SSH public key, ACR
name/login server).

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
```bash
curl -X POST http://<ingress-public-ip-or-hostname>/jobs
```
**Expected:** `202` with a `jobId` in the response body.

### 3.2 - Confirm it completes
```bash
curl http://<ingress-public-ip-or-hostname>/jobs/<jobId-from-3.1>
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

### 8.3 - A real, still-open dependency this surfaced: Trivy's DB download

Trivy downloads its vulnerability database on first run (typically from
`ghcr.io`) - this is a NEW outbound dependency for the self-hosted
runner that wasn't accounted for when `modules/firewall-rules`'
shared-services rule collection was built. If 8.1 fails with a
connectivity-looking error (not a scan finding), this is the likely
cause.

```bash
# Connect to the runner directly using Section 0.3's SSH-tunnel method
# (not the jumpbox - this needs to run FROM the runner itself)
curl -v https://ghcr.io
```

**If this is blocked:** add `ghcr.io` to the `github-actions-runner` rule
in `modules/firewall-rules/main.tf`'s shared-services collection, same
pattern as every other outbound dependency this project has already
caught and fixed.

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

Connect to the jumpbox (Section 0.2), then:

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