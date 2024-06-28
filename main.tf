# ---------------------------------------------------------------------------------------------------------------------
# ACCESS ACCOUNT INFORMATION
# ---------------------------------------------------------------------------------------------------------------------

data "aws_partition" "current" {}
data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = local.name
  cidr = local.vpc_cidr

  azs              = local.azs
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 8)]

  create_database_subnet_group = true


  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  tags = local.tags
}


# #################################
# # --- AWS ECR Resources ---     #
# #################################
resource "aws_ecr_repository" "repository" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  # Uncomment only if you want to delete completely ECR Repo with all the images
  # force_delete = true
}

resource "aws_ecr_lifecycle_policy" "name" {
  repository = aws_ecr_repository.repository.name
  policy     = <<EOF
{
    "rules": [
        {
            "rulePriority": 1,
            "description": "Keep only 3 untagged image, expire all others",
            "selection": {
                "tagStatus": "any",
                "countType": "imageCountMoreThan",
                "countNumber": 3
            },
            "action": {
                "type": "expire"
            }
        }
    ]
}
EOF
}

resource "aws_ecr_registry_scanning_configuration" "scan_configuration" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

###################################################
# --- Lambda Roles and POlicies Resources ---     #
###################################################


resource "aws_iam_role" "lambda_role" {
  name               = var.function_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role_policy_document.json
}


data "aws_iam_policy_document" "lambda_assume_role_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_basic_role_policy_document" {
  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = ["arn:aws:logs:*:*:*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "eks:DescribeCluster"
    ]

    resources = [
      "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/your-cluster-name"
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeTags",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances"
    ]

    resources = [
      "*"
    ]
  }
  statement {
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = [
      "*",
    ]
  }
}

resource "aws_iam_policy" "lambda_basic_role_policy_document" {
  name        = "${var.function_name}_policy"
  description = "Container lambda basic policy"
  policy      = data.aws_iam_policy_document.lambda_basic_role_policy_document.json
}

resource "aws_iam_role_policy_attachment" "container_lambda_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_basic_role_policy_document.arn
}

##########################################
# --- Security Group Placeholder ---     #
##########################################
resource "aws_security_group" "eks_sg_example" {
  name        = "eks_node_group_sg"
  description = "Security Group place holder, to have as an example of SG of a EKS Cluster"

  vpc_id = module.vpc.vpc_id


  tags = {
    Name = "eks_node_group_sg"
  }
}

##########################################
# --- Security Group for Lambdas ---     #
##########################################

resource "aws_security_group" "lambda_security_group" {
  name   = "${var.function_name}_sg"
  description = "Security Group for the Lambda Function"

  vpc_id = module.vpc.vpc_id

    tags = {
    Name = "${var.function_name}_sg"
  }
}

resource "aws_security_group_rule" "lambda_egress" {
  type              = "egress"
  from_port         = "0"
  to_port           = "65535"
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.lambda_security_group.id
}

resource "aws_security_group_rule" "lambda_to_cluster" {
  type                     = "ingress"
  from_port                = "443"
  to_port                  = "443"
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lambda_security_group.id
  security_group_id        = aws_security_group.eks_sg_example.id
}

#############################
# --- ECR IMAGE URI ---     #
#############################
data "aws_ecr_image" "bash_container" {
  repository_name = aws_ecr_repository.repository.name
  most_recent     = true
}

###############################
# --- Lambda Resources---     #
###############################
resource "aws_lambda_function" "custom_runtime" {
  function_name = var.function_name
  role          = aws_iam_role.lambda_role.arn
  image_uri     = data.aws_ecr_image.bash_container.image_uri
  package_type  = "Image"

  timeout = 900

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda_security_group.id]
  }

  environment {
    variables = {
      deployment_name = "exampleApp01",
    }
  }
}