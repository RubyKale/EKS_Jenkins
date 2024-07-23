provider "aws" {
  region = "ap-southeast-2"
}

resource "aws_eks_cluster" "clusterruby" {
  name     = "hkmycluster"
  role_arn = "arn:aws:iam::333080888830:role/allaccessec2lambdaeks"

  vpc_config {
    subnet_ids = ["subnet-dd6fccbb", "subnet-538c501b", "subnet-a0d280f8"]
  }
}

data "aws_eks_cluster" "clusterrubydata" {
  name = aws_eks_cluster.clusterruby.name
}

data "aws_eks_cluster_auth" "clusterauthrubydata" {
  name = aws_eks_cluster.clusterruby.name
}

resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
  }
}

resource "aws_iam_role" "EKSNodeRoleruby" {
  name = "rkEKSNodeRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole",
    }],
  })
}

resource "aws_iam_role_policy_attachment" "EKSWorkerNodePolicy" {
  role       = aws_iam_role.EKSNodeRoleruby.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "EKS_CNI_Policy" {
  role       = aws_iam_role.EKSNodeRoleruby.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "Ec2ContainerRegistryReadOnly" {
  role       = aws_iam_role.EKSNodeRoleruby.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "describe_load_balancers_policy" {
  role       = aws_iam_role.EKSNodeRoleruby.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

resource "aws_eks_node_group" "ruby_node_group" {
  cluster_name    = aws_eks_cluster.clusterruby.name
  node_group_name = "rk_node_group"
  node_role_arn   = aws_iam_role.EKSNodeRoleruby.arn
  subnet_ids      = aws_eks_cluster.clusterruby.vpc_config[0].subnet_ids

  scaling_config {
    desired_size = 1
    max_size     = 3
    min_size     = 1
  }

  instance_types = ["t3.medium"]

  remote_access {
    ec2_ssh_key = "my-key-pair"
  }

  tags = {
    Name = "ruby-eks-node-group"
  }

  depends_on = [
    aws_iam_role_policy_attachment.EKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.EKS_CNI_Policy,
    aws_iam_role_policy_attachment.Ec2ContainerRegistryReadOnly,
    aws_iam_role_policy_attachment.describe_load_balancers_policy
  ]
}

/*resource "helm_release" "aws-efs-csi-driver" {
  name       = "aws-efs-csi-driver"
  repository = "https://charts.deliveryhero.io/"
  chart      = "aws-efs-csi-driver"
  version    = "2.17.1"
  namespace  = "rkkube-system"
}*/

resource "kubernetes_storage_class" "rkgp2" {
  storage_provisioner = "efs.csi.aws.com"
  metadata {
    name = "rk-gp2-storage-class"
  }
}

resource "aws_efs_file_system" "newFS" {
  creation_token = "FS-20july"
  performance_mode = "generalPurpose" // the value is predifened performance_mode to be one of ["generalPurpose" "maxIO"],
  tags = {
    Name = "example-efs"
  }
}

resource "aws_security_group" "my_sg" {
  vpc_id = "vpc-602dd606"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "my-security-group"
  }
}
resource "aws_efs_mount_target" "my_mount_target"{
  file_system_id = aws_efs_file_system.newFS.id
  security_groups = [aws_security_group.my_sg.id]
  subnet_id = "subnet-a0d280f8"
 // count = "1"
}

resource "kubernetes_persistent_volume" "efs-pv" {
  metadata {
    name = "rk-efs-pv"
  }
  spec {
    access_modes = ["ReadWriteMany"]
    capacity = {
      storage = "10Gi"
    }
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name = kubernetes_storage_class.rkgp2.metadata[0].name
    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = aws_efs_file_system.newFS.id
        fs_type = "nfs"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "jenkins-efs" {
  metadata {
    name      = "jenkins-efs"
    namespace = "jenkins"
    labels = {
      "jenkins-ebs" = "jenkins-efs"
    }
  }
  spec {
    access_modes = ["ReadWriteMany"]
    resources {
      requests = {
        storage = "10Gi"
      }
    }
    storage_class_name = kubernetes_storage_class.rkgp2.metadata[0].name
    volume_name        = kubernetes_persistent_volume.efs-pv.metadata[0].name
  }
  depends_on = [kubernetes_namespace.jenkins]
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.clusterrubydata.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.clusterrubydata.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.clusterauthrubydata.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.clusterrubydata.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.clusterrubydata.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.clusterauthrubydata.token
  }
}

resource "helm_release" "jenkins" {
  name             = "jenkins"
  repository       = "https://charts.jenkins.io"
  chart            = "jenkins"
  namespace        = "jenkins"
  timeout          = 300
  create_namespace = true

  set {
    name  = "controller.admin.password"
    value = "admin"
  }

  set {
    name  = "controller.serviceType"
    value = "LoadBalancer"
  }

  set {
    name  = "persistence.existingClaim"
    value = kubernetes_persistent_volume_claim.jenkins-efs.metadata[0].name
  }
}
