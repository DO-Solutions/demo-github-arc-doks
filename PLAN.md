# GitHub Runner on DOKS Demo - Implementation Plan

## Overview

This plan implements the demo environment specified in `SPEC.md` based on the architecture defined in `PROJECT.pdf`. The demo showcases GitHub Actions Runner Controller (ARC) on DigitalOcean Kubernetes Service (DOKS) for a customer migrating from AWS ECS.

### Configuration Summary

| Setting | Value |
|---------|-------|
| Region | sfo3 |
| GitHub Auth | Personal Access Token (fine-grained) |
| Terraform Backend | DO Spaces: `jkeegan-solutions-tf-state` (sfo3) |
| Observability | Skipped for demo |
| Runner Scope | Repository level |

### How to Use This Plan

**Phase Execution = Deployment + Verification**

When executing a phase, completion requires:
1. **Create all files** listed in "Files to Create"
2. **Run all commands** in "Deployment Steps"
3. **Verify each item** in "Verification Checklist" and mark it `[x]` when confirmed

A phase is NOT complete until every checklist item has been verified and checked off. If a verification step fails, troubleshoot and resolve before proceeding to the next phase.

**Checklist Syntax:**
- `[ ]` = Not yet verified
- `[x]` = Verified and passing

---

### Repository Structure (Target)

```
github-runner-doks-demo/
├── terraform/
│   ├── backend.tf
│   ├── versions.tf
│   ├── providers.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── vpc.tf
│   ├── doks.tf
│   ├── nat-gateway.tf
│   └── docr.tf
├── kubernetes/
│   ├── namespaces.yaml
│   ├── arc-controller/
│   │   └── values.yaml
│   ├── runner-scale-set/
│   │   └── values.yaml
│   └── pause-pods/
│       ├── priority-class.yaml
│       └── deployment.yaml
├── .github/
│   └── workflows/
│       ├── demo-instant-pickup.yaml
│       ├── demo-graceful-scaling.yaml
│       ├── demo-docker-build.yaml
│       └── demo-burst-scaling.yaml
├── demo-app/
│   ├── Dockerfile
│   └── entrypoint.sh
├── docs/
│   ├── demo-script.md
│   └── post-demo-handoff.md
├── PLAN.md
├── SPEC.md
└── README.md
```

---

## Phase 1: Infrastructure (Terraform)

### Objective
Set up the project structure, configure Terraform backend, and deploy all DigitalOcean infrastructure: VPC, DOKS cluster with node pools, NAT Gateway, and Container Registry.

### Prerequisites (Manual Steps Before Starting)

1. **Environment Variables**: Source the environment file before running any commands:
   ```bash
   source /home/jjk3/env/do-solutions.env
   ```
   This provides: `DO_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (for Spaces)

2. **GitHub PAT**: Create a fine-grained Personal Access Token:
   - Go to GitHub Settings > Developer Settings > Personal Access Tokens > Fine-grained tokens
   - Repository access: Select the target demo repository
   - Permissions required:
     - `Actions`: Read and Write
     - `Administration`: Read and Write
     - `Metadata`: Read
   - Save the token securely

3. **Local Tools**:
   - `doctl` CLI authenticated (`doctl auth init`)
   - `kubectl` >= 1.28
   - `terraform` >= 1.5.0
   - `helm` >= 3.12.0

### Files to Create

#### `terraform/backend.tf`
```hcl
terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://sfo3.digitaloceanspaces.com"
    }
    bucket                      = "jkeegan-solutions-tf-state"
    key                         = "github-runner-doks-demo/terraform.tfstate"
    region                      = "us-east-1"  # Required but ignored by DO
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}
```

#### `terraform/versions.tf`
```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.34"
    }
  }
}
```

#### `terraform/variables.tf`
```hcl
variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "sfo3"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "arc-demo"
}

variable "kubernetes_version" {
  description = "DOKS Kubernetes version prefix"
  type        = string
  default     = "1.31"
}
```

#### `terraform/providers.tf`
```hcl
provider "digitalocean" {
  token = var.do_token
}
```

#### `terraform/vpc.tf`
```hcl
resource "digitalocean_vpc" "main" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = "10.100.0.0/16"
}
```

#### `terraform/doks.tf`
```hcl
data "digitalocean_kubernetes_versions" "current" {
  version_prefix = var.kubernetes_version
}

