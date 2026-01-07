# GitHub Runner on DOKS Demo - Makefile
#
# Required env vars:
#   DIGITALOCEAN_TOKEN - DigitalOcean API token
#   GITHUB_TOKEN - For runner scale set (fine-grained PAT with Actions permissions)

.PHONY: help check-env check-tools tf-init tf-plan tf-apply tf-destroy kubeconfig \
        k8s-foundation arc-controller arc-runner-set arc-runner-set-large pause-pods \
        infra arc deploy status logs-controller logs-listener \
        pause-scale-up pause-scale-down clean-arc clean-all \
        demo-preflight demo-small demo-large demo-docker-build

CLUSTER_NAME := arc-demo-cluster
HELM_CONTROLLER_CHART := oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
HELM_RUNNER_CHART := oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

help:
	@echo "GitHub Runner on DOKS Demo"
	@echo ""
	@echo "Required env vars: DIGITALOCEAN_TOKEN"
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
	@echo "  k8s-foundation       Apply namespaces and priority classes"
	@echo "  arc-controller       Install ARC controller"
	@echo "  arc-runner-set       Install small runner scale set (needs GITHUB_TOKEN)"
	@echo "  arc-runner-set-large Install large runner scale set (needs GITHUB_TOKEN)"
	@echo "  pause-pods           Deploy pause pods"
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
	@echo "Demo:"
	@echo "  demo-preflight     Run pre-demo health checks"
	@echo "  demo-small         Trigger small runner workflow"
	@echo "  demo-large         Trigger large runner workflow"
	@echo "  demo-docker-build  Trigger docker build workflow"
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

arc-runner-set-large:
	@test -n "$(GITHUB_TOKEN)" || (echo "Error: GITHUB_TOKEN not set" && exit 1)
	@kubectl get secret github-arc-secret -n arc-runners 2>/dev/null || \
		kubectl create secret generic github-arc-secret \
			--namespace arc-runners \
			--from-literal=github_token="$(GITHUB_TOKEN)"
	helm upgrade --install arc-runner-set-large \
		--namespace arc-runners \
		$(HELM_RUNNER_CHART) \
		-f kubernetes/runner-scale-set-large/values.yaml

pause-pods:
	kubectl apply -f kubernetes/pause-pods/deployment.yaml

# Composite targets
infra: tf-init tf-apply kubeconfig

arc: k8s-foundation arc-controller arc-runner-set arc-runner-set-large pause-pods

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

# Demo targets
demo-preflight:
	@echo "=== Pre-Demo Preflight Check ==="
	@echo ""
	@echo "Checking cluster health..."
	@kubectl get nodes -L node-role || (echo "FAIL: Cannot reach cluster" && exit 1)
	@echo ""
	@echo "Checking ARC controller..."
	@kubectl get pods -n arc-systems -l app.kubernetes.io/name=gha-rs-controller | grep Running || (echo "FAIL: Controller not running" && exit 1)
	@echo ""
	@echo "Checking listener..."
	@kubectl get pods -n arc-systems -l app.kubernetes.io/component=runner-scale-set-listener | grep Running || (echo "FAIL: Listener not running" && exit 1)
	@echo ""
	@echo "Checking pause pod..."
	@kubectl get pods -n arc-runners -l app=pause-pods | grep Running || (echo "FAIL: Pause pod not running" && exit 1)
	@echo ""
	@echo "Clearing stale pods..."
	-@kubectl delete pods -n arc-runners --field-selector=status.phase=Failed 2>/dev/null || true
	@echo ""
	@echo "=== Preflight Complete ==="

# Demo workflow triggers (using gh CLI)
# gh auto-detects repo from current directory - works with forks
demo-small:
	@echo "Triggering Demo: Small Runner..."
	@gh workflow run "Demo: Small Runner"
	@sleep 2
	@echo "View logs: gh run view $$(gh run list --workflow='Demo: Small Runner' --limit 1 --json databaseId -q '.[0].databaseId') --log"

demo-large:
	@echo "Triggering Demo: Large Runner..."
	@gh workflow run "Demo: Large Runner"
	@sleep 2
	@echo "View logs: gh run view $$(gh run list --workflow='Demo: Large Runner' --limit 1 --json databaseId -q '.[0].databaseId') --log"

demo-docker-build:
	@echo "Triggering Demo: Docker Build..."
	@gh workflow run "Demo: Docker Build"
	@sleep 2
	@echo "View logs: gh run view $$(gh run list --workflow='Demo: Docker Build' --limit 1 --json databaseId -q '.[0].databaseId') --log"
