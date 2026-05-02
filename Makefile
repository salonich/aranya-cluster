# Aranya cluster — Makefile wrapping the runbook.
#
# Each target is one logical step. Run them in order from a fresh checkout, or
# pick the one you need. Variables at the top can be overridden on the command
# line (e.g. `make cluster KUBESPRAY_BRANCH=release-2.28`).

# ---------- variables ----------
SHELL              := /usr/bin/env bash

REPO_DIR           := $(shell pwd)
INVENTORY          := $(REPO_DIR)/inventory/aranya-takehome/hosts.yaml
ARTIFACTS_DIR      := $(REPO_DIR)/artifacts
KUBECONFIG_FILE    := $(ARTIFACTS_DIR)/kubeconfig-public
SSH_KEY            := $(HOME)/.ssh/aranya_id_ed25519

KUBESPRAY_DIR      := $(REPO_DIR)/kubespray
KUBESPRAY_BRANCH   := release-2.27
KUBESPRAY_COMMIT   := 03828c9ffa26fced518cb9ebf7b20cc359412198

ARGOCD_VERSION     := v2.13.2

NODE1_PUBLIC       := 134.199.196.192
NODE2_PUBLIC       := 129.212.186.30
NODE3_PUBLIC       := 134.199.204.141

# Recipients for the encrypted kubeconfig delivery.
GPG_RECIPIENTS     := -r sasivarnan619@gmail.com -r ybquansah@gmail.com

export KUBECONFIG  := $(KUBECONFIG_FILE)
export ANSIBLE_CONFIG := $(KUBESPRAY_DIR)/ansible.cfg

# ---------- top-level ----------
.PHONY: help
help:
	@echo "make ping          - sanity-ping all 3 nodes via ansible"
	@echo "make kubespray     - clone + pin kubespray and install python deps"
	@echo "make swap-off      - disable swap on every node (kubespray prereq)"
	@echo "make cluster       - run kubespray cluster.yml"
	@echo "make kubeconfig    - fetch admin.conf, rewrite for public node IP"
	@echo "make argocd        - install pinned ArgoCD"
	@echo "make clusterdos    - apply ClusterdOS install.yaml (gitapps sync via Argo)"
	@echo "make hello         - apply hello-aranya manifests"
	@echo "make verify        - run end-to-end verify.sh against the cluster"
	@echo "make encrypt       - GPG-encrypt artifacts/kubeconfig-public for delivery"
	@echo "make all           - kubespray bring-up to public hello page (no encrypt)"
	@echo "make clean         - remove local kubespray clone and artifacts/"

.PHONY: all
all: kubespray swap-off cluster kubeconfig argocd clusterdos hello verify

# ---------- prereqs ----------
.PHONY: kubespray
kubespray:
	@if [ ! -d "$(KUBESPRAY_DIR)" ]; then \
	  git clone --branch $(KUBESPRAY_BRANCH) https://github.com/kubernetes-sigs/kubespray.git $(KUBESPRAY_DIR); \
	fi
	cd $(KUBESPRAY_DIR) && git checkout $(KUBESPRAY_COMMIT)
	pip3 install --user -r $(KUBESPRAY_DIR)/requirements.txt

.PHONY: ping
ping:
	ansible -i $(INVENTORY) all -m ping

.PHONY: swap-off
swap-off:
	ansible -i $(INVENTORY) all -b -m shell -a "swapoff -a && sed -i '/swap/s/^/#/' /etc/fstab"

# ---------- cluster bring-up ----------
.PHONY: cluster
cluster: ping swap-off
	cd $(KUBESPRAY_DIR) && ansible-playbook -i $(INVENTORY) --become cluster.yml

.PHONY: reset
reset:
	cd $(KUBESPRAY_DIR) && ansible-playbook -i $(INVENTORY) --become reset.yml

# ---------- kubectl access ----------
.PHONY: kubeconfig
kubeconfig:
	mkdir -p $(ARTIFACTS_DIR)
	scp -i $(SSH_KEY) -o StrictHostKeyChecking=accept-new \
	  root@$(NODE1_PUBLIC):/etc/kubernetes/admin.conf $(ARTIFACTS_DIR)/kubeconfig
	cp $(ARTIFACTS_DIR)/kubeconfig $(KUBECONFIG_FILE)
	sed -i 's|server: https://127.0.0.1:6443|server: https://$(NODE1_PUBLIC):6443|' $(KUBECONFIG_FILE)
	@echo "wrote $(KUBECONFIG_FILE)"
	kubectl get nodes

# ---------- platform layer ----------
.PHONY: argocd
argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd \
	  -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
	kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
	kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

.PHONY: clusterdos
clusterdos:
	kubectl apply -f $(REPO_DIR)/apps/clusterdos/install.yaml
	@echo "watch sync with: kubectl -n argocd get applications -w"

# ---------- workload ----------
.PHONY: hello
hello:
	kubectl apply -k $(REPO_DIR)/apps/hello-aranya/
	kubectl -n hello-aranya rollout status daemonset/hello-aranya --timeout=120s
	@for ip in $(NODE1_PUBLIC) $(NODE2_PUBLIC) $(NODE3_PUBLIC); do \
	  printf "%s -> " "$$ip"; \
	  curl -sS -o /dev/null -w "HTTP %{http_code}\n" -m 5 http://$$ip; \
	done

# ---------- verify + deliver ----------
.PHONY: verify
verify:
	bash $(REPO_DIR)/scripts/verify.sh

.PHONY: encrypt
encrypt:
	gpg --trust-model always --encrypt --armor \
	  $(GPG_RECIPIENTS) \
	  --output $(ARTIFACTS_DIR)/kubeconfig-public.gpg \
	  $(KUBECONFIG_FILE)
	@echo "encrypted kubeconfig at $(ARTIFACTS_DIR)/kubeconfig-public.gpg (attach to email)"

# ---------- cleanup ----------
.PHONY: clean
clean:
	rm -rf $(KUBESPRAY_DIR) $(ARTIFACTS_DIR)
