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
| 8 | Cluster access path | Jumpbox with a public IP, NSG-restricted to one allow-listed source (see Part 4) | Originally Bastion + Private Endpoint; reversed for cost reasons - a real, stated trade-off, not a silent downgrade |
| 9 | App architecture | Reuse Aduke, add one purpose-built worker | A larger multi-service demo app (Sock Shop, Online Boutique) - rejected as disproportionate complexity for what needs proving |
| 10 | Staging environment | Deliberately NOT built as a live cluster | A second live NonProd cluster - cost/value didn't justify it for a single-operator, short-lived test project. Naming stays environment-aware (`var.environment`) so promotion later is a config change, not a rewrite |
| 11 | 1M-user scale design | Documented capacity-planning target, not a live deployment; HPA/node-pool ceilings raised generously since ceilings cost nothing while unused | Actually running at that scale - rejected as financially and practically unnecessary for this project's real usage pattern |

### Phase 2 - Cluster identity & DNS

| Decision | Reasoning |
|---|---|
| Custom (BYO) private DNS zone, not AKS's "System" default | Originally needed because the Bastion jumpbox lived in a separate hub VNet from the cluster - now that both share one standalone VNet (see Part 4), "System" would technically suffice, but the explicit zone is kept anyway simply for the clarity of having it as a visible, named resource in this project's own state |
| `UserAssigned` cluster identity, not `SystemAssigned` | Solves a chicken-and-egg problem: a BYO-subnet, BYO-DNS-zone cluster needs its identity to already hold `Network Contributor`/`Private DNS Zone Contributor` *before* cluster creation finishes - impossible with a `SystemAssigned` identity that doesn't exist until creation is underway |
| Cilium as the CNI data plane | Azure NPM's retirement is real and dated, not just directional - confirmed against Microsoft's own current documentation: support for NPM on Linux nodes ends September 30, 2028. Cilium's eBPF enforcement is also what the later NetworkPolicy deny-and-verify testing actually exercises |

### Phase 4 - ACR, Key Vault, Storage

| Decision | Reasoning |
|---|---|
| Storage: Queue Sender/Processor split, not one shared Contributor role | Aduke only ever sends messages; the worker only ever processes them. Confirmed as genuinely separate built-in Azure roles before using them |
| Storage: `shared_access_key_enabled = false` | Removes the static account key entirely - forces every client through Workload Identity, no fallback credential exists to leak |
| Storage/Key Vault data-plane resources (queue, container, secret): created via Terraform; the table is the one permanent exception | See Part 2 for the full account - the table's exclusion is a separate, permanent provider limitation, unrelated to the network-access story that applied to the other three |
| Velero: dedicated blob container in the existing Storage Account, not a new account | Sufficient isolation for this project's scope; avoids a whole additional account to secure |
| Velero: whole-Storage-Account RBAC scope, not container-level | Container-level scope was tried at one point - see Part 2 for the full account of why it didn't remain the final state |

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

### OS disk type: Ephemeral reverted to Managed

`Standard_D2s_v5` has no local temp disk, which Ephemeral OS disks
strictly require. Both node pools moved to `Managed` OS disks instead,
which work with any VM size. This is a genuine compromise, not an
equivalent swap - Managed disks are persisted, network-attached
storage, the opposite of Ephemeral. The original benefit of Ephemeral
(no persisted disk I/O for disposable, autoscaled VMs) is lost, not
preserved through another mechanism.

### VM sizing, driven entirely by real subscription quota

- **Node pools run `Standard_D2s_v6`.** This subscription's Dsv5 family
  had a hard 0 vCPU limit; Dsv6 (a separate quota family) had real
  headroom once quota was raised to 20 vCPU.
- **User node pool `max_count` is 3.** System (4 vCPU) + user at max (6
  vCPU) fit comfortably within the 20 vCPU quota, with real room to
  raise this further if load-testing needs ever grow past it.
- **The jumpbox runs `Standard_B2ls_v2`**, a Burstable-series size in a
  separate quota family from the node pools - chosen for cost, since its
  only workload is occasional `kubectl`/`az` CLI sessions, never
  application traffic.
