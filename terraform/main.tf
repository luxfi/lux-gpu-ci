###############################################################################
# Lux GPU CI — EKS cluster with Karpenter-managed GPU spot nodes.
#
# Layout:
#   - 1 small system node group (t3.medium x 1) runs Karpenter, ARC controller,
#     kube-system, NVIDIA device plugin scheduler. Always-on (~$30/mo).
#   - Karpenter NodePool spins g4dn.xlarge spot instances 0..1 on demand.
#   - GPU node lifecycle: queued workflow → ARC creates pod → unschedulable →
#     Karpenter provisions node (~90s) → workflow runs → consolidation tears
#     it down 30s after pod completes.
###############################################################################

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)

  # Karpenter discovery tag — Karpenter finds subnets and security groups via this.
  karpenter_discovery_tag = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

###############################################################################
# VPC — 3 AZs, public + private subnets. Private subnets host worker nodes.
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = var.cluster_name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  map_public_ip_on_launch = false

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = merge(local.karpenter_discovery_tag, {
    "kubernetes.io/role/internal-elb" = 1
  })
}

###############################################################################
# EKS cluster + tiny managed system node group.
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  # System node group — always on, runs the controllers. Single small instance.
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.system_instance_type]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      capacity_type  = "ON_DEMAND"
      labels = {
        role = "system"
      }
    }
  }

  # Discovery tag on the cluster security group so Karpenter can find it.
  node_security_group_tags = local.karpenter_discovery_tag

  tags = var.tags
}

###############################################################################
# Karpenter — IAM, SQS interruption queue, controller IRSA.
###############################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name = module.eks.cluster_name

  # Pod Identity is the modern replacement for IRSA; v20 module supports both.
  enable_v1_permissions = true
  enable_pod_identity   = true
  create_pod_identity_association = true

  # Allow node IAM role to be used by EC2 instances launched by Karpenter.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  tags = var.tags
}

###############################################################################
# Outputs.
###############################################################################

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "region" {
  value = var.region
}

output "karpenter_node_iam_role_name" {
  value = module.karpenter.node_iam_role_name
}

output "karpenter_queue_name" {
  value = module.karpenter.queue_name
}

output "karpenter_iam_role_arn" {
  value = module.karpenter.iam_role_arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
