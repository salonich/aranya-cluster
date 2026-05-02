# Aranya take-home — 3-node Kubernetes cluster

A GitOps-managed Kubernetes cluster on three DigitalOcean droplets. Built from cold metal with kubespray, then ArgoCD installs ClusterdOS, which installs the platform apps. A public nginx page serves "hello aranya" from every node.

---

## What's running

| Layer | Component |
|---|---|
| Infrastructure | 3× Ubuntu 24.04 droplets, DigitalOcean |
| Kubernetes | v1.31.9, all 3 nodes run control-plane + worker (stacked) |
| CNI | Cilium 1.15.9 |
| Service routing | kube-proxy (kept as a fallback alongside Cilium) |
| API HA | Per-node localhost nginx LB (kubespray default) |
| GitOps | ArgoCD v2.13.2 |
| Platform apps | cert-manager, metrics-server, NFD, sealed-secrets, vLLM — all installed by ClusterdOS as gitapps |
| Public web | "hello aranya" nginx — DaemonSet on `hostNetwork`, port 80 on each node |

## Try it

**Hello page** : http://134.199.196.192 · http://129.212.186.30 · http://134.199.204.141

**Cluster admin access** (using the GPG-encrypted kubeconfig from the email):

```bash
gpg --decrypt kubeconfig-public.gpg > kubeconfig
export KUBECONFIG=$PWD/kubeconfig

# one-shot health check of everything
bash <(curl -sSL https://raw.githubusercontent.com/<your-account>/aranya-cluster/main/scripts/verify.sh)

# or just kubectl
kubectl get nodes
kubectl -n argocd get applications
```

If node1 is unreachable: `kubectl config use-context aranya-via-node2` (or `node3`).

## Repo layout

```
aranya-cluster/
├── README.md                                # this file
├── inventory/aranya-takehome/               # ansible inventory + group_vars
├── apps/
│   ├── hello-aranya/                        # public nginx
│   ├── clusterdos/install.yaml              # one Argo Application bootstrapping all gitapps
│   └── vllm/                                # TinyLlama deployment
└── artifacts/                               # gitignored; kubeconfig lives here locally
```

---

## How to reproduce

### Prerequisites

On the operator machine:
- python3 ≥ 3.10
- ansible-core 2.16.x (kubespray release-2.27 requirement)
- kubectl 1.30+
- helm 3.14+
- gpg 2.4+

```bash
sudo apt install -y python3-pip gnupg
pip3 install --user ansible-core==2.16.4 netaddr jmespath
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
curl -LO https://dl.k8s.io/release/v1.31.9/bin/linux/amd64/kubectl && sudo install kubectl /usr/local/bin/
```

Three nodes:
- Ubuntu 24.04, ≥2 vCPU, ≥4 GB RAM, ≥50 GB disk
- Same private VPC subnet
- SSH key-auth to root

### 1. Set up

Clone the repo. Put the SSH private key outside the repo:

```bash
git clone https://github.com/salonich/aranya-cluster.git
cd aranya-cluster

mv /path/to/given/private-key ~/.ssh/aranya_id_ed25519
chmod 600 ~/.ssh/aranya_id_ed25519
```

Edit `inventory/aranya-takehome/hosts.yaml` to match your node IPs.

### 2. Get kubespray

```bash
git clone --branch release-2.27 https://github.com/kubernetes-sigs/kubespray.git
cd kubespray
git checkout 03828c9ffa26fced518cb9ebf7b20cc359412198
pip3 install --user -r requirements.txt
export ANSIBLE_CONFIG=$PWD/ansible.cfg
cd ..
```

### 3. Disable swap on every node

Kubespray refuses to install if swap is on:

```bash
ansible -i inventory/aranya-takehome/hosts.yaml all \
  -m shell -a "swapoff -a && sed -i '/swap/s/^/#/' /etc/fstab" -b
```

### 4. Run kubespray

```bash
ansible -i inventory/aranya-takehome/hosts.yaml all -m ping        # all 3 should SUCCESS

cd kubespray
ansible-playbook -i ../inventory/aranya-takehome/hosts.yaml --become cluster.yml
```

`failed=0` on all three nodes in the PLAY RECAP = success.

**If containerd wedges during image pull** (kubespray hangs on `Download_container | Download image if required` and `crictl images` is empty on the affected node):

```bash
ssh -i ~/.ssh/aranya_id_ed25519 root@<NODE_IP> \
  'systemctl stop containerd && rm -rf /var/lib/containerd/io.containerd.content.v1.content/ingest/* && systemctl start containerd'
```

Then re-run `cluster.yml` — kubespray is idempotent.

### 5. Get the kubeconfig

