#!/usr/bin/env bash
# build-kubeconfig.sh — build a multi-context kubeconfig from a node's admin.conf.
#
# Result: a single ./kubeconfig file with 3 clusters and 3 contexts, one per
# node IP, all sharing the same CA and client credentials. Recipients can
# switch between nodes with `kubectl config use-context aranya-via-node{1,2,3}`.
#
# Usage:
#   build-kubeconfig.sh <ssh-key> <node1-ip> <node2-ip> <node3-ip> <output-path>

set -euo pipefail

SSH_KEY="${1:?missing ssh-key arg}"
NODE1="${2:?missing node1 ip}"
NODE2="${3:?missing node2 ip}"
NODE3="${4:?missing node3 ip}"
OUT="${5:?missing output path}"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# fetch the original admin.conf from node1
scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
  "root@${NODE1}:/etc/kubernetes/admin.conf" "$TMP" >/dev/null

# pull the embedded CA, client cert, client key out of admin.conf
CA=$(kubectl --kubeconfig="$TMP" config view --raw --flatten \
       -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
CERT=$(kubectl --kubeconfig="$TMP" config view --raw --flatten \
       -o jsonpath='{.users[0].user.client-certificate-data}')
KEY=$(kubectl --kubeconfig="$TMP" config view --raw --flatten \
       -o jsonpath='{.users[0].user.client-key-data}')

# write the multi-context kubeconfig
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
preferences: {}

clusters:
- name: aranya-via-node1
  cluster:
    server: https://${NODE1}:6443
    certificate-authority-data: ${CA}
- name: aranya-via-node2
  cluster:
    server: https://${NODE2}:6443
    certificate-authority-data: ${CA}
- name: aranya-via-node3
  cluster:
    server: https://${NODE3}:6443
    certificate-authority-data: ${CA}

users:
- name: kubernetes-admin
  user:
    client-certificate-data: ${CERT}
    client-key-data: ${KEY}

contexts:
- name: aranya-via-node1
  context:
    cluster: aranya-via-node1
    user: kubernetes-admin
- name: aranya-via-node2
  context:
    cluster: aranya-via-node2
    user: kubernetes-admin
- name: aranya-via-node3
  context:
    cluster: aranya-via-node3
    user: kubernetes-admin

current-context: aranya-via-node1
EOF

chmod 600 "$OUT"
echo "✓ wrote multi-context kubeconfig at $OUT"