resource "digitalocean_kubernetes_cluster" "main" {
  name     = "${var.project_name}-cluster"
  region   = var.region
  version  = data.digitalocean_kubernetes_versions.current.latest_version
  vpc_uuid = digitalocean_vpc.main.id

  # Management node pool - fixed size for ARC controller and listeners
  node_pool {
    name       = "management"
    size       = "s-2vcpu-4gb"
    node_count = 2

    labels = {
      "node-role" = "management"
    }

    taint {
      key    = "node-role"
      value  = "management"
      effect = "NoSchedule"
    }
  }

  maintenance_policy {
    day        = "sunday"
    start_time = "04:00"
  }
}

# Job node pool - autoscaling for runner pods
resource "digitalocean_kubernetes_node_pool" "jobs" {
  cluster_id = digitalocean_kubernetes_cluster.main.id
  name       = "jobs"
  size       = "s-2vcpu-4gb"
  min_nodes  = 1
  max_nodes  = 3
  auto_scale = true

  labels = {
    "node-role" = "jobs"
  }

  taint {
    key    = "node-role"
    value  = "jobs"
    effect = "NoSchedule"
  }
}
```

#### `terraform/nat-gateway.tf`
```hcl
# NAT Gateway for static egress IP
# Note: Full NAT Gateway support requires doctl - see deployment steps
resource "digitalocean_reserved_ip" "nat" {
  region = var.region
}

output "nat_gateway_instructions" {
  description = "Instructions for NAT Gateway setup"
  value = <<-EOT
    Create NAT Gateway after cluster is ready:

    doctl compute nat-gateway create \
      --name ${var.project_name}-nat \
      --vpc-uuid ${digitalocean_vpc.main.id} \
      --region ${var.region}

    Note the public IP for GitHub Enterprise whitelisting.
  EOT
}
```

#### `terraform/docr.tf`
```hcl
resource "digitalocean_container_registry" "main" {
  name                   = "${var.project_name}-registry"
  subscription_tier_slug = "basic"
  region                 = var.region
}

resource "digitalocean_container_registry_docker_credentials" "main" {
  registry_name = digitalocean_container_registry.main.name
}
```

#### `terraform/outputs.tf`
```hcl
output "cluster_id" {
  description = "DOKS cluster ID"
  value       = digitalocean_kubernetes_cluster.main.id
}

output "cluster_name" {
  description = "DOKS cluster name"
  value       = digitalocean_kubernetes_cluster.main.name
}

output "cluster_endpoint" {
  description = "DOKS cluster API endpoint"
  value       = digitalocean_kubernetes_cluster.main.endpoint
  sensitive   = true
}

output "kubeconfig" {
  description = "kubectl config for the cluster"
  value       = digitalocean_kubernetes_cluster.main.kube_config[0].raw_config
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID for NAT Gateway setup"
  value       = digitalocean_vpc.main.id
}

output "registry_endpoint" {
  description = "DOCR endpoint"
  value       = digitalocean_container_registry.main.endpoint
}

output "registry_credentials" {
  description = "DOCR docker credentials JSON"
  value       = digitalocean_container_registry_docker_credentials.main.docker_credentials
  sensitive   = true
}
```

### Deployment Steps
```bash
# Source environment variables (sets DIGITALOCEAN_TOKEN, AWS credentials for Spaces)
source /home/jjk3/env/do-solutions.env

cd terraform

# Initialize Terraform backend
terraform init

# Plan and review (no -var needed, uses DIGITALOCEAN_TOKEN env var)
terraform plan

# Apply infrastructure (takes ~5-10 minutes)
terraform apply

# Get kubeconfig
terraform output -raw kubeconfig > ~/.kube/arc-demo-config
export KUBECONFIG=~/.kube/arc-demo-config

# Verify cluster access
kubectl get nodes

