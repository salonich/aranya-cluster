# 3-node Kubernetes cluster

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

### See the public hello page

Curl at `http://<NODE-IP>/ to see the page. 

### Get cluster admin access

To get cluster access you need:

1. SSH private key for the cluster nodes.

```bash
mv /path/to/given/private-key ~/.ssh/aranya_id_ed25519
chmod 600 ~/.ssh/aranya_id_ed25519
```

2. The `kubeconfig.gpg` file attached to the email.

3. GPG public keys for the kubeconfig recipients (Sasi and Yoofi). Save each block to a file, then import:

```bash
# 1. paste each PGP block into its own file, e.g.:
#      vi /tmp/sasi.asc
#      vi /tmp/yoofi.asc

# 2. import them into your GPG keyring :
gpg --import /tmp/sasi.asc /tmp/yoofi.asc

# 3. verify both appear:
gpg --list-keys sasivarnan619@gmail.com ybquansah@gmail.com
```

4. Decrypt the GPG file to get the kubeconfig:

```bash
# from the directory where you saved the .gpg attachment
gpg --decrypt kubeconfig.gpg > kubeconfig
export KUBECONFIG=$PWD/kubeconfig

# one-shot health check of the whole cluster
bash <(curl -sSL https://raw.githubusercontent.com/salonich/aranya-cluster/main/scripts/verify.sh)

# or just kubectl
kubectl get nodes
kubectl -n argocd get applications
```

The kubeconfig has three contexts, one per node IP. If the node it's currently pointing at is unreachable, switch to another:

```bash
kubectl config use-context aranya-via-node2   # or aranya-via-node3
```

Same client cert and CA are valid against all three.

## Repo layout

```
aranya-cluster/
├── README.md                                # this file
├── inventory/aranya-takehome/               # ansible inventory + group_vars
├── apps/
│   ├── hello-aranya/                        # public nginx
│   ├── clusterdos/install.yaml              # one Argo Application bootstrapping all gitapps
│   └── vllm/                                # TinyLlama deployment
```

---

## How to reproduce

To go end-to-end on a fresh checkout: `make all` runs prereqs through hello-aranya. The detailed steps below are the exact commands behind those targets.

### Prerequisites

#### Tools on the operator machine

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

#### Three nodes

- Ubuntu 24.04, ≥2 vCPU, ≥4 GB RAM, ≥50 GB disk
- Same private VPC subnet
- SSH key-auth to root

### 1. Clone the repo and edit the inventory

```bash
git clone https://github.com/salonich/aranya-cluster.git
cd aranya-cluster
```

Edit `inventory/aranya-takehome/hosts.yaml` to match your node IPs (only needed if reproducing on different droplets).

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

### 7. Apply ClusterdOS

Apply ClusterdOS manifest and verify all applications get into `HEALTHY` state:

```bash
kubectl apply -f apps/clusterdos/install.yaml
kubectl -n argocd get applications 
```

Spawns six sub-Applications: `clusterdos-config`, `clusterdos-certmanager`, `clusterdos-metricsserver`, `clusterdos-nfd`, `clusterdos-sealedsecrets`, `clusterdos-vllm`.

### 8. Apply hello-aranya

```bash
kubectl apply -k apps/hello-aranya/
kubectl -n hello-aranya rollout status daemonset/hello-aranya


# Verify traffic working
for ip in <node1-ip> <node2-ip> <node3-ip>; do
  curl -sS -o /dev/null -w "$ip → HTTP %{http_code}\n" http://$ip
done
```

Expect three `HTTP 200` responses.

## Decisions

1. Every node runs as both a control plane and a worker. With only 3 nodes, splitting roles would have wasted hardware and left one server doing all the cluster-management work — if it died, nothing in the cluster could schedule new pods or change anything. Stacking gives us etcd quorum: as long as any 2 of the 3 nodes are alive, the cluster keeps working.

2. Cilium is the cluster's networking layer. It handles pod-to-pod traffic and network policies using eBPF, which is faster and more observable than the older iptables approach. We left kube-proxy installed alongside it as a safety net. If Cilium ever has a config regression in how it routes Services, kube-proxy's iptables rules still work, and you can run `iptables-save` to see what the kernel thinks should happen. Removing kube-proxy would have been cleaner on paper but gives up that fallback for almost no real benefit at our scale.

3. All cluster-internal traffic — kubelet talking to apiserver, pod talking to pod, etcd between members — runs over the private network at 10.128.0.x. The public NICs on the nodes only carry SSH and the hello-aranya page. This shrinks the attack surface and avoids charging inter-node packets as public egress.

4. There's no single floating IP for the API. The first attempt used kube-vip in ARP mode advertising a private virtual IP. Clean idea, but the cloud's private network silently drops ARP responses for IPs that weren't officially assigned to a node (a common anti-spoofing default in cloud VPCs). The other two nodes never learned the VIP existed. We switched to the pattern kubespray ships by default: each node runs a tiny local nginx that knows how to reach all 3 apiservers, and kubelet just talks to `127.0.0.1:6443`. If one apiserver dies, the local nginx fails over to another. The proper production fix would be a real cloud load balancer in front of the API, but that costs money and needs an API token.

5. The kubeconfig delivered by email has three contexts, one per node IP. kubectl can only point at one server URL at a time and has no built-in failover between alternatives. With three contexts, the recipient can switch with one command (`kubectl config use-context aranya-via-node2`) if a node is unreachable. The same client cert and CA work against all three because the API cert SANs include every public node IP — kubespray pulled them from the inventory's `access_ip` entries.

6. The hello-aranya page doesn't sit behind an ingress controller. An ingress controller is useful when you have multiple services to route between or want to terminate TLS in one place; for a single static page it would just be nginx in front of nginx. Instead, the page is served by a DaemonSet running with `hostNetwork: true` so each pod binds directly to its node's port 80. If a real domain or a second service shows up, a Gateway-API implementation goes in front then.

7. ArgoCD was installed by hand using its upstream pinned manifest, not via ClusterdOS. The reason is bootstrap order: ClusterdOS itself ships as an ArgoCD Application, so something has to install ArgoCD before ClusterdOS can sync. One `kubectl apply` of the official manifest, then ArgoCD takes over from there.

8. The optional extra gitapp is sealed-secrets. It lets us commit encrypted Kubernetes Secret manifests directly to the public git repo; only the in-cluster controller (which holds a private key generated at install time) can decrypt them. The result is that the entire cluster state — including secrets — could live in git without leaking anything to a reader of the public repo. Tiny footprint, fits the security posture set elsewhere.

9. vLLM is installed as a custom gitapp added to ClusterdOS, not via ClusterdOS's built-in `inference` gitapp. The built-in one is hard-locked to NVIDIA GPU (it uses llm-d, which requires the GPU operator) and our cluster is CPU-only — enabling it would have created an Application that endlessly fails to schedule. Instead, we wrote our own vLLM Deployment in `apps/vllm/` and added a custom gitapp pointing at it using the chart's path-based source mode. Same GitOps discipline as the built-in catalog, just with CPU-friendly args.

10. metrics-server runs with `--kubelet-insecure-tls`. The reason: kubespray-installed kubelets serve TLS using self-signed certificates whose SAN list doesn't include the node's IP. metrics-server tries to scrape kubelets by IP, fails the cert handshake, and never goes Ready. The flag tells metrics-server to skip that verification step. In real production you'd instead set `kubelet_rotate_server_certificates: true` in kubespray so the kubelets serve certs signed by the cluster CA, then drop the flag.

11. Ansible is configured to disable SSH connection multiplexing (`ControlMaster=no`, `ControlPath=none`, `ServerAliveInterval=30`). During the cluster install we hit zombie-socket failures three separate times — the SSH process was alive, but the underlying TCP connection had been silently dropped by some intermediary, so ansible just hung waiting on a dead socket. Each task now opens a fresh SSH connection. Slightly slower per task, but no more zombies.

12. The SSH private key for the cluster nodes is never committed. It lives at `~/.ssh/aranya_id_ed25519` on the operator machine and is referenced by absolute path in the ansible config. The `.gitignore` blocks every common key pattern (`*.pem`, `*.key`, `id_*`, `*_ed25519`) and the entire `artifacts/` directory where local kubeconfigs live.

---

## Known limitations

### vLLM doesn't fit on 3.8 GB nodes

vLLM container starts and validates config (we passed `--device=cpu`, `--swap-space=0`, `--dtype=float16` — all working). Then hits OOMKill during model load. Math:

- Container memory limit: 3 Gi
- TinyLlama at float16: ~2.2 GB for weights
- vLLM runtime + tokenizer + KV cache: ~700-900 MB
- Total > 3 GB → kubelet evicts the pod when the node hits its eviction threshold

This is a node-size constraint.

```bash
kubectl -n vllm scale deployment vllm --replicas=1
```

### Hubble UI attempted, scope-cut

Tried to add Hubble UI as a second optional gitapp by pointing at the cilium chart with everything-but-Hubble disabled (`agent: false`, `operator.enabled: false`, etc., plus `hubble.relay.enabled: true` and `hubble.ui.enabled: true`). The chart deployed cleanly without conflicting with the kubespray-managed Cilium agent — but `hubble-relay` crash-looped because kubespray's cilium agent runs with Hubble disabled at the agent level:

```
$ kubectl -n kube-system exec ds/cilium -- cilium status | grep -i hubble
Hubble:                  Disabled
```

The `cilium_hubble_*` group_vars I set don't appear to be the canonical names in kubespray release-2.27, so the cilium ConfigMap was generated without `enable-hubble: "true"`. Without Hubble at the agent level, no `hubble-peer` Service exists and the chart-deployed relay has nothing to talk to. I would have needed to re-run cluster generation using KubeSpray which i avoided due to time limitations.

---

## What I'd do with more time

- A real load balancer in front of the API (so kubectl gets one stable endpoint instead of relying on the multi-context kubeconfig) and another in front of hello-aranya (so the page has one entry point instead of three published node IPs). On any cloud, this is the cloud controller manager plus a `Service: LoadBalancer`.
- Make Hubble UI actually work. The blocker was a kubespray variable name that didn't match the version we used; finding the right one and re-running the playbook would unblock it.
- A vLLM image built for CPU with quantized weights, so the workload actually fits on small nodes instead of being deployed at zero replicas.
- Network policies. Default-deny in every workload namespace, with explicit allow rules for the cross-namespace flows we actually want.
- Real TLS for the hello-aranya page (cert-manager plus a real domain name and a public certificate authority).
- A small CI pipeline that runs the verify script against the running cluster on every push and fails the build on regressions.
- Cluster backups for state and persistent volumes, stored in cheap object storage.

---

## References

- Kubespray: https://github.com/kubernetes-sigs/kubespray (`release-2.27`, commit `03828c9ffa26fced518cb9ebf7b20cc359412198`)
- ClusterdOS: https://gitlab.com/aranya-tech/public/clusterdos (chart `v0.3.16`)
- ArgoCD: https://github.com/argoproj/argo-cd (`v2.13.2`)
- Cilium: https://github.com/cilium/cilium (`1.15.9`)
- vLLM: https://github.com/vllm-project/vllm
