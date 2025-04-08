provider "aws" {
  region = var.region
  shared_credentials_files = ["aws-creds.ini"]
}


data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

data "aws_caller_identity" "current" {}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  repository_cache       = "/tmp/.helm"
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

data "aws_availability_zones" "available" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                   = var.cluster_name
  cluster_version                = var.k8s_version
  cluster_endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

}

module "eks_managed_node_group_default" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.0"

  name            = "managed-ng-default"
  ami_type        = var.ami_type
  cluster_name    = var.cluster_name
  cluster_version = var.k8s_version

  subnet_ids = module.vpc.private_subnets

  cluster_primary_security_group_id = module.eks.cluster_security_group_id
  vpc_security_group_ids            = [module.eks.node_security_group_id]
  cluster_service_cidr              = module.eks.cluster_service_cidr

  instance_types = [var.instance_type_default]

  min_size     = 2
  max_size     = 2
  desired_size = 2

  enable_bootstrap_user_data = false

  pre_bootstrap_user_data = <<-EOT
    #!/bin/bash
    LINE_NUMBER=$(grep -n "KUBELET_EXTRA_ARGS=\$2" /etc/eks/bootstrap.sh | cut -f1 -d:)
    REPLACEMENT="\ \ \ \ \ \ KUBELET_EXTRA_ARGS=\$(echo \$2 | sed -s -E 's/--max-pods=[0-9]+/--max-pods=100/g')"
    sed -i '/KUBELET_EXTRA_ARGS=\$2/d' /etc/eks/bootstrap.sh
    sed -i "$${LINE_NUMBER}i $${REPLACEMENT}" /etc/eks/bootstrap.sh
  EOT
}

module "eks_managed_node_group_gpu" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.0"

  name            = "managed-ng-gpu"
  ami_type        = var.ami_type
  cluster_name    = var.cluster_name
  cluster_version = var.k8s_version

  subnet_ids = module.vpc.private_subnets

  cluster_primary_security_group_id = module.eks.cluster_security_group_id
  vpc_security_group_ids            = [module.eks.node_security_group_id]
  cluster_service_cidr              = module.eks.cluster_service_cidr

  instance_types = [var.instance_type_gpu]

  min_size     = 1
  max_size     = 1
  desired_size = 1

  labels = {
    "nvidia.com/mps.capable" = true
    "nvidia.com/gpu.present" = true
  }

  taints = [
    {
      key    = "nvidia.com/gpu"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  ]

  enable_bootstrap_user_data = false
}

################################################################################
# EKS Blueprints Addons
################################################################################

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  create_delay_dependencies = [module.eks_managed_node_group_default.node_group_arn]

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns    = {}
    kube-proxy = {}
  }

  enable_velero = false
}

################################################################################
# Storage Classes
################################################################################

resource "kubernetes_annotations" "gp2" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  # This is true because the resources was already created by the ebs-csi-driver addon
  force = "true"

  metadata {
    name = "gp2"
  }

  annotations = {
    # Modify annotations to remove gp2 as default storage class still retain the class
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [
    module.eks_blueprints_addons
  ]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      # Annotation to set gp3 as default storage class
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    encrypted = true
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    module.eks_blueprints_addons
  ]
}


################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

module "ebs_kms_key" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 1.5"

  description = "Customer managed key to encrypt EKS managed node group volumes"

  # Policy
  key_administrators = [data.aws_caller_identity.current.arn]
  key_service_roles_for_autoscaling = [
    # required for the ASG to manage encrypted volumes for nodes
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
    # required for the cluster / persistentvolume-controller to create encrypted PVCs
    module.eks.cluster_iam_role_arn,
  ]

  # Aliases
  aliases = ["eks/${var.cluster_name}/ebs"]
}

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# resource "helm_release" "nvidia_device_plugin" {
#   name             = "nvidia-device-plugin"
#   namespace        = "nvidia-device-plugin"
#   repository       = "https://nvidia.github.io/k8s-device-plugin"
#   chart            = "nvidia-device-plugin"
#   version          = "0.17.1"
#   create_namespace = true
# }