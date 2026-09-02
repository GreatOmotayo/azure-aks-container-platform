# DECISIONS.md

A living log of the real decisions, trade-offs, and corrections made
across this project - written honestly, including the mistakes. Corrections
are appended, never deleted or silently fixed without a record.

---

## Part 1: Architecture Decisions

### Phase 1 - Core cluster design

| # | Decision | Chosen | Alternatives considered |
|---|---|---|---|
| 1 | Network model | Azure CNI Overlay | Flat Azure CNI (would've forced a much larger subnet reservation) |
| 2 | Node pools | System + User, separated by taint | Single mixed pool |
| 3 | Ingress controller | Self-managed NGINX via Helm | AKS Application Routing add-on (mid-deprecation as of 2026), AGIC (superseded by Application Gateway for Containers) |
| 4 | HPA metric | CPU-based, both Aduke and worker | KEDA/queue-depth (documented as the theoretically better fit for the worker specifically, deferred as future work) |
| 5 | Job status store | Azure Table Storage | New Postgres/Cosmos instance (unnecessary overkill for `{jobId, status, result}`) |
| 6 | Pod-to-Azure auth | Workload Identity (OIDC federation) | AAD Pod Identity (deprecated), stored SP credentials |
| 7 | `kubectl` access control | Entra ID RBAC, `local_account_disabled = true` | Static admin kubeconfig |
| 8 | Cluster access path | Bastion (human) + Private Endpoint path for CI/CD | Bastion-only (would've blocked the GitHub Actions stretch goal) |
| 9 | App architecture | Reuse Aduke, add one purpose-built worker | A larger multi-service demo app (Sock Shop, Online Boutique) - rejected as disproportionate complexity for what needs proving |
| 10 | Staging environment | Deliberately NOT built as a live cluster | A second live NonProd cluster - cost/value didn't justify it for a single-operator, short-lived test project. Naming stays environment-aware (`var.environment`) so promotion later is a config change, not a rewrite |
| 11 | 1M-user scale design | Documented capacity-planning target, not a live deployment; HPA/node-pool ceilings raised generously since ceilings cost nothing while unused | Actually running at that scale - rejected as financially and practically unnecessary for this project's real usage pattern |

### Phase 2 - Cluster identity & DNS

| Decision | Reasoning |
|---|---|
| Custom (BYO) private DNS zone, not AKS's "System" default | The "System" zone only auto-links to the cluster's own VNet - the Bastion jumpbox (in the hub) would never resolve the cluster's FQDN otherwise |
| `UserAssigned` cluster identity, not `SystemAssigned` | Solves a chicken-and-egg problem: a BYO-subnet, BYO-DNS-zone cluster needs its identity to already hold `Network Contributor`/`Private DNS Zone Contributor` *before* cluster creation finishes - impossible with a `SystemAssigned` identity that doesn't exist until creation is underway |
| Cilium as the CNI data plane | Azure NPM's retirement is real and dated, not just directional - confirmed against Microsoft's own current documentation: support for NPM on Linux nodes ends September 30, 2028. Cilium's eBPF enforcement is also what the later NetworkPolicy deny-and-verify testing actually exercises |

### Phase 3 - Cluster access, egress ownership, CI/CD split

| Decision | Reasoning |
|---|---|
| Jumpbox: AAD-based login (extension), SSH key as break-glass only | Consistent "access is a role assignment, not a credential" pattern used everywhere else in this project |
| Runner: SSH-key-only (no AAD extension) | Simpler for a machine identity that doesn't need interactive human login |
| Shared-services subnet egress (UDR forcing traffic through the Firewall) moved OUT of this project, into the network project | Genuinely a network-topology concern (subnet ownership), same as the network project's existing spoke UDRs - zero downside to this move, unlike the next decision |
| Firewall **rules** (FQDN allow-lists) kept IN this project, NOT moved to the network project | Real trade-off, considered and rejected: moving them would remove priority-collision risk, but would also break this project's independent change cadence - every new outbound dependency (Entra ID, GitHub, ghcr.io) would require modifying and reapplying the network project. Kept here deliberately - see Part 2 for how this decision later collided with a network-project-owned Firewall rule in a way neither project's own review would have caught alone |
| CI/CD split: GitHub Actions builds/pushes/updates Git tag; ArgoCD only ever syncs, never builds | Standard, correct GitOps boundary - CI and CD never do each other's job |
| Runner's cluster-admin RBAC (`aks_rbac_runner`) removed | Became dead privilege the moment ArgoCD (not the runner) took over deployment - a CI build machine holding cluster-admin it no longer used was exactly the privilege creep this project otherwise avoided |

### Phase 4 - ACR, Key Vault, Storage

| Decision | Reasoning |
|---|---|
| Key Vault: Private Endpoint, not public+Firewall-allowlist | The original public-endpoint decision was reconsidered and reversed after direct challenge - a public endpoint is reachable from the whole internet regardless of Firewall egress rules, which only govern outbound traffic. Rebuilt behind a real `azurerm_private_endpoint` |
| ACR: Premium SKU + Private Endpoint, not Standard+public | Premium is required for Private Link (a hard Azure limitation, not a Terraform choice) - upgrade cost is negligible given this project's short-lived (3-4hr) test window, which was the deciding factor once made explicit |
| Storage: Queue Sender/Processor split, not one shared Contributor role | Aduke only ever sends messages; the worker only ever processes them. Confirmed as genuinely separate built-in Azure roles before using them |
| Storage: `shared_access_key_enabled = false` | Removes the static account key entirely - forces every client through Workload Identity, no fallback credential exists to leak |
| Storage/Key Vault data-plane resources (queue, table, container, secret): created via Terraform | Reversed twice during actual deployment - see Part 2 for the full account of why this briefly moved to manual creation and why it was restored |
| Velero: dedicated blob container in the existing Storage Account, not a new account | Sufficient isolation for this project's scope; avoids a whole additional account to secure |
| Velero: container-level RBAC scope (not whole-account) | The final, settled state after a real ordering problem forced a temporary broadening - see Part 2 |

### GitOps structure

| Decision | Reasoning |
|---|---|
| App-of-Apps, not two flat Applications | Chosen specifically to demonstrate the scalable pattern, even though two flat Applications would have sufficed for this project's actual size |
| ArgoCD scope: everything, including ingress-nginx | A fully consistent GitOps story - nothing running in the cluster exists outside Git's authority |
| `root-app.yaml` placed one directory above what it watches (`gitops/apps/`) | Avoids a self-reference problem - if the root Application lived inside the directory it manages, ArgoCD would be unclear whether it's the manager or one of the managed things |
| Aduke's Ingress: public, not internal | **Reversed a unilateral earlier decision.** Initially forced an internal Azure LB, reasoning "no public IP anywhere" should apply cluster-wide. Directly challenged and corrected: zero-trust means the control plane and backend PaaS services have no public exposure - it does not mean the actual product surface can't be public. Corrected to match how real zero-trust architectures actually work |
| CI never pushes directly to `main` - both `build-and-push.yml`'s tag bump and `terraform.yml`'s values-population open a pull request instead | An earlier version of both workflows committed straight to `main`, unreviewed. Genuinely reconsidered as unacceptable for anything beyond a personal demo - now requires at least one approval before either automated change reaches the branch ArgoCD watches |

---

## Part 2: Deployment-time decisions and corrections

Everything below was found and fixed while actually running this
project's Terraform against real Azure subscriptions - not caught by
design review, caught by real errors. Kept as its own section because
the *pattern* across these is worth more than any single fix: several of
these were only found because an earlier, unrelated mistake forced a
closer, more skeptical look at something nearby.

### The Firewall rule evaluation order - the most significant finding in this project

A real, sustained connectivity failure (the jumpbox's AAD login
extension, then a node pool's own bootstrap script, both failing to
reach already-allow-listed hosts like `login.microsoftonline.com`) was
eventually traced - through a systematic process of ruling out the NSG,
the route table, and the Firewall's own IP, in that order - to a single
root cause: **Azure Firewall evaluates every network rule across every
rule collection group in a policy before it evaluates a single
application rule, regardless of each rule's own priority number.** The
network project's own Firewall Policy carried a pre-existing network-rule
deny-all (`rcg-baseline-deny`, priority 65000) that silently caught all
outbound traffic before this project's carefully-built FQDN allow-lists
- entirely application rules - were ever reached.

**The fix:** a `network_rule_collection` added to this project's own
rule collection groups, using Azure Service Tags where possible (no DNS
Proxy dependency) and a scoped fallback for non-Microsoft destinations.

**The honest cost, stated plainly rather than glossed over:** once a
network rule allows traffic, Firewall processing stops for that packet -
every FQDN-specific application rule this project built is no longer the
actual enforcement mechanism. They remain in the codebase as documentation
of intent, not as active security controls. This is a real, meaningful
loss of precision, not a clean win.

### OS disk type: Ephemeral reverted to Managed

`Standard_D2s_v5` (the original node pool VM size) has no local temp
disk at all, which Ephemeral OS disks strictly require - only `d`-variant
sizes do. Rather than hand-tune a specific size and disk size to fit a
temp-disk capacity exactly (fragile, breaks again the next time the VM
size changes), both node pools moved to `Managed` OS disks, which work
with any VM size. The original reasoning for Ephemeral (no persisted
network disk needed) still holds; only the mechanism changed.

### VM sizing, driven entirely by real subscription quota

- Node pools moved from `Standard_D2s_v5`/`Standard_D4s_v5` to
  `Standard_E2bds_v5` after a real quota check showed the Dsv5 family at
  a hard 0 vCPU limit in this subscription/region - not a capacity issue,
  a genuine ceiling.
- The user node pool's `max_count` was reduced from 5 to 3 - system (4
  vCPU) + user at max (6 vCPU) uses the full 10 vCPU EBDSv5 quota exactly,
  with zero spare. This is a real subscription-tier constraint, not an
  architectural choice; a quota increase request would allow reverting
  to a higher ceiling.
- Jumpbox and runner moved from `Standard_B2s` (hit a genuine, transient
  capacity restriction - not quota, physical datacenter inventory) to
  `Standard_B2ms`, then finally to `Standard_D2s_v6` once a Portal quota
  check showed confirmed headroom in the newest available generation.
  The mid-point (`B2ms`) was already working when the final switch was
  made - the move to `D2s_v6` was a deliberate preference given
  confirmed quota, not a fix for an active problem.
- This tight quota ceiling had a real, non-obvious consequence: a routine
  Terraform change that forces a node pool VMSS *replace* (rather than
  an in-place update) briefly needs both the old and new VMSS to exist
  simultaneously - a genuine overlap-capacity requirement the original
  zero-slack quota design didn't account for. Surfaced as a real,
  repeatedly-retried stuck operation, resolved by requesting a real quota
  increase rather than trying to design around it further.

### The NTP Firewall rule - removed, because it was solving a problem that didn't exist

A network rule allowing UDP/123 to `ntp.ubuntu.com` failed with a real
Azure requirement: FQDN-based network rules require DNS Proxy enabled at
the Firewall Policy level, a network-project-owned, broad-blast-radius
setting not worth changing for one rule. Investigating this surfaced
something more useful than a workaround: modern Azure Linux VM images
sync time against the Azure host's own PTP hardware clock by default,
confirmed directly against Microsoft's own time-sync documentation - not
an external NTP server reached over the network at all. The rule was
removed entirely, not worked around.

### Cross-subscription provider aliasing for the jumpbox and runner

Both modules create resources in `rg-hub-network`, which lives in the
Platform subscription, not Production - but neither module was ever
given the Platform-aliased provider, meaning both silently used the
default (Production) provider and failed with `ResourceGroupNotFound`.
Fixed by remapping each module's entire default provider via a
`providers = { azurerm = azurerm.platform }` block - simpler than
aliasing individual resources, since every resource in both modules
belongs to Platform, not a mix.

### Tag policy compliance - two separate, real governance conflicts

- **Container Insights.** Enabling `oms_agent` on the cluster causes AKS
  to auto-create a companion `Microsoft.OperationsManagement/solutions`
  resource, blocked by the Landing Zone project's own tag-requiring
  policy (`baseline-platform`, requiring a `CostCenter` tag). Fixed by
  pre-creating that same Solution resource directly in this project's own
  Terraform, with the required tag already attached - avoiding a
  cross-project policy exemption entirely.
- **Node pool VMSS.** A separate policy assignment (`baseline-production`,
  same underlying tag requirement) blocked the auto-created VMSS behind
  the system node pool. Fixed by adding `tags` directly to the node
  pool block - confirmed against Microsoft's own documentation that
  node-pool-level tags propagate onto the pool's actual VMSS, the real,
  intended mechanism for this, not a workaround.
- `CostCenter` was added to this project's own default tag set as a
  result of the first finding, closing the same gap proactively for any
  other resource under the same management group scope.

### Storage/Key Vault data-plane resources - removed from Terraform, then restored

`shared_access_key_enabled = false` and `public_network_access_enabled =
false` together mean creating the Storage queue/table/container, and
writing the Key Vault secret's value, are data-plane operations requiring
network access to the private endpoint. Running `terraform apply` from
a personal machine outside the VNet hit this wall directly. These four
resources were initially moved to manual `az` CLI creation as a result.

**Reconsidered and reversed once the actual constraint was named
precisely:** the wall only applies to *where* `apply` runs from - this
project's CI pipeline runs on the self-hosted runner, which lives inside
the VNet by design and never hits it. All four resources were restored
to full Terraform management; the real, remaining rule is simply never
to run `apply` from a personal machine outside the network.

A related provider-level fix was required alongside this:
`storage_use_azuread = true` on the default provider, since
`shared_access_key_enabled = false` means the provider's own internal
reads must also use Azure AD rather than a (non-existent) account key -
plus dedicated Storage Queue/Table/Blob Data Contributor role
assignments for whichever identity runs `terraform apply`, since that
identity's own RBAC is separate from any application's Workload
Identity.

### Velero's role scope - broadened, then restored to its original, tighter form

Container-level RBAC scope requires the target container to already
exist at the moment the role assignment is created. When the backup
container briefly moved to manual creation (see above), this became a
genuine ordering problem - the role assignment ran during `apply`,
before the manually-created container existed - and the scope was
broadened to the whole Storage Account as a working fallback.

Once the container was restored to Terraform management within the same
`apply`, that ordering problem no longer existed, and the scope was
narrowed back to the specific container - Terraform's own dependency
graph (referencing the container's real output value) now guarantees
correct ordering without any additional work.

### Values-file automation, and a real bug caught before it shipped

Scripts were built to replace manual copy-paste of Terraform outputs
into each chart's `values.yaml` and `gitops/apps/velero.yaml`. The
`velero.yaml` portion uses targeted text substitution rather than a
YAML-aware tool, since its real values sit inside an embedded Helm
values string, not real YAML structure - and an early version of that
substitution matched against a comment that did not actually exist in
the real file, silently matching nothing. Corrected to match by key
name instead, which is also more robust generally, since key names are
functionally required and far less likely to drift than a comment.

A second, genuine correctness issue was caught before it caused a
problem in practice: the same substitution only matches a known
placeholder string, meaning a second population run - after
infrastructure has been destroyed and recreated, producing genuinely
new values - would silently fail to update `velero.yaml` at all, leaving
stale identity data in place. Fixed by running the reverse (reset-to-
placeholder) script first, unconditionally, before every population run,
guaranteeing a known starting state regardless of history.

### State drift from interrupted applies - a recurring, expected pattern

Several resources (a storage role assignment, the jumpbox's AAD login
extension, the AKS cluster resource itself) were each, at different
points, successfully created in Azure by an `apply` run that then failed
on a later, unrelated resource - meaning Terraform's state file never
recorded the earlier success. Each case produced the identical class of
error (`already exists - needs import`, or `RoleAssignmentExists`) and
was resolved the same way: `terraform import` using the exact resource
ID the error itself provides, followed - specifically for the VM
extension case - by `terraform apply -replace` to force a genuine retry
of a previously-failed install, now that its underlying cause (the
Firewall finding above) was fixed. This is now documented as a standing
runbook procedure, since the CI pipeline will hit this identically to a
manual run.

### Jumpbox and runner live in a separate Terraform root - solving a genuine chicken-and-egg problem

This project's own CI (`.github/workflows/terraform.yml`) runs on the
self-hosted runner, since its data-plane operations (the Storage
sub-resources and Key Vault secret) require network access to the
private endpoint. On a genuinely fresh environment, this creates a real,
unavoidable circularity: the CI that would create the runner needs the
runner to already exist to run at all.

**The jumpbox and runner - and the specific Firewall rules they depend
on - live in a second, completely independent Terraform root
(`bootstrap/`), with its own state file and its own CI workflow
(`.github/workflows/bootstrap.yml`), running on GitHub-hosted
infrastructure rather than the self-hosted runner.** Every resource
`bootstrap/` creates is management-plane only - VM creation, Firewall
rule collection groups - meaning it has no equivalent circularity and
can genuinely apply itself from a completely fresh environment.

Two real details this design required getting right:

- **The Firewall rules the jumpbox and runner need live in `bootstrap/`
  itself, not this project's own state.** Their boot scripts need
  outbound connectivity the moment they start - if their Firewall
  allow-rules lived in this project's state instead (applied strictly
  after `bootstrap/`, by definition), a fresh `bootstrap/` apply would
  recreate the exact connectivity failure documented earlier in this
  section. The relevant rule collection group is its own module
  (`modules/firewall-rules-shared-services`), applied as part of
  `bootstrap/` before the VMs it protects.
- **The runner's identity is read across states, not via a direct module
  reference.** This project's own `runner_acr_push` role assignment
  needs the runner's `principal_id`, which lives in a genuinely separate
  Terraform state - read via a `terraform_remote_state` data source
  pointed at `bootstrap/`'s own exposed output, the same pattern already
  used for reading the network project's state.

Genuinely shared modules (`jumpbox`, `github-runner`,
`firewall-rules-shared-services`) live in a top-level `modules/` folder,
sibling to both `bootstrap/` and this project's own root.

**The bootstrap sequence, solved structurally rather than worked
around:** `bootstrap/` applies first (on GitHub-hosted CI, or manually,
no self-hosted dependency) → the runner is registered → this project's
own CI can now run, since the runner it depends on already exists.

### One Service Principal, three federated credentials - not one

Every workflow authenticates to Azure via OIDC through a single, shared
Microsoft Entra Application - one Service Principal used across
`terraform.yml`, `bootstrap.yml`, and `build-and-push.yml`, rather than
a separate identity per workflow.

**A real, non-obvious detail that would have caused a confusing partial
failure if missed:** `terraform.yml` and `bootstrap.yml`'s `apply` jobs
both declare `environment: production` - and GitHub issues a materially
different OIDC subject claim for jobs running under a declared
environment (`repo:<org>/<repo>:environment:production`) than for jobs
without one (`repo:<org>/<repo>:pull_request`,
`repo:<org>/<repo>:ref:refs/heads/main`). A single federated credential
covering only the "push to main" case would have let `build-and-push.yml`
authenticate fine while both `apply` jobs failed silently at exactly the
same login step, for what would look like an unrelated reason. Three
separate federated credentials were created instead, each matching the
exact subject claim a specific job type actually presents.

### The Storage Table - a hard provider limitation, not a network issue

Every other data-plane resource this project restored to Terraform
management (the queue, the Velero container, the Key Vault secret) was
solvable, once the real constraint was understood - `storage_use_azuread
= true` plus running `apply` from inside the VNet. The Table specifically
is not solvable this way at all, confirmed directly from HashiCorp's own
`azurerm_storage_table` documentation: Shared Key authentication is
always required to set or retrieve a table's ACLs, unconditionally -
not affected by `storage_use_azuread`, not affected by which identity
runs `apply`, not affected by network location. This account's
`shared_access_key_enabled = false` means no key exists for this
resource to use at all, and the two are structurally incompatible.

The table moved back to manual creation - a narrow, single-resource
exception, not a repeat of the earlier full-storage reversal. The
queue and container don't share this documented limitation and remain
fully Terraform-managed.

### Key Vault Secrets Officer - a genuine self-bootstrapping gap

`Contributor` and `User Access Administrator`, granted to the CI Service
Principal during initial setup, cover management-plane access only -
creating the vault resource itself, and creating role assignments.
Neither grants data-plane access to actually read or write secret
*values* inside an RBAC-mode Key Vault, which is a separate permission
entirely.

The Key Vault module already grants this dynamically, to whoever runs
`apply`, via a role assignment scoped to `data.azurerm_client_config
.current.object_id`. That's correct in steady state, but creates a real
gap the first time a genuinely new identity (a freshly created Service
Principal) runs `apply`: it needs to both grant itself this permission
and use it within the same run, and if Terraform's read of the secret's
current value happens before that role assignment has fully propagated,
a 403 on `Microsoft.KeyVault/vaults/secrets/getSecret/action` results.

Fixed by granting `Key Vault Secrets Officer` explicitly, once, to the
Service Principal directly - removing the dependency on that
self-bootstrap for the specific case of a brand-new identity's first run.

### Velero's stuck sync - five genuinely separate root causes, one surface symptom

The `velero` ArgoCD Application sat `OutOfSync`/`Missing` for hours,
surviving multiple fixes that each looked complete on their own. Worth
recording in full, since every one of these was independently real and
independently necessary - fixing four of the five still left it broken.

1. **A third-party image brownout, not a project bug.** Bitnami
   restructured their free image distribution in 2025, removing most
   versioned tags from `docker.io/bitnami` entirely. The Velero chart's
   CRD-upgrade hook auto-computes `bitnami/kubectl:<cluster-k8s-version>`
   - a tag that no longer exists, confirmed against a matching, currently
   open upstream issue (`bitnami/charts#36357`). Fixed by explicitly
   overriding `kubectl.image.repository`/`kubectl.image.tag` to
   `bitnamilegacy/kubectl:1.33.4`, a real, still-published tag on
   Bitnami's own legacy (unmaintained but still free) mirror.
2. **App-of-Apps propagation lag.** `gitops/apps/velero.yaml` is watched
   by `root-app`, not by the `velero` Application directly - syncing
   `velero` alone just re-applies whatever spec `root-app` already gave
   it. The values fix genuinely didn't reach `velero`'s own spec until
   `root-app` itself was synced first.
3. **A stale repo-server render cache.** Even with the correct spec in
   place, the rendered manifest ArgoCD was applying still showed the old
   image - confirmed by testing the identical override with plain
   `helm template`, completely bypassing ArgoCD, which rendered
   correctly. `argocd-repo-server` (which runs `helm template` and
   caches the result) needed a restart - `argocd-application-controller`
   alone does not cover this.
4. **A sync operation stuck for four-plus hours, ignoring every fix
   underneath it.** `Status.Operation.Started At` showed the *original*
   sync attempt from hours earlier, still `Running`, still retrying
   against whatever values existed when it started - not the corrected
   ones. Every subsequent manual sync patched cleanly but reported
   "(no change)," since ArgoCD won't start a new operation on top of one
   already in progress. Fixed by directly removing the stuck operation:
   `kubectl patch application velero -n argocd --type json -p '[{"op":
   "remove", "path": "/operation"}]'`.
5. **A Kubernetes finalizer stuck twice in a row.** The hook Job's
   `argocd.argoproj.io/hook-finalizer` prevented `kubectl delete` from
   ever actually completing, despite reporting success - confirmed by an
   unchanged object UID before and after the delete. Required manually
   clearing the finalizer (`kubectl patch job ... -p
   '{"metadata":{"finalizers":[]}}' --type=merge`) twice, once per
   affected Job, alongside a restart of `argocd-application-controller`
   (the component that actually owns finalizer release, distinct from
   the repo-server restart above).

The methodology that actually cut through this: comparing Terraform/
Kubernetes object UIDs and timestamps directly, rather than trusting
`kubectl`/`helm` command output alone - "deleted" and "patched" both
reported success at multiple points while the real, underlying object
was provably unchanged.

### Two identities sharing one role-assignment ID - a real import mistake, found by checking Azure directly, not Terraform state

`aduke_table` and `worker_table` (both `Storage Table Data Contributor`
grants) independently surfaced `AuthorizationPermissionMismatch` errors
at the application layer, at different points in the same session, with
both apps' own Terraform code confirmed correct. Terraform's state for
*both* resources pointed at the exact same real Azure role-assignment ID
- a leftover of an earlier mis-import, most likely from copy-pasting one
import command to build the next during an extensive drift-cleanup
sweep.

Fixing one (`worker_table`, via `terraform state rm` + a fresh `apply`)
correctly created a new, distinct role assignment for Worker - but that
apply implicitly orphaned Aduke's own real grant, since it had never
actually existed separately from Worker's under that shared ID.
Terraform's state kept claiming Aduke's grant existed long after it
didn't.

**The only way this was actually confirmed - `az role assignment list
--assignee <principal-id> --scope <resource-id>`, querying Azure
directly, bypassing Terraform's state entirely.** Every other check
(the module's source code, `terraform state show`, the pod's own
environment variables, the storage account name, the table's own
existence) came back correct in isolation - only asking Azure "what does
this identity actually, currently have" revealed the real gap.

---

## Part 3: Known limitations, stated honestly

- **Single region (`centralus`).** A regional Azure outage takes the whole
  project down. No multi-region failover exists or was attempted - documented
  as out of scope, not an oversight.
- **NetworkPolicy egress is not fully locked down.** The `0.0.0.0/0:443`
  rule (required for Entra ID token exchange, since Microsoft doesn't
  publish a stable IP range for it) means HTTPS to any destination is
  technically reachable from Aduke/worker pods. The real enforcement in
  this project is the **ingress** restriction and the **port-level**
  restriction - not a complete destination allow-list. Cilium's L7/FQDN
  policies (available given Cilium was already chosen as the CNI) are
  the documented path to closing this further, not yet implemented.
- **Every FQDN-based Firewall application rule in this project is
  currently non-enforcing**, a direct consequence of the network rule
  evaluation order finding in Part 2. They remain as documentation of
  intent. Closing this properly would require either accepting the
  network project's broad Service-Tag/fallback rules as the real
  boundary (the current state), or negotiating a narrower, jointly-owned
  Firewall design with the network project - not done here.
- **Velero's practical recovery value is limited for this specific
  architecture.** This project is fully stateless (no PersistentVolumes)
  and fully GitOps-managed - Git + Terraform + ArgoCD already reconstruct
  the entire cluster's state from scratch. Velero was built to demonstrate
  the skill and pattern, not because this architecture has a gap it
  uniquely fills.
- **This subscription's vCPU quota is tight by design, not by choice**,
  and it has already caused one real, hard-to-diagnose stuck deployment
  (a node pool replace needing temporary overlap capacity). A real quota
  increase request, not a further sizing adjustment, is the durable fix.
- **The `ARM_CLIENT_ID`/`ARM_TENANT_ID`/`ARM_USE_OIDC` question in
  `terraform.yml` was never fully confirmed** - whether `azure/login@v2`
  sets these automatically for the `azurerm` provider's own OIDC
  authentication, separate from the `az` CLI's own login. Flagged, not
  resolved.
- **No manual approval gate exists before `terraform apply` runs on
  `main`** - only the `plan` job runs on pull requests. A human currently
  only reviews changes *after* they've already been applied to
  infrastructure (via the values-population PR), not before. A GitHub
  Environment protection rule requiring approval before the `apply` job
  proceeds would close this gap; not yet implemented.

---

## Part 4: A deliberate cost-driven restructuring - what changed, and what it genuinely gives up

Everything in Part 1 through Part 3 documents a real, working, fully
zero-trust architecture - a hub-and-spoke network, Azure Firewall
forcing all egress through a single inspection point, Bastion gating
every human connection, and private endpoints on every backend PaaS
dependency. That architecture is not wrong, and this section doesn't
retract any of the reasoning that led to it. **It stopped being the
right choice for this specific project for one plain reason: running
cost.** Azure Firewall Standard and Bastion Standard are both billed a
fixed hourly rate regardless of actual traffic - for a portfolio project
that isn't running production traffic continuously, that fixed cost
never gets amortized against real usage the way it would in an actual
production system.

### What was removed, and why each one specifically

- **The hub-and-spoke network integration is gone entirely.** This
  project no longer reads the separate network project's remote state,
  peers with its VNet, or shares any of its infrastructure. It creates
  its own small, standalone VNet instead (`modules/network`) - two
  subnets, no peering, no shared hub to depend on or pay a share of.
- **Azure Firewall is gone.** Every outbound path this project ever had
  (node bootstrap traffic, the jumpbox's own package installs) now uses
  AKS's standard outbound egress directly - no forced-tunneling UDR, no
  central inspection point. The real, significant debugging finding
  documented in Part 2 (network rules silently evaluated before
  application rules) is now moot for this project specifically, since
  there's no Firewall left to hit that behavior at all.
- **Bastion is gone.** The jumpbox now has its own public IP, with an
  NSG restricting inbound SSH to exactly one allow-listed source address
  - the actual access control moved from Bastion's own AAD-gated
  tunnel to a plain network-layer allowlist. This is a real, honest
  reduction in defense-in-depth, not a lateral move: Bastion added a
  second, independent barrier (you needed both network reachability
  *and* an Azure AD-authenticated tunnel); a locked-down NSG rule is a
  single barrier. Acceptable for this project's actual threat model, not
  presented as equivalent security.
- **Every private endpoint is gone** (Key Vault, ACR, Storage). All
  three now have `public_network_access_enabled = true`, relying on
  Azure RBAC as the real access control instead of network isolation. A
  leaked credential or an RBAC misconfiguration is now reachable from
  the public internet in a way it structurally couldn't be before - this
  is the single largest security trade-off in this whole restructuring,
  and it's the right one to be most honest about. Container Registry
  also dropped from Premium to Standard SKU in the same move - Premium
  existed *only* because Standard/Basic don't support Private Link at
  all, a requirement that no longer applies.
- **The dedicated self-hosted CI runner is gone.** With every PaaS
  dependency public, CI no longer needs real network access to reach
  anything - `terraform.yml` and `build-and-push.yml` both moved to
  GitHub-hosted runners. This wasn't explicitly requested - it fell out
  directly from removing private endpoints, and it's a genuine
  simplification: no VM to pay for, patch, or keep provisioned for CI at
  all.

### What this enabled, as a direct, positive consequence

**The entire reason `bootstrap/` existed as a separate Terraform root
was a chicken-and-egg problem: this project's own CI ran on a
self-hosted runner that CI itself had to create.** With CI now
GitHub-hosted from the start, that problem never exists in the first
place - `bootstrap/` and `aks-platform/` were merged back into one
consolidated Terraform project. No more cross-state
`terraform_remote_state` reads between two roots, no more coordinating
two separate applies, no more possibility of the exact state-drift
incidents documented in Part 2 (the mis-imported role assignment shared
between `aduke_table` and `worker_table`, the VM/Firewall-rule
destroy incidents from state genuinely disagreeing across two roots).
A structural simplification, not just a smaller one.

**The project also collapsed to a single Azure subscription.** The
original Platform/Production split existed specifically to mirror
sharing infrastructure with the (now-removed) hub network project -
with nothing left to share, there's no reason left to keep two
subscriptions, two sets of OIDC federated-credential subject claims to
worry about per subscription, or the provider-aliasing pattern
(`azurerm.platform`) that several modules previously required.

### What stayed exactly the same, deliberately

**The AKS API server remains private**, reachable only via the jumpbox
- the one piece of the original zero-trust posture kept intact by
explicit choice, not by default. Workload Identity, GitOps via ArgoCD,
Helm charts, NetworkPolicy enforcement, HPA/Cluster Autoscaler, and
Velero backup are all completely unchanged - this restructuring
touched the network/security perimeter specifically, not the
application or delivery layers built on top of it.

### The honest summary

This is not a claim that the new design is "just as secure" as the one
it replaced - it isn't, and pretending otherwise would undermine the
actual value of documenting this decision at all. It's a real,
considered trade: a meaningfully lower ongoing cost, in exchange for a
genuinely smaller (not zero, but smaller) attack surface reduction than
the original design provided. For a project whose primary purpose is
demonstrating engineering judgment rather than protecting real
production data, that's a defensible trade - and the judgment worth
demonstrating is making the trade-off explicit, not hiding it behind
architecture-diagram language that no longer matches what's actually
running.
