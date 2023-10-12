provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      environment = "Dev"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
    }
  }
}
provider "kubectl" {
  apply_retry_count      = 10
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_availability_zones" "available" {} 

locals {
  region = "us-east-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.12"

  ## EKS Cluster Config
  cluster_name       = "solr-demo"
  cluster_version    = "1.25"

  ## VPC Config
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets

  # EKS Cluster Network Config
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = true

  ## EKS Worker
  eks_managed_node_groups  = {
    "solr-nodegroup" = {
      node_group_name    = "solr_managed_node_group"
      # launch_template_os = "amazonlinux2eks"
      public_ip          = false
      pre_userdata       = <<-EOF
          yum install -y amazon-ssm-agent
          systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
        EOF
      desired_size       = 2
      ami_type           = "AL2_x86_64"
      capacity_type      = "ON_DEMAND"
      instance_types     = ["t3.medium"]
      disk_size          = 30
    }
  }
}

module "eks_blueprints_addons_common" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.3.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  create_delay_dependencies = [for ng in module.eks.eks_managed_node_groups: ng.node_group_arn]

  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    vpc-cni = {
      service_account_role_arn = module.aws_node_irsa.iam_role_arn
    }
    coredns = {
    }
    kube-proxy = {
    }
  }
  enable_aws_efs_csi_driver = true
}

## Resource for VPC CNI Addon
module "aws_node_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-aws-node-"

  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
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

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "solr-demo-subnet"
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}