```bash
mkdir -p artifacts
scp -i ~/.ssh/aranya_id_ed25519 root@<node1-public-ip>:/etc/kubernetes/admin.conf artifacts/kubeconfig

cp artifacts/kubeconfig artifacts/kubeconfig-public
sed -i 's|server: https://127.0.0.1:6443|server: https://<node1-public-ip>:6443|' artifacts/kubeconfig-public

export KUBECONFIG=$PWD/artifacts/kubeconfig-public
kubectl get nodes
```

The API server cert SANs include all 3 public IPs (kubespray picks them up from `access_ip` in the inventory), so you can re-target the kubeconfig to any node IP.

### 6. Install ArgoCD

```bash
ARGOCD_VERSION=v2.13.2

kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

### 7. Apply ClusterdOS (installs cert-manager, metrics-server, NFD, sealed-secrets, vLLM)

Before applying, edit the `vllm` gitapp's `repoURL:` in `apps/clusterdos/install.yaml` to point at YOUR public fork of this repo (the gitapp uses path-based source pointing at `apps/vllm/` in your repo).

```bash
kubectl apply -f apps/clusterdos/install.yaml
kubectl -n argocd get applications -w   # Ctrl+C when all Synced/Healthy
```

Spawns six sub-Applications: `clusterdos-config`, `clusterdos-certmanager`, `clusterdos-metricsserver`, `clusterdos-nfd`, `clusterdos-sealedsecrets`, `clusterdos-vllm`.

- `metricsserver` and `sealedsecrets` settle at `OutOfSync/Healthy` — both controllers self-mutate at runtime (sealed-secrets rotates its key Secret; metrics-server's APIService gets `availabilityCondition` set by the kube-aggregator). Drift is expected, not a failure.
- `clusterdos-vllm` syncs `Synced/Healthy` because the Deployment ships with `replicas: 0` (won't fit in 3.8GB nodes — see Known limitations). Manifest lives in `apps/vllm/`; ArgoCD pulls from your repo and applies it.

### 8. Apply hello-aranya

```bash
kubectl apply -k apps/hello-aranya/
kubectl -n hello-aranya rollout status daemonset/hello-aranya

# verify all 3 public IPs serve
for ip in <node1-ip> <node2-ip> <node3-ip>; do
  curl -sS -o /dev/null -w "$ip → HTTP %{http_code}\n" http://$ip
done
```

Three `HTTP 200` lines.

### 9. Build the multi-context kubeconfig and encrypt for delivery

The repo ships a multi-context kubeconfig at `artifacts/kubeconfig-public` already shaped for delivery (one cluster + context per node). To regenerate from your own admin.conf, copy the same CA and client credentials into three cluster definitions, one per node IP.

Encrypt to recipients (verify fingerprints out-of-band first):

```bash
gpg --import /path/to/sasi.asc /path/to/yoofi.asc

gpg --trust-model always --encrypt --armor \
  --recipient sasivarnan619@gmail.com \
  --recipient ybquansah@gmail.com \
  --output artifacts/kubeconfig-public.gpg \
  artifacts/kubeconfig-public
