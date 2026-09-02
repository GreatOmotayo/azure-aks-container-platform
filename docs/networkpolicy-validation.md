# NetworkPolicy Validation Test Plan

This is the procedure for validating that the NetworkPolicies in
`charts/aduke/templates/networkpolicy.yaml` and
`charts/worker/templates/networkpolicy.yaml` actually enforce what they
claim to - both the denials and the allows. Run this after `terraform
apply` and both Helm charts are deployed. Record actual command output in
the "Observed result" line under each test - this document is the skeleton
for the eventual writeup deliverable, not the writeup itself.

**Access:** run all commands from the Bastion jumpbox (`az network bastion
ssh`), where `kubectl` is already configured against the private cluster.

**Testing technique used, and why:**
- **Ingress denial tests** use standalone `kubectl run` test pods placed in
  different namespaces - this correctly tests "can *anything else* reach
  Aduke," which is a question about the caller, not about Aduke itself.
- **Egress tests** use `kubectl debug` to attach an ephemeral container
  directly to the *real* Aduke/worker pods, sharing their actual network
  namespace. This tests the real pod's real NetworkPolicy context, rather
  than a generic pod that might not accurately represent what Aduke or the
  worker can actually do - the production images are minimal Alpine
  builds with no `curl`/`nc`, so this technique avoids needing to bloat
  them with debug tools just to test.

---

## Test 1 - ALLOW: Ingress Controller can reach Aduke (baseline)

Confirms the normal path works before testing denials - a denial test is
meaningless if the baseline was never confirmed working.

```bash
curl -H "Host: aduke.local" http://<ingress-controller-external-or-internal-ip>/jobs
```

**Expected result:** HTTP response from Aduke (404 or a real jobs response, not a connection timeout).

**Observed result:** _(record here)_

---

## Test 2 - DENY: An arbitrary pod cannot reach Aduke directly

This is the core "denied pod-to-pod path" deliverable. A generic pod, in
the same namespace as Aduke but carrying none of the allowed source
labels, should be unable to reach Aduke's Service at all.

```bash
kubectl run netshoot-test --rm -it --image=nicolaka/netshoot -n app -- \
  curl -m 5 -v http://aduke.app.svc.cluster.local
```

**Expected result:** Connection times out (curl exit code 28) - NOT a
connection refused (which would suggest the Service has no endpoints, a
different problem) and NOT a successful response.

**Observed result:** _(record here)_

---

## Test 3 - DENY: The worker specifically cannot reach Aduke directly

Same test as #2, but run from inside the worker's own pod (via `kubectl
debug`, sharing its real network namespace) rather than a generic test
pod - this is the specific pair the project spec calls out, worth testing
explicitly rather than only by generalization from Test 2.

```bash
kubectl get pods -n app -l app=worker  # get a real worker pod name first

kubectl debug -it <worker-pod-name> -n app --image=nicolaka/netshoot --target=worker -- \
  curl -m 5 -v http://aduke.app.svc.cluster.local
```

**Expected result:** Connection times out - same as Test 2, confirming
the worker specifically has no special-cased access to Aduke.

**Observed result:** _(record here)_

---

## Test 4 - ALLOW: Aduke can still reach its Storage/Key Vault private endpoints

Confirms the egress allow-rule for the private-endpoint subnet CIDR is
actually working, not just present in the manifest.

```bash
kubectl get pods -n app -l app=aduke

kubectl debug -it <aduke-pod-name> -n app --image=nicolaka/netshoot --target=aduke -- \
  curl -m 5 -v https://<storage-account-name>.queue.core.windows.net
```

**Expected result:** TLS handshake succeeds (curl gets far enough to
negotiate TLS, even if the final HTTP response is a 4xx - that still
proves the network path is open, which is what this test actually checks).

**Observed result:** _(record here)_

---

## Test 5 - ALLOW: Aduke can reach Entra ID for Workload Identity token exchange

Directly validates the Firewall fix from earlier in this project
(`entra-id-token-exchange` rule) actually works end-to-end, not just that
the rule exists in Terraform.

```bash
kubectl debug -it <aduke-pod-name> -n app --image=nicolaka/netshoot --target=aduke -- \
  curl -m 5 -v https://login.microsoftonline.com
```

**Expected result:** TLS handshake succeeds.

**Observed result:** _(record here)_

---

## Test 6 - DENY: Aduke cannot make arbitrary egress on a non-allowed port

The egress allow-list only opens DNS (53) and HTTPS (443) - this confirms
that's a real restriction, not effectively open-everything. Worth being
honest in the writeup that the `0.0.0.0/0:443` rule (needed for Entra ID)
is fairly broad on its own - this test at least confirms non-443/53
traffic is genuinely blocked, which is the boundary that's actually being
enforced.

```bash
kubectl debug -it <aduke-pod-name> -n app --image=nicolaka/netshoot --target=aduke -- \
  curl -m 5 -v http://example.com:80
```

**Expected result:** Connection times out - port 80 was never allowed, only 443.

**Observed result:** _(record here)_

---

## Test 7 - ALLOW: DNS resolution works

A sanity check - if this fails, every other test's failure is meaningless
noise, since nothing would resolve at all.

```bash
kubectl debug -it <aduke-pod-name> -n app --image=nicolaka/netshoot --target=aduke -- \
  nslookup login.microsoftonline.com
```

**Expected result:** A resolved IP address, no timeout.

**Observed result:** _(record here)_

---

## Known limitation, worth stating plainly in the eventual writeup

The `0.0.0.0/0:443` egress rule (required for Entra ID token exchange,
since Microsoft doesn't publish a narrow, stable IP range for it) means
this NetworkPolicy is **not** a fully locked-down egress boundary - any
HTTPS destination is technically reachable from these pods, not just the
specific Azure services they're meant to talk to. The meaningful
enforcement here is the **ingress** restriction (Tests 2-3) and the
**port-level** restriction (Test 6), not a complete deny-all-except-named-
destinations egress policy. This is a real, documented trade-off, not an
oversight - narrowing it further would require either a service mesh with
L7/FQDN-aware egress policies (Cilium supports this, and was already
chosen as this cluster's CNI for exactly this kind of future capability)
or accepting the operational risk of hardcoding Microsoft's IP ranges,
which change over time.
