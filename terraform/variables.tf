variable "region" {
  description = "AWS region. us-west-2 has good g4dn spot capacity."
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "lux-gpu-ci"
}

variable "cluster_version" {
  description = "Kubernetes minor version."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.42.0.0/16"
}

variable "system_instance_type" {
  description = "Instance type for the always-on system node group (Karpenter, ARC controller, kube-system)."
  type        = string
  default     = "t3.medium"
}

variable "github_org" {
  description = "GitHub organization that hosts the runner repos."
  type        = string
  default     = "luxfi"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "lux-gpu-ci"
    ManagedBy = "terraform"
    Component = "gpu-ci"
  }
}