```

Attach the `.gpg` to the email. To use it:

```bash
gpg --decrypt kubeconfig-public.gpg > kubeconfig
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
# if node1 is unreachable:
kubectl config use-context aranya-via-node2
```

## Decisions

1. **Stacked control-plane + worker on all 3 nodes.** 3-node etcd quorum survives any single node loss; splitting roles on 3 nodes wastes hardware and creates a single-CP SPOF.

2. **Cilium CNI with kube-proxy kept alongside.** Cilium for the eBPF datapath; kube-proxy stays as a Service-routing fallback and gives `iptables-save` / `ipvsadm` as a debugging surface even when both layers are healthy.

3. **Cluster traffic bound to the private VPC.** `ip` and `access_ip` point at `10.128.0.x`; public NICs only carry SSH and external ingress. Smaller attack surface, no inter-node egress cost.

4. **Per-node localhost API LB, not a floating VIP.** Tried kube-vip ARP first — DigitalOcean's VPC silently filters ARP for IPs not officially assigned to a droplet, so the GARPs were blackholed. Switched to kubespray's per-node nginx LB (kubelet talks to `127.0.0.1:6443`). Real-prod answer: DO Cloud Controller Manager + a `Service: LoadBalancer`.

5. **Multi-context kubeconfig for delivery.** kubectl has no built-in failover between server URLs. Three contexts let recipients flip with `kubectl config use-context aranya-via-node{1,2,3}` if a node dies. Cert SANs cover all 3 public IPs.

6. **No ingress controller for hello-aranya — DaemonSet on hostNetwork instead.** One static page doesn't need a Layer-7 router. NGINX Gateway Fabric (Gateway API) the moment a real domain or second service appears.

7. **ArgoCD installed directly, not via ClusterdOS.** ClusterdOS bootstraps AS an Argo Application — something has to install ArgoCD first. Pinned upstream manifest, one shot.

8. **sealed-secrets as the optional gitapp.** Extends "nothing sensitive in the public repo" to runtime — encrypted Secret manifests can live in git, only the in-cluster controller can decrypt.

9. **vLLM as a custom gitapp, not the built-in `inference` one.** Built-in `inference` is GPU-locked (uses llm-d). Added vLLM via the gitapps template's path-based source mode pointing at `apps/vllm/`. Same GitOps discipline, our own CPU-friendly Deployment.

10. **metrics-server `--kubelet-insecure-tls`.** kubespray-installed kubelet TLS certs don't include node IPs in SANs, so metrics-server's IP-based validation fails. Real-prod fix: `kubelet_rotate_server_certificates: true` and drop the flag.

11. **SSH multiplexing disabled in ansible.** Zombie-socket hangs hit three times during install. `ControlMaster=no` + `ServerAliveInterval=30` trades per-task latency for connection reliability.

12. **SSH key never committed.** Lives at `~/.ssh/aranya_id_ed25519`, referenced by absolute path. `.gitignore` blocks key patterns and the entire `artifacts/` dir.

---

## Known limitations

### vLLM doesn't fit on 3.8 GB nodes

vLLM container starts and validates config (we passed `--device=cpu`, `--swap-space=0`, `--dtype=float16` — all working). Then hits OOMKill during model load. Math:

- Container memory limit: 3 Gi
- TinyLlama at float16: ~2.2 GB for weights
- vLLM runtime + tokenizer + KV cache: ~700-900 MB
- Total > 3 GB → kubelet evicts the pod when the node hits its eviction threshold

This is a node-size constraint, not a config bug. The Deployment manifest is correct. Scale back up on nodes ≥ 8 GB and it'll work:

```bash
kubectl -n vllm scale deployment vllm --replicas=1
```

To make it fit on the current nodes: try INT8 quantization (TinyLlama at int8 ~1.1 GB, would fit) by switching to a pre-quantized model and adding `--quantization=gptq`. Not done in this delivery to protect the runbook timeline.

### Hubble UI attempted, scope-cut

Tried to add Hubble UI as a second optional gitapp by pointing at the cilium chart with everything-but-Hubble disabled (`agent: false`, `operator.enabled: false`, etc., plus `hubble.relay.enabled: true` and `hubble.ui.enabled: true`). The chart deployed cleanly without conflicting with the kubespray-managed Cilium agent — but `hubble-relay` crash-looped because kubespray's cilium agent runs with **Hubble disabled at the agent level**:

```
$ kubectl -n kube-system exec ds/cilium -- cilium status | grep -i hubble
Hubble:                  Disabled
```

The `cilium_hubble_*` group_vars I set don't appear to be the canonical names in kubespray release-2.27, so the cilium ConfigMap was generated without `enable-hubble: "true"`. Without Hubble at the agent level, no `hubble-peer` Service exists and the chart-deployed relay has nothing to talk to.

Proper fix: `grep -rE hubble kubespray/roles/network_plugin/cilium/defaults` to find the canonical var names, update `inventory/aranya-takehome/group_vars/k8s_cluster/k8s-cluster.yaml`, re-run `cluster.yml`. Then flip `hubbleui.enabled: true` in `apps/clusterdos/install.yaml` — the gitapp YAML is preserved with `enabled: false` so it's a one-line revert.

---

## What I'd do with more time

- **Real load balancers** in front of both the API (currently per-node, multi-context kubeconfig as workaround) and hello-aranya (currently 3 published public IPs). DO Cloud Controller Manager + `Service: LoadBalancer`.
- **Fix Hubble UI** — find the right kubespray vars, re-run, flip the gitapp.
- **vLLM CPU image baked in CI** with INT8 quantization to actually serve on small nodes.
- **NetworkPolicies** — default-deny in every workload namespace, ReferenceGrants for cross-namespace flows.
- **Real TLS** for hello-aranya via cert-manager + Let's Encrypt once a real DNS name is in play.
- **CI smoke tests** — a workflow that runs the end-to-end checks above against the running cluster.
- **Backups** — Velero + DO Spaces.
- **A Makefile** wrapping the runbook commands so reproduction is `make recon && make cluster && make platform && make hello`.

---

## References

- Kubespray: https://github.com/kubernetes-sigs/kubespray (`release-2.27`, commit `03828c9ffa26fced518cb9ebf7b20cc359412198`)
- ClusterdOS: https://gitlab.com/aranya-tech/public/clusterdos (chart `v0.3.16`)
- ArgoCD: https://github.com/argoproj/argo-cd (`v2.13.2`)
- Cilium: https://github.com/cilium/cilium (`1.15.9`)
- vLLM: https://github.com/vllm-project/vllm