# NAT Gateway is created automatically by Terraform
# Get the NAT Gateway public IP for whitelisting:
terraform output nat_gateway_ip
```

### Verification Checklist (verify each item and mark `[x]` when confirmed)
- [x] Terraform initialized successfully
- [x] VPC created in sfo3
- [x] DOKS cluster running with 2 management nodes
- [x] Job node pool with 1 node (autoscale 1-3)
- [x] NAT Gateway created with public IP
- [x] DOCR registry created
- [x] `kubectl get nodes` shows 3 nodes Ready

### Implementation Notes (Differences from Original Plan)

The following changes were made during Phase 1 implementation:

| Original Plan | Actual Implementation | Impact on Future Phases |
|--------------|----------------------|------------------------|
| VPC IP range: `10.100.0.0/16` | Changed to `10.200.0.0/16` | None - internal networking unchanged |
| NAT Gateway: Manual creation via `doctl` | Fully managed by Terraform (`digitalocean_vpc_nat_gateway` resource) | None - simplifies deployment |
| DOCR: Create new registry | Uses existing ``do-solutions-sfo3`` registry (TF provider doesn't support multi-registry API) | Docker build demo will push to existing registry |
| Provider auth: `var.do_token` | Uses `DIGITALOCEAN_TOKEN` env var | Simpler - no `-var` flag needed |
| Provider version: `~> 2.34` | Updated to `~> 2.72` | Access to VPC-native DOKS features |
| DOKS version: `var.kubernetes_version = 1.31` | Dynamic latest (currently 1.35.0) | Variable removed |
| DOKS networking: default subnets | VPC-native with `cluster_subnet=10.201.0.0/20`, `service_subnet=10.202.0.0/20` | All CIDRs configurable via variables |
| `doctl` context | Must use `solutions` context (`doctl auth switch --context solutions`) | Ensure correct context before doctl commands |

**NAT Gateway IP for GitHub Enterprise whitelisting:** `129.212.166.5`
**Registry endpoint:** `registry.digitalocean.com/do-solutions-sfo3`

---

## Phase 2: Kubernetes Foundation & ARC Controller

### Objective
Set up namespaces, priority classes, and deploy the ARC controller on management nodes.

### Files to Create

#### `kubernetes/namespaces.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: arc-systems
  labels:
    app.kubernetes.io/part-of: arc
---
apiVersion: v1
kind: Namespace
metadata:
  name: arc-runners
  labels:
    app.kubernetes.io/part-of: arc
```

#### `kubernetes/pause-pods/priority-class.yaml`
```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: pause-pods
value: -10
globalDefault: false
preemptionPolicy: Never
description: "Low priority class for pause pods - preempted by runner pods"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: arc-runner
value: 100
globalDefault: false
preemptionPolicy: PreemptLowerPriority
description: "High priority for ARC runner pods - preempts pause pods"
```

#### `kubernetes/arc-controller/values.yaml`
```yaml
# ARC Controller Helm values
# Chart: oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

replicaCount: 1

# Run on management nodes only
nodeSelector:
  node-role: management

tolerations:
  - key: "node-role"
    operator: "Equal"
    value: "management"
    effect: "NoSchedule"

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

metrics:
  controllerManagerAddr: ":8080"
  listenerAddr: ":8081"

logLevel: info
```

### Deployment Steps
```bash
# Apply namespaces and priority classes
kubectl apply -f kubernetes/namespaces.yaml
kubectl apply -f kubernetes/pause-pods/priority-class.yaml

# Install ARC controller
helm install arc \
  --namespace arc-systems \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  -f kubernetes/arc-controller/values.yaml

# Wait for controller to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=gha-runner-scale-set-controller \
  -n arc-systems \
  --timeout=120s

# Verify
kubectl get namespaces | grep arc
kubectl get priorityclasses | grep -E "(pause|arc)"
kubectl get pods -n arc-systems
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller
```

### Verification Checklist (verify each item and mark `[x]` when confirmed)
- [x] Namespace `arc-systems` exists
- [x] Namespace `arc-runners` exists
- [x] PriorityClass `pause-pods` with value -10
- [x] PriorityClass `arc-runner` with value 100
- [x] ARC controller pod running in `arc-systems` namespace
- [x] Controller pod scheduled on management node
- [x] No errors in controller logs

### Implementation Notes (Differences from Original Plan)

The following changes were made during Phase 2 implementation:

| Original Plan | Actual Implementation | Reason |
|--------------|----------------------|--------|
| Management nodes tainted | No taint on management nodes | System pods (konnectivity-agent, coredns, etc.) need to schedule somewhere |
| Tolerations in ARC values | No tolerations needed | Management nodes no longer tainted |
| K8s version 1.35 (dev) | K8s version 1.34.1-do.2 | Dev build had kubelet HTTP/HTTPS issues |
| Cluster subnet 10.201.0.0/20 | 10.240.0.0/16 | Original CIDR conflicted with existing VPC |
| Service subnet 10.202.0.0/20 | 10.241.0.0/16 | Updated to match new cluster subnet range |

---

## Phase 3: Runner Scale Set & Pause Pods

### Objective
Deploy the runner scale set connected to GitHub and configure pause pods for warm capacity.

### Prerequisites
- GitHub PAT ready (from Prerequisites)
- Know your target repository URL (e.g., `https://github.com/YOUR_ORG/YOUR_REPO`)

### Files to Create