- **A tight quota ceiling has one real, non-obvious consequence worth
  knowing:** a Terraform change that forces a node pool VMSS *replace*
  (not an in-place update) briefly needs both the old and new VMSS to
  exist simultaneously - a genuine overlap-capacity requirement, not
  something a zero-slack quota accounts for on its own. Keep some
  headroom above the bare minimum for exactly this reason.

### Tag policy compliance - two separate, real governance conflicts

- **Container Insights.** Enabling `oms_agent` auto-creates a companion
  `Microsoft.OperationsManagement/solutions` resource, which the
  Landing Zone project's own tag-requiring policy (`baseline-platform`)
  blocks without a `CostCenter` tag. This project pre-creates that same
  Solution resource directly, with the tag already attached - avoiding
  a cross-project policy exemption entirely.
- **Node pool VMSS.** A separate policy (`baseline-production`, same
  tag requirement) blocks the system node pool's own auto-created
  VMSS. `tags` set directly on the node pool block propagate onto the
  VMSS itself - the real, documented mechanism for this, not a
  workaround.
- `CostCenter` is part of this project's default tag set for exactly
  this reason, closing the same gap for every resource under the same
  management group scope.

### Storage/Key Vault data-plane resources - queue, container, and secret via Terraform; the table is the one exception

Key Vault and Storage are both public now (see Part 4), so there's no
network-location requirement on where `terraform apply` runs from -
the queue, the Velero backup container, and the Key Vault secret are
all created and managed directly in Terraform, from any machine.
`storage_use_azuread = true` on the provider is still required
regardless - an auth-method setting, unrelated to network location -
since `shared_access_key_enabled = false` means no account key exists
for the provider to fall back on.

**The Storage table is a separate, permanent exception, unrelated to
network access at all.** `azurerm_storage_table` always requires Shared
Key authentication to read/set ACLs - a hard AzureRM provider
constraint. It's created manually regardless of network location (see
`docs/VALIDATION-PLAN.md` Section 1.4).

### Velero's role scope - whole Storage Account, a known least-privilege trade-off

Velero's identity has `Storage Blob Data Contributor` at the whole
Storage Account level, not scoped to just its own backup container.
Container-level scope is technically possible and would be tighter -
this is a real, acknowledged least-privilege gap left as-is, not a
technical limitation forcing the broader scope.

### Values-file automation - key-name matching, always reset before populating

`scripts/populate-values.sh` replaces Terraform outputs into each
chart's `values.yaml` and `gitops/apps/velero.yaml`. The `velero.yaml`
portion uses targeted text substitution rather than a YAML-aware tool,
since its real values sit inside an embedded Helm values string, not
real YAML structure - matching by key name specifically, since key
names are functionally required and won't drift the way a comment
could.

`scripts/revert-values.sh` always runs first, unconditionally, resetting
every value back to its placeholder before populating. Substitution only
matches a known placeholder string - without a reset first, a second
population run (after infrastructure is destroyed and recreated, with
genuinely new values) would silently fail to update anything at all,
leaving stale identity data in place.

### One Service Principal, three federated credentials - not one

Every workflow authenticates to Azure via OIDC through a single, shared
Microsoft Entra Application - one Service Principal used across both
`terraform.yml` and `build-and-push.yml`, not a separate identity per
workflow.

**A real, non-obvious detail:** `terraform.yml`'s `apply` job declares
`environment: production`, and GitHub issues a materially different
OIDC subject claim for jobs under a declared environment
(`repo:<org>/<repo>:environment:production`) than for jobs without one
(`repo:<org>/<repo>:pull_request`,
`repo:<org>/<repo>:ref:refs/heads/main`). A single federated credential
covering only "push to main" would let `build-and-push.yml`
authenticate fine while `terraform.yml`'s `apply` job failed silently
at the same login step, for what would look like an unrelated reason.
Three separate federated credentials exist instead, each matching the
exact subject claim a specific job type actually presents.

### The Storage Table - a hard provider limitation, not a network issue

The queue, the Velero container, and the Key Vault secret are all
Terraform-managed, requiring only `storage_use_azuread = true` on the
provider. The Table is different, confirmed directly from HashiCorp's
own `azurerm_storage_table` documentation: Shared Key authentication
is always required to set or retrieve a table's ACLs, unconditionally -
not affected by `storage_use_azuread`, not affected by which identity
runs `apply`, not affected by network location. This account's
`shared_access_key_enabled = false` means no key exists for this
resource to use at all - the two are structurally incompatible.

