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

variable "vpc_ip_range" {
  description = "VPC IP range (CIDR notation)"
  type        = string
  default     = "10.200.0.0/16"
}

variable "cluster_subnet" {
  description = "DOKS cluster subnet for pod network (CIDR notation)"
  type        = string
  default     = "10.240.0.0/16"
}

variable "service_subnet" {
  description = "DOKS service subnet (CIDR notation)"
  type        = string
  default     = "10.241.0.0/16"
}

variable "kubernetes_version" {
  description = "DOKS Kubernetes version"
  type        = string
  default     = "1.34.1-do.2"
}