#### `kubernetes/runner-scale-set/values.yaml`
```yaml
# ARC Runner Scale Set Helm values
# Chart: oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
#
# UPDATE: githubConfigUrl before deploying

githubConfigUrl: "https://github.com/YOUR_ORG/YOUR_REPO"
githubConfigSecret: github-arc-secret

runnerScaleSetName: "doks-demo"

minRunners: 0
maxRunners: 10

containerMode:
  type: dind

template:
  spec:
    nodeSelector:
      node-role: jobs
    tolerations:
      - key: "node-role"
        operator: "Equal"
        value: "jobs"
        effect: "NoSchedule"
    priorityClassName: arc-runner
    containers:
      - name: runner
        resources:
          limits:
            cpu: "1500m"
            memory: "3Gi"
          requests:
            cpu: "500m"
            memory: "1Gi"

listenerTemplate:
  spec:
    nodeSelector:
      node-role: management
    tolerations:
      - key: "node-role"
        operator: "Equal"
        value: "management"
        effect: "NoSchedule"
```

#### `kubernetes/pause-pods/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pause-pods
  namespace: arc-runners
  labels:
    app: pause-pods
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pause-pods
  template:
    metadata:
      labels:
        app: pause-pods
    spec:
      priorityClassName: pause-pods
      nodeSelector:
        node-role: jobs
      tolerations:
        - key: "node-role"
          operator: "Equal"
          value: "jobs"
          effect: "NoSchedule"
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              # ~90% of s-2vcpu-4gb allocatable
              cpu: "1700m"
              memory: "3Gi"
            limits:
              cpu: "1700m"
              memory: "3Gi"
```

### Deployment Steps
```bash
# Create GitHub secret (replace with your PAT)
kubectl create secret generic github-arc-secret \
  --namespace arc-runners \
  --from-literal=github_token="ghp_YOUR_GITHUB_PAT_HERE"

# Update values.yaml with your repository URL, then deploy runner scale set
helm install arc-runner-set \
  --namespace arc-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f kubernetes/runner-scale-set/values.yaml

# Wait for listener to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/component=runner-scale-set-listener \
  -n arc-runners \
  --timeout=120s

# Deploy pause pods
kubectl apply -f kubernetes/pause-pods/deployment.yaml

# Verify all components
kubectl get pods -n arc-runners -o wide
kubectl get autoscalingrunnerset -n arc-runners
```

### Verification Checklist (verify each item and mark `[x]` when confirmed)
- [x] GitHub secret created in `arc-runners` namespace
- [x] Runner scale set listener pod running
- [x] Listener pod on management node
- [x] Pause pod running on job node
- [x] `kubectl get autoscalingrunnerset` shows the scale set
- [x] GitHub UI: Settings > Actions > Runners shows "doks-demo" registered (scale set registered via listener, runners spawn on-demand)

### Implementation Notes (Differences from Original Plan)

| Original Plan | Actual Implementation | Reason |
|--------------|----------------------|--------|
| Listener tolerations for management taint | No tolerations for listener | Management nodes untainted (per Phase 2) |
| Placeholder repo URL | `https://github.com/DO-Solutions/demo-github-arc-doks` | Confirmed target repo |
| Pause pod resources: 1700m CPU, 3Gi mem | 1300m CPU, 2Gi mem | System pods consume ~522m CPU, 505Mi on jobs nodes |
| listenerTemplate.spec with nodeSelector | Removed listenerTemplate | Helm chart requires containers when spec is defined; listener naturally schedules on management (only untainted nodes) |

**SAML SSO Note:** The DO-Solutions org requires SAML SSO authorization for PATs. Token must be authorized at: GitHub Settings > Developer settings > PATs > Configure SSO.

---

## Phase 4: Demo Workflows

### Objective
Create the four GitHub Actions workflows demonstrating each customer pain point being solved.

### Registry Note
The Docker build demo uses the existing registry `do-solutions-sfo3`. If pushing images to DOCR is needed:
- Registry endpoint: `registry.digitalocean.com/do-solutions-sfo3`
- Get docker credentials: `doctl registry docker-config`
- Login: `doctl registry login`

### Files to Create

#### `.github/workflows/demo-instant-pickup.yaml`
```yaml
name: "Demo: Instant Job Pickup"

on:
  workflow_dispatch:

jobs:
  instant-pickup:
    runs-on: [self-hosted, doks-demo]
    steps:
      - name: Record start time
        run: |
          echo "============================================"
          echo "  DEMO: Instant Job Pickup"
          echo "============================================"
          echo ""
          echo "Job started at: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
          echo ""
          echo "This job demonstrates sub-second pickup when"
          echo "warm capacity (pause pods) is available."
          echo ""

      - name: Quick task
        run: |
          echo "Running a quick task..."
          sleep 5
          echo "Task complete!"

      - name: Record end time
        run: |
          echo ""
          echo "Job completed at: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
          echo ""
          echo "SUCCESS: Job picked up instantly by preempting pause pod."
```

