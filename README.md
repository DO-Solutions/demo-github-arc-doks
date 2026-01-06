# GitHub Runner on DOKS Demo

This repository demonstrates GitHub Actions self-hosted runners on DigitalOcean Kubernetes Service (DOKS) using Actions Runner Controller (ARC).

## What This Demo Shows

This demo addresses common pain points when migrating from AWS ECS-based GitHub runners:

| Pain Point | Solution | Demo |
|------------|----------|------|
| **Cold-start latency (minutes)** | Pause pods maintain warm node capacity for instant job pickup | Small Runner |
| **Docker build support** | Docker-in-Docker (DinD) mode - existing workflows work unchanged | Docker Build |
| **T-shirt sized runners** | Small (~25% node) and Large (~70% node) scale sets | Small/Large Runner |
| **Node autoscaling** | Run 4+ small jobs to trigger cluster autoscaler | Small Runner (4x) |

## Architecture

| Component | Purpose |
|-----------|---------|
| **DOKS Cluster** | Kubernetes cluster with management and job node pools |
| **ARC Controller** | Manages runner scale sets, runs on management nodes |
| **Runner Scale Sets** | Two t-shirt sized scale sets: small (~25% node) and large (~70% node) |
| **Pause Pods** | Low-priority pods (30% node) - preempted when 3+ small runners arrive |
| **NAT Gateway** | Static egress IP for GitHub Enterprise IP whitelisting |

## Quick Start

### Prerequisites
- DigitalOcean account with API token
- GitHub PAT with Actions permissions (fine-grained: Actions R/W, Administration R/W, Metadata R)
- CLI tools: `doctl`, `kubectl`, `terraform`, `helm`, `gh`

### Fork Setup
If you forked this repo, update the runner scale set configuration:
```bash
# Edit kubernetes/runner-scale-set/values.yaml
# Change githubConfigUrl to your fork's URL
```

### Environment Variables
```bash
export DIGITALOCEAN_TOKEN="your-do-token"
export AWS_ACCESS_KEY_ID="your-spaces-key"       # For Terraform state backend
export AWS_SECRET_ACCESS_KEY="your-spaces-secret"
export GITHUB_TOKEN="ghp_your-github-pat"
```

### Deploy
```bash
make deploy   # Full deployment (infrastructure + ARC)
make status   # Verify everything is running
```

## Running the Demos

```bash
# Pre-demo health check
make demo-preflight

# Individual demos
make demo-small         # Small runner (25% of node) - preempts pause pod
make demo-large         # Large runner (100% of node) - fills entire node
make demo-docker-build  # Build and run a Docker container using small runner
```

## Monitoring Job Execution

Watch the cluster while demos run to see ARC in action:

```bash
# Terminal 1: Watch runner pods (see runners spawn and terminate)
watch -n1 'kubectl get pods -n arc-runners -o wide'

# Terminal 2: Watch nodes (see autoscaling during burst demo)
watch -n2 'kubectl get nodes -L node-role'

# Terminal 3: Watch events (see pod scheduling, preemption)
kubectl get events -n arc-runners -w
```

### What to Look For

| Demo | What You'll See |
|------|-----------------|
| **Small Runner** | Pause pod evicted, runner pod starts in <2s, uses 25% of node |
| **Large Runner** | Runner pod uses ~70% of node, pause pod evicted |
| **Docker Build** | Runner pod with DinD sidecar, successful build in logs |
| **4x Small Runner** | 3 runners fill 75%, 4th triggers autoscaler (new node in 60-90s) |

### Useful Commands

```bash
# View runner logs (small or large)
kubectl logs -n arc-runners -l actions.github.com/scale-set-name=doks-small -f
kubectl logs -n arc-runners -l actions.github.com/scale-set-name=doks-large -f

# Describe a specific runner pod
kubectl describe pod -n arc-runners <pod-name>

# Check scale set status
kubectl get autoscalingrunnerset -n arc-runners

# View GitHub workflow run status
gh run list --limit 5
gh run view <run-id>
```

## Operations

```bash
make status             # Cluster and pod status
make logs-controller    # ARC controller logs
make logs-listener      # Listener pod logs
make pause-scale-up     # Restore warm capacity
make pause-scale-down   # Reduce costs
```

## Cleanup

```bash
make pause-scale-down   # Scale down (keep infrastructure)
make clean-all          # Full teardown
```

Run `make help` for all available targets.
