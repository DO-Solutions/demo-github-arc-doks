# GitHub Runner on DOKS Demo - Makefile
#
# Required env vars:
#   DIGITALOCEAN_TOKEN - DigitalOcean API token
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY - For Spaces backend
#   GITHUB_TOKEN - For runner scale set (fine-grained PAT with Actions permissions)

.PHONY: help check-env check-tools tf-init tf-plan tf-apply tf-destroy kubeconfig \
        k8s-foundation arc-controller arc-runner-set pause-pods \
        infra arc deploy status logs-controller logs-listener \
        pause-scale-up pause-scale-down clean-arc clean-all

CLUSTER_NAME := arc-demo-cluster
HELM_CONTROLLER_CHART := oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
HELM_RUNNER_CHART := oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

help:
	@echo "GitHub Runner on DOKS Demo"
	@echo ""
	@echo "Required env vars: DIGITALOCEAN_TOKEN, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
	@echo "For runner-set:    GITHUB_TOKEN"
	@echo ""
	@echo "Infrastructure:"
	@echo "  tf-init       Initialize Terraform"
	@echo "  tf-plan       Plan infrastructure changes"
	@echo "  tf-apply      Apply infrastructure"
	@echo "  tf-destroy    Destroy infrastructure"
	@echo "  kubeconfig    Save and switch to cluster context"
	@echo ""
	@echo "Kubernetes/ARC:"
	@echo "  k8s-foundation  Apply namespaces and priority classes"
	@echo "  arc-controller  Install ARC controller"
	@echo "  arc-runner-set  Install runner scale set (needs GITHUB_TOKEN)"
	@echo "  pause-pods      Deploy pause pods"
	@echo ""
	@echo "Composite:"
	@echo "  infra         Full infra (tf-init + tf-apply + kubeconfig)"
	@echo "  arc           Full ARC (foundation + controller + runners + pause)"
	@echo "  deploy        Complete deployment (infra + arc)"
	@echo ""
	@echo "Operations:"
	@echo "  status        Show cluster status"
	@echo "  logs-controller  Tail controller logs"
	@echo "  logs-listener    Tail listener logs"
	@echo "  pause-scale-up   Scale pause pods to 1"
	@echo "  pause-scale-down Scale pause pods to 0"
	@echo ""
	@echo "Cleanup:"
	@echo "  clean-arc     Uninstall ARC components"
	@echo "  clean-all     Full teardown"

check-env:
	@test -n "$(DIGITALOCEAN_TOKEN)" || (echo "Error: DIGITALOCEAN_TOKEN not set" && exit 1)

check-tools:
	@command -v terraform >/dev/null || (echo "Error: terraform not found" && exit 1)
	@command -v kubectl >/dev/null || (echo "Error: kubectl not found" && exit 1)
	@command -v helm >/dev/null || (echo "Error: helm not found" && exit 1)
	@command -v doctl >/dev/null || (echo "Error: doctl not found" && exit 1)

# Infrastructure targets
tf-init: check-env check-tools
	cd terraform && terraform init

tf-plan: check-env
	cd terraform && terraform plan

tf-apply: check-env
	cd terraform && terraform apply

tf-destroy: check-env
	cd terraform && terraform destroy

kubeconfig:
	doctl kubernetes cluster kubeconfig save $(CLUSTER_NAME)
	kubectl config use-context do-sfo3-$(CLUSTER_NAME)

# Kubernetes/ARC targets
k8s-foundation:
	kubectl apply -f kubernetes/namespaces.yaml
	kubectl apply -f kubernetes/pause-pods/priority-class.yaml

arc-controller:
	helm upgrade --install arc \
		--namespace arc-systems \
		--create-namespace \
		$(HELM_CONTROLLER_CHART) \
		-f kubernetes/arc-controller/values.yaml
	kubectl wait --for=condition=ready pod \
		-l app.kubernetes.io/name=gha-runner-scale-set-controller \
		-n arc-systems --timeout=120s

arc-runner-set:
	@test -n "$(GITHUB_TOKEN)" || (echo "Error: GITHUB_TOKEN not set" && exit 1)
	@kubectl get secret github-arc-secret -n arc-runners 2>/dev/null || \
		kubectl create secret generic github-arc-secret \
			--namespace arc-runners \
			--from-literal=github_token="$(GITHUB_TOKEN)"
	helm upgrade --install arc-runner-set \
		--namespace arc-runners \
		$(HELM_RUNNER_CHART) \
		-f kubernetes/runner-scale-set/values.yaml
	kubectl wait --for=condition=ready pod \
		-l app.kubernetes.io/component=runner-scale-set-listener \
		-n arc-runners --timeout=120s

pause-pods:
	kubectl apply -f kubernetes/pause-pods/deployment.yaml

# Composite targets
infra: tf-init tf-apply kubeconfig

arc: k8s-foundation arc-controller arc-runner-set pause-pods

deploy: infra arc

# Operations targets
status:
	@echo "=== Nodes ==="
	kubectl get nodes -L node-role
	@echo ""
	@echo "=== ARC System Pods ==="
	kubectl get pods -n arc-systems -o wide
	@echo ""
	@echo "=== Runner Pods ==="
	kubectl get pods -n arc-runners -o wide
	@echo ""
	@echo "=== Scale Set ==="
	kubectl get autoscalingrunnerset -n arc-runners

logs-controller:
	kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller -f

logs-listener:
	kubectl logs -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener -f

pause-scale-up:
	kubectl scale deployment pause-pods -n arc-runners --replicas=1

pause-scale-down:
	kubectl scale deployment pause-pods -n arc-runners --replicas=0

# Cleanup targets
clean-arc:
	-helm uninstall arc-runner-set -n arc-runners
	-helm uninstall arc -n arc-systems
	-kubectl delete -f kubernetes/pause-pods/
	-kubectl delete -f kubernetes/namespaces.yaml

clean-all: clean-arc tf-destroy