#### `.github/workflows/demo-graceful-scaling.yaml`
```yaml
name: "Demo: Graceful Scaling (Long-Running)"

on:
  workflow_dispatch:

jobs:
  long-running:
    runs-on: [self-hosted, doks-demo]
    steps:
      - name: Start long-running job
        run: |
          echo "============================================"
          echo "  DEMO: Graceful Scaling"
          echo "============================================"
          echo ""
          echo "Job started at: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
          echo ""
          echo "This job runs for 3 minutes to demonstrate"
          echo "that active runners are NEVER terminated."
          echo ""
          echo "Unlike ECS, ARC tracks runner state via GitHub API."
          echo "Scale-down only targets idle runners."
          echo ""

      - name: Simulate work (3 minutes)
        run: |
          for i in {1..18}; do
            echo "[$(date -u +%H:%M:%S)] Still running... iteration $i/18"
            sleep 10
          done

      - name: Complete
        run: |
          echo ""
          echo "Job completed at: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
          echo ""
          echo "SUCCESS: Runner was NEVER interrupted during execution."
          echo "The runner will now terminate gracefully."
```

#### `.github/workflows/demo-docker-build.yaml`
```yaml
name: "Demo: Docker Build"

on:
  workflow_dispatch:

jobs:
  docker-build:
    runs-on: [self-hosted, doks-demo]
    steps:
      - name: Introduction
        run: |
          echo "============================================"
          echo "  DEMO: Docker Build (DinD)"
          echo "============================================"
          echo ""
          echo "This job demonstrates Docker-in-Docker support."
          echo "Existing workflows work WITHOUT modification."
          echo ""

      - name: Checkout code
        uses: actions/checkout@v4

      - name: Verify Docker availability
        run: |
          echo "Docker version:"
          docker version
          echo ""
          echo "Docker info (abbreviated):"
          docker info | head -20

      - name: Build demo application
        run: |
          echo ""
          echo "Building demo-app Docker image..."
          docker build -t demo-app:latest ./demo-app
          echo ""
          echo "Build complete!"

      - name: List built image
        run: |
          echo "Successfully built image:"
          docker images demo-app:latest
          echo ""

      - name: Run container test
        run: |
          echo "Running container..."
          echo ""
          docker run --rm demo-app:latest
          echo ""
          echo "SUCCESS: Docker commands work inside runner pod."
```

#### `.github/workflows/demo-burst-scaling.yaml`
```yaml
name: "Demo: Burst Scaling"

on:
  workflow_dispatch:

jobs:
  burst:
    runs-on: [self-hosted, doks-demo]
    strategy:
      matrix:
        job: [1, 2, 3, 4, 5]
      fail-fast: false
    steps:
      - name: Job start
        run: |
          echo "============================================"
          echo "  DEMO: Burst Scaling - Job ${{ matrix.job }}/5"
          echo "============================================"
          echo ""
          echo "Started at: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
          echo "Running on: $(hostname)"
          echo ""
          echo "First job gets warm capacity (instant)."
          echo "Additional jobs trigger cluster autoscaler."
          echo ""

      - name: Simulate work (60-90 seconds)
        run: |
          DURATION=$((60 + RANDOM % 30))
          echo "This job will run for ~$DURATION seconds..."
          echo ""
          for i in $(seq 1 $((DURATION / 10))); do
            echo "[$(date -u +%H:%M:%S)] Job ${{ matrix.job }} working... ($((i * 10))s)"
            sleep 10
          done

      - name: Complete
        run: |
          echo ""
          echo "Job ${{ matrix.job }} completed at: $(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
          echo ""
          echo "SUCCESS: Job completed regardless of node it landed on."
```

### Verification Checklist (verify each item and mark `[x]` when confirmed)
- [x] All four workflow files created in `.github/workflows/`
- [x] Push to GitHub and verify workflows appear in Actions tab
- [x] Each workflow shows "Run workflow" button (workflow_dispatch)
- [x] demo-instant-pickup: Completed successfully
- [x] demo-graceful-scaling: Completed successfully (3m23s)
- [x] demo-docker-build: Built and ran container successfully
- [x] demo-burst-scaling: 5 concurrent jobs completed, node scaling triggered (1→3 nodes)

### Implementation Notes (Differences from Original Plan)

| Original Plan | Actual Implementation | Reason |
|--------------|----------------------|--------|
| `runs-on: [self-hosted, doks-demo]` | `runs-on: doks-demo` | Array syntax not matched by ARC listener |

