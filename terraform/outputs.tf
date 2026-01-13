output "nat_gateway_ip" {
  description = "NAT Gateway public IP for GitHub Enterprise whitelisting"
  value       = one(one(digitalocean_vpc_nat_gateway.main.egresses).public_gateways).ipv4
}

