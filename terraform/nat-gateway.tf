# NAT Gateway for static egress IP
resource "digitalocean_vpc_nat_gateway" "main" {
  name   = "${var.project_name}-nat"
  region = var.region
  type   = "PUBLIC"
  size   = "1"

  vpcs {
    vpc_uuid = digitalocean_vpc.main.id
  }

  udp_timeout_seconds  = 30
  icmp_timeout_seconds = 30
  tcp_timeout_seconds  = 30
}