---

## Phase 5: Demo Application

### Objective
Create a simple application for the Docker build demo.

### Files to Create

#### `demo-app/Dockerfile`
```dockerfile
FROM alpine:3.19

LABEL maintainer="DigitalOcean Solutions"
LABEL description="Simple demo app for GitHub Runner DOKS demo"

RUN apk add --no-cache curl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

#### `demo-app/entrypoint.sh`
```bash
#!/bin/sh
echo "============================================"
echo "  Demo App Running Successfully!"
echo "============================================"
echo ""
echo "This container was built by a GitHub Actions"
echo "runner on DigitalOcean Kubernetes (DOKS)"
echo "using Docker-in-Docker (DinD) mode."
echo ""
echo "Build timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Hostname: $(hostname)"
echo ""
echo "Your existing Docker workflows work without"
echo "modification on this platform."
echo ""
```

### Verification Checklist (verify each item and mark `[x]` when confirmed)
- [x] `demo-app/Dockerfile` created
- [x] `demo-app/entrypoint.sh` created
- [x] Docker build tested via demo-docker-build workflow (builds and runs successfully in runner)

---

## Phase 6: Documentation

### Objective
Create demo script and customer handoff documentation.

### Files to Create

#### `docs/demo-script.md`
```markdown
# Demo Script: GitHub Runners on DOKS

## Pre-Demo Checklist (Day Before)

- [ ] Verify cluster health: `kubectl get nodes`
- [ ] Verify ARC controller: `kubectl get pods -n arc-systems`
- [ ] Verify listener running: `kubectl get pods -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener`
- [ ] Verify pause pod running: `kubectl get pods -n arc-runners -l app=pause-pods`
- [ ] Run each workflow once to confirm functionality
- [ ] Clear stale pods: `kubectl delete pods -n arc-runners --field-selector=status.phase=Failed`

## Terminal Setup

Open three terminal windows side-by-side:

```bash
# Terminal 1: Watch nodes
watch -n2 'kubectl get nodes -L node-role'

# Terminal 2: Watch runner pods
watch -n1 'kubectl get pods -n arc-runners -o wide'

# Terminal 3: Watch events
kubectl get events -n arc-runners -w
```

## Demo Flow (60 minutes)

### Opening (5 min)
- Recap customer pain points from their ECS experience
- Set expectations: "You'll see each problem solved live"

### Architecture Walkthrough (10 min)
- Show architecture diagram from PROJECT.pdf
- Explain flow: GitHub → Listener → Controller → Runner → Termination
- Key message: "ARC knows which runners are busy - ECS doesn't"

### Environment Tour (10 min)

```bash
# Show node separation
kubectl get nodes -L node-role

# Show ARC components
kubectl get pods -n arc-systems -o wide
kubectl get pods -n arc-runners -o wide

# Show scale set registration
kubectl get autoscalingrunnerset -n arc-runners
```

### Demo 1: Instant Job Pickup (8 min)

1. Show pause pod running: `kubectl get pods -n arc-runners -l app=pause-pods`
2. Open GitHub Actions UI
3. Trigger `demo-instant-pickup` workflow
4. Watch Terminal 2: pause pod evicted, runner starts instantly
5. Key metric: Job pickup < 2 seconds
6. Compare: "Your ECS cold-start is minutes, this is seconds"

### Demo 2: Graceful Scaling (10 min)

1. Trigger `demo-graceful-scaling` workflow
2. Show runner pod running: `kubectl get pods -n arc-runners`
3. Explain: "This runner will run for 3 minutes"
4. Show: "ARC tracks this via GitHub API - it knows the job is active"
5. Discuss: "In ECS, this could be killed during scale-down"
6. Wait for completion
7. Show: "Runner terminated only AFTER reporting complete to GitHub"

### Demo 3: Docker Build (5 min)

1. Trigger `demo-docker-build` workflow
2. Point out DinD in job logs
3. Show successful build
4. Key message: "Your existing workflows work without modification"

### Demo 4: Burst Scaling (7 min)

