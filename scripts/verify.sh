#!/usr/bin/env bash
# verify.sh — one-command smoke test of the Aranya cluster.
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig
#   bash scripts/verify.sh
#
# Exits 0 if everything looks healthy, non-zero on first failure.

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()  { echo -e "  ${YELLOW}!${RESET} $1"; }
fail()  { echo -e "  ${RED}✗${RESET} $1"; FAILED=1; }
hdr()   { echo -e "\n${YELLOW}== $1 ==${RESET}"; }

FAILED=0
NODES_PUBLIC=(134.199.196.192 129.212.186.30 134.199.204.141)

if [[ -z "${KUBECONFIG:-}" ]]; then
  fail "KUBECONFIG is not set. Run: export KUBECONFIG=\$PWD/kubeconfig"
  exit 1
fi

# ----- 1. cluster reachable, all nodes Ready -----
hdr "Cluster nodes"
nodes_out=$(kubectl get nodes --no-headers 2>&1)
if [[ $? -ne 0 ]]; then
  fail "kubectl can't reach the API: $nodes_out"
  echo
  echo "If node1 is unreachable, try: kubectl config use-context aranya-via-node2"
  exit 1
fi
echo "$nodes_out"
ready_count=$(echo "$nodes_out" | awk '$2=="Ready"' | wc -l)
[[ $ready_count -eq 3 ]] && ok "3 nodes Ready" || fail "$ready_count nodes Ready (expected 3)"

# ----- 2. ArgoCD applications -----
hdr "ArgoCD applications"
apps_out=$(kubectl -n argocd get applications --no-headers 2>&1)
if [[ $? -ne 0 ]]; then
  fail "Could not list ArgoCD applications"
else
  echo "$apps_out"
  # Healthy and Progressing are both acceptable — Progressing just means it's
  # still rolling out (cert-manager often spends a minute here). Only flag
  # Degraded / Missing / Unknown as actual failures.
  bad=$(echo "$apps_out" | awk '$3 == "Degraded" || $3 == "Missing" || $3 == "Unknown" {print $1}')
  if [[ -z "$bad" ]]; then
    ok "all ArgoCD applications are Healthy or still Progressing"
  else
    fail "applications in bad state: $bad"
  fi
fi

# ----- 3. metrics-server (kubectl top works) -----
hdr "Metrics-server"
if kubectl top nodes >/dev/null 2>&1; then
  ok "kubectl top nodes works"
else
  fail "kubectl top nodes failed (metrics-server not serving?)"
fi

# ----- 4. cert-manager CRDs -----
hdr "cert-manager CRDs"
cm_crds=$(kubectl get crd 2>/dev/null | grep -c cert-manager.io)
[[ $cm_crds -ge 5 ]] && ok "$cm_crds cert-manager CRDs present" || fail "only $cm_crds cert-manager CRDs found (expected 5+)"

# ----- 5. NFD labels on nodes -----
hdr "Node-feature-discovery labels"
nfd_labels=$(kubectl get nodes -o yaml 2>/dev/null | grep -c "feature.node.kubernetes.io")
[[ $nfd_labels -gt 0 ]] && ok "$nfd_labels NFD labels found" || fail "no NFD labels found on any node"

# ----- 6. sealed-secrets controller -----
hdr "Sealed-secrets controller"
ss_pods=$(kubectl -n clusterdos-sealed-secrets get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
[[ $ss_pods -ge 1 ]] && ok "sealed-secrets controller Running" || fail "no Running sealed-secrets pods"

# ----- 7. hello-aranya — public on all 3 node IPs -----
hdr "hello-aranya public reachability"
for ip in "${NODES_PUBLIC[@]}"; do
  code=$(curl -sS -o /dev/null -w "%{http_code}" -m 5 "http://$ip" 2>/dev/null)
  if [[ "$code" == "200" ]]; then
    ok "$ip → HTTP 200"
  else
    fail "$ip → HTTP ${code:-no response}"
  fi
done

# ----- 8. hello-aranya pods (one per node, hostNetwork) -----
hdr "hello-aranya pods"
ha_pods=$(kubectl -n hello-aranya get pods --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
[[ $ha_pods -eq 3 ]] && ok "3/3 hello-aranya pods Running" || fail "$ha_pods/3 hello-aranya pods Running"

# ----- summary -----
echo
if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}ALL CHECKS PASSED${RESET}"
  exit 0
else
  echo -e "${RED}SOME CHECKS FAILED — see ✗ marks above${RESET}"
  exit 1
fi