The table is created manually - a narrow, single-resource exception.
The queue and container don't share this limitation and remain fully
Terraform-managed.

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

`Key Vault Secrets Officer` is granted explicitly, once, to the Service
Principal directly - removing the dependency on the self-bootstrap for
a brand-new identity's first run.

### Velero's stuck sync - five genuinely separate root causes, one surface symptom

The `velero` ArgoCD Application sat `OutOfSync`/`Missing` for hours.
Five independent causes, each real and each necessary - fixing four
still left it broken:

1. **Bitnami image brownout.** The CRD-upgrade hook's auto-computed
   `bitnami/kubectl` tag no longer exists on Bitnami's free tier.
   Pinned explicitly to `bitnamilegacy/kubectl:1.33.4` instead.
2. **App-of-Apps propagation lag.** `velero.yaml` is watched by
   `root-app`, not `velero` directly - `root-app` needed its own sync
   before `velero`'s spec reflected the fix.
3. **Stale repo-server render cache.** `argocd-repo-server` needed a
   restart to actually re-render the manifest - `argocd-application-
   controller` alone didn't cover it.
4. **A sync operation stuck for hours**, still retrying against
   pre-fix values. Fixed by removing the stuck operation directly via
   `kubectl patch`.
5. **A Kubernetes finalizer stuck twice**, making `kubectl delete`
   report success without the object actually being removed. Cleared
   manually, alongside a restart of `argocd-application-controller`.

The methodology that cut through it: comparing object UIDs directly,
rather than trusting `kubectl`/`helm` success messages alone.

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
- **This subscription's vCPU quota was tight by design initially**, and
  it caused one real, hard-to-diagnose stuck deployment (a node pool
  replace needing temporary overlap capacity). Resolved by requesting
  and receiving a genuine quota increase (to 20 vCPU in the relevant
  family) - the durable fix, not a further sizing workaround.
- **Velero's practical recovery value is limited for this specific
  architecture.** This project is fully stateless (no PersistentVolumes)
  and fully GitOps-managed - Git + Terraform + ArgoCD already reconstruct
  the entire cluster's state from scratch. Velero was built to demonstrate
  the skill and pattern, not because this architecture has a gap it
  uniquely fills.

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

- **The hub-and-spoke network integration is gone.** This project now
  creates its own small, standalone VNet (`modules/network`) - no
  shared hub, no remote-state dependency.
- **Azure Firewall is gone.** All egress now uses AKS's standard
  outbound path directly. The Part 2 finding about network rules
  silently pre-empting application rules is now moot - there's no
  Firewall left to hit it.
- **Bastion is gone.** The jumpbox has its own public IP with an
  NSG allow-listing one source address. A real reduction in
  defense-in-depth, not a lateral move - Bastion was two independent
  barriers (network reachability *and* an AAD-gated tunnel); an NSG
  rule is one.
- **Every private endpoint is gone** (Key Vault, ACR, Storage) - all
  three are public now, relying on Azure RBAC instead of network
  isolation. **This is the single largest security trade-off in the
  whole restructuring**, worth being most honest about: a leaked
  credential or RBAC misconfiguration is now reachable from the
  internet in a way it structurally couldn't be before. ACR also
  dropped from Premium to Standard, since Premium existed only for
  Private Link support.
- **The dedicated self-hosted CI runner is gone.** With every PaaS
  dependency public, CI needs no VNet access at all - both workflows
  moved to GitHub-hosted runners. Not explicitly requested; it fell
  out directly from removing private endpoints.

### What this enabled, as a direct, positive consequence

`bootstrap/` existed as a separate Terraform root solely to solve a
chicken-and-egg problem: CI ran on a self-hosted runner that CI itself
had to create. GitHub-hosted CI never has that problem, so
`bootstrap/` and `aks-platform/` merged back into one project - no
more cross-state reads, no more coordinating two applies.

The project also collapsed to a single subscription. The original
Platform/Production split existed to mirror sharing infrastructure
with the hub network project; with nothing left to share, there's no
reason to keep two subscriptions, two sets of federated-credential
claims, or the `azurerm.platform` provider-aliasing pattern several
modules required.

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