1. Trigger `demo-burst-scaling` workflow
2. Watch Terminal 2: First job instant (takes pause pod's spot)
3. Watch Terminal 1: New nodes provisioning (60-90 seconds)
4. Show all 5 jobs completing successfully
5. Key message: "Automatic scaling, no custom scripts"

### Q&A (5 min)
- Address questions
- Discuss next steps

## Useful Commands During Demo

```bash
# Quick pod status
kubectl get pods -n arc-runners -o wide

# Describe scale set
kubectl describe autoscalingrunnerset -n arc-runners

# Check node scaling
kubectl get nodes -w

# View runner logs
kubectl logs -n arc-runners -l actions.github.com/scale-set-name=doks-demo -f
```
```

#### `docs/post-demo-handoff.md`
```markdown
# Post-Demo Reference Guide

## What Was Demonstrated

| Customer Pain Point | Solution | Demo Workflow |
|---------------------|----------|---------------|
| Job failures during scale-down | ARC runner-aware scaling | Graceful Scaling |
| Cold-start latency (minutes) | Pause pod warm capacity | Instant Pickup |
| Docker build support needed | DinD container mode | Docker Build |
| Complex custom scaling logic | Native K8s + ARC | Burst Scaling |

## Architecture Components

| Component | Purpose | Location |
|-----------|---------|----------|
| ARC Controller | Manages all runner scale sets | arc-systems namespace |
| Listener Pod | Maintains connection to GitHub | arc-systems namespace |
| Runner Pods | Ephemeral, one per job | arc-runners namespace |
| Pause Pods | Maintain warm node capacity | arc-runners namespace |
| NAT Gateway | Static egress IP for whitelisting | VPC level |

## Key Resources

- [ARC Documentation](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller)
- [DOKS Documentation](https://docs.digitalocean.com/products/kubernetes/)
- [NAT Gateway Documentation](https://docs.digitalocean.com/products/networking/vpc/how-to/configure-nat-gateway/)
- [DOCR Documentation](https://docs.digitalocean.com/products/container-registry/)

## Production Considerations

### Authentication
- Replace PAT with GitHub App for production
- GitHub App provides better audit trail and fine-grained permissions

### Multi-Organization Support
- Each org gets dedicated namespace: `arc-runners-{org}`
- Separate GitHub credentials per org
- Single ARC controller manages all scale sets

### Scaling Tuning
- Adjust pause pod replicas based on concurrent job patterns
- Monitor queue depth to right-size warm capacity
- Consider time-based scaling with KEDA for business hours

### Observability
- Add Prometheus for ARC metrics
- Configure alerts for queue depth, pod failures
- Consider Grafana dashboards for visibility

## Next Steps

1. **GitHub App Setup**: Create GitHub App with required permissions
2. **Repository Configuration**: Point runner scale set at production repos
3. **Observability**: Discuss monitoring integration requirements
4. **Migration Planning**: Parallel run vs cutover strategy
```

#### `README.md`
```markdown
# GitHub Runner on DOKS Demo

This repository demonstrates GitHub Actions self-hosted runners on DigitalOcean Kubernetes Service (DOKS) using Actions Runner Controller (ARC).

## Documentation

| Document | Purpose |
|----------|---------|
| `PROJECT.pdf` | Full architecture design |
| `SPEC.md` | Demo environment specification |
| `PLAN.md` | Implementation phases |
| `docs/demo-script.md` | Demo meeting guide |
| `docs/post-demo-handoff.md` | Customer reference |

## Quick Start

### Prerequisites
- DigitalOcean account with API token
- GitHub PAT with Actions permissions
- `doctl`, `kubectl`, `terraform`, `helm` installed

### Deploy Infrastructure
```bash
# Ensure environment variables are set:
# - DO_TOKEN (DigitalOcean API token)
# - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (for Spaces backend)

cd terraform
terraform init
terraform apply -var="do_token=$DO_TOKEN"

# Get kubeconfig
terraform output -raw kubeconfig > ~/.kube/arc-demo
export KUBECONFIG=~/.kube/arc-demo
```

### Deploy ARC
```bash
# Foundation
kubectl apply -f kubernetes/namespaces.yaml
kubectl apply -f kubernetes/pause-pods/priority-class.yaml

# Controller
helm install arc \
  --namespace arc-systems \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  -f kubernetes/arc-controller/values.yaml

# Runners (create secret first)
kubectl create secret generic github-arc-secret \
  --namespace arc-runners \
  --from-literal=github_token="ghp_YOUR_TOKEN"

helm install arc-runner-set \
  --namespace arc-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -f kubernetes/runner-scale-set/values.yaml

# Pause pods
kubectl apply -f kubernetes/pause-pods/deployment.yaml
```

## Demo Workflows

| Workflow | Purpose | Demonstrates |
|----------|---------|--------------|
| demo-instant-pickup | Sub-second job pickup | Pause pod preemption |
| demo-graceful-scaling | Long-running job protection | Runner-aware scaling |
| demo-docker-build | Container image builds | DinD support |
| demo-burst-scaling | Concurrent job handling | Cluster autoscaling |

## Cleanup

```bash
# Scale down to reduce costs
kubectl scale deployment pause-pods -n arc-runners --replicas=0

# Full teardown (ensure DO_TOKEN is set)
helm uninstall arc-runner-set -n arc-runners
helm uninstall arc -n arc-systems
cd terraform && terraform destroy -var="do_token=$DO_TOKEN"
```
```

### Verification Checklist (verify each item and mark `[x]` when confirmed)
- [ ] `docs/demo-script.md` created
- [ ] `docs/post-demo-handoff.md` created
- [ ] `README.md` updated

---

## Final Verification Checklist (verify each item and mark `[x]` when confirmed)

Run through this before the demo meeting to confirm all phases are complete:

### Infrastructure
- [ ] All nodes healthy: `kubectl get nodes`
- [ ] NAT Gateway active: `doctl compute nat-gateway list`
- [ ] DOCR accessible: `doctl registry get`

### ARC Components
- [ ] Controller running: `kubectl get pods -n arc-systems`
- [ ] Listener connected: `kubectl get pods -n arc-runners -l app.kubernetes.io/component=runner-scale-set-listener`
- [ ] Scale set registered in GitHub UI

### Warm Capacity
- [ ] Pause pod running on job node: `kubectl get pods -n arc-runners -l app=pause-pods -o wide`

### Workflows
- [ ] All four workflows visible in GitHub Actions
- [ ] Each workflow runs successfully
- [ ] Docker build produces valid image
- [ ] Burst scaling provisions additional nodes

---

## Makefile Reference

A Makefile is provided for simplified deployment and operations. Run `make help` for all available targets.

### Required Environment Variables

| Variable | Purpose |
|----------|---------|
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token |
| `AWS_ACCESS_KEY_ID` | For Spaces backend (Terraform state) |
| `AWS_SECRET_ACCESS_KEY` | For Spaces backend (Terraform state) |
| `GITHUB_TOKEN` | Fine-grained PAT for runner scale set |

### Quick Start

```bash
# Set environment variables, then:

# Full deployment (infrastructure + ARC)
make deploy

# Or step-by-step:
make infra          # Deploy infrastructure
make arc            # Deploy ARC components
```

### Target Reference

| Target | Description |
|--------|-------------|
| **Infrastructure** | |
| `tf-init` | Initialize Terraform backend |
| `tf-plan` | Plan infrastructure changes |
| `tf-apply` | Apply infrastructure |
| `tf-destroy` | Destroy infrastructure |
| `kubeconfig` | Save and switch to cluster context via doctl |
| **Kubernetes/ARC** | |
| `k8s-foundation` | Apply namespaces and priority classes |
| `arc-controller` | Install ARC controller |
| `arc-runner-set` | Install runner scale set |
| `pause-pods` | Deploy pause pods |
| **Composite** | |
| `infra` | Full infrastructure deployment |
| `arc` | Full ARC deployment |
| `deploy` | Complete deployment (infra + arc) |
| **Operations** | |
| `status` | Show cluster, pods, and scale set status |
| `logs-controller` | Tail ARC controller logs |
| `logs-listener` | Tail listener pod logs |
| `pause-scale-up` | Scale pause pods to 1 |
| `pause-scale-down` | Scale pause pods to 0 |
| **Cleanup** | |
| `clean-arc` | Uninstall ARC components |
| `clean-all` | Full teardown |

### Example Workflows

**Update ARC configuration:**
```bash
# Edit kubernetes/arc-controller/values.yaml or runner-scale-set/values.yaml
make arc-controller   # Upgrade controller
make arc-runner-set   # Upgrade runner scale set
```

**Check status:**
```bash
make status
```

**Reduce costs (keep infrastructure):**
```bash
make pause-scale-down
```

**Full teardown:**
```bash
make clean-all
```

---

## Cleanup Commands

### Reduce Costs (Keep Infrastructure)
```bash
# Scale pause pods to zero
kubectl scale deployment pause-pods -n arc-runners --replicas=0

# Job nodes will scale down after idle timeout
```

### Full Teardown
```bash
# Source environment variables
source /home/jjk3/env/do-solutions.env

# Remove Helm releases
helm uninstall arc-runner-set -n arc-runners
helm uninstall arc -n arc-systems

# Remove Kubernetes resources
kubectl delete -f kubernetes/pause-pods/
kubectl delete -f kubernetes/namespaces.yaml

# Remove NAT Gateway
doctl compute nat-gateway delete arc-demo-nat

# Destroy Terraform infrastructure
cd terraform
terraform destroy -var="do_token=$DO_TOKEN"
```
