resource "digitalocean_vpc" "main" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = var.vpc_ip_range
}
