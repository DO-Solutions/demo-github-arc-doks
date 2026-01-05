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
  description = "VPC ID"
  value       = digitalocean_vpc.main.id
}

output "nat_gateway_ip" {
  description = "NAT Gateway public IP for GitHub Enterprise whitelisting"
  value       = one(one(digitalocean_vpc_nat_gateway.main.egresses).public_gateways).ipv4
}
