data "digitalocean_kubernetes_versions" "current" {
  # Get latest stable version
}

resource "digitalocean_kubernetes_cluster" "main" {
  name           = "${var.project_name}-cluster"
  region         = var.region
  version        = data.digitalocean_kubernetes_versions.current.latest_version
  vpc_uuid       = digitalocean_vpc.main.id
  cluster_subnet = var.cluster_subnet
  service_subnet = var.service_subnet

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
