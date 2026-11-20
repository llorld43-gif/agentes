# ==============================================================================
# Fase de Bootstrap: Configuración OIDC para GitHub Actions y Backend Remoto
# ==============================================================================
# Esta fase se ejecuta una ÚNICA VEZ antes de configurar el pipeline de CI/CD.
# Elimina el uso de credenciales estáticas (AWS Access Keys) usando tokens JWT.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# ------------------------------------------------------------------------------
# 1. PROVEEDOR OPENID CONNECT (OIDC) PARA GITHUB ACTIONS
# ------------------------------------------------------------------------------
# Huella digital oficial del certificado SSL raíz de GitHub Actions
resource "aws_iam_openid_connect_provider" "github_oidc" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # Thumbprints oficiales de GitHub Actions OIDC
  thumbprint_list = [
    "d367a47959a77b088bec4fe3e7dd3ec9ba733ab5",
    "ab9d0263244dd0326eb67015705a667e79cfe998",
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c5876bd52c0005b5b828fe01fae4270e044240f"
  ]

  tags = {
    Name        = "GitHubActions-OIDC"
    Environment = "Bootstrap"
  }
}

# ------------------------------------------------------------------------------
# 2. ROL IAM ASUMIDO POR EL PIPELINE (Sin credenciales estáticas)
# ------------------------------------------------------------------------------
resource "aws_iam_role" "github_actions_role" {
  name = "${var.project_name}-github-oidc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_oidc.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # Soporta tanto el formato estándar como el formato inmutable de sub claim de GitHub
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:${var.github_repo}:*",
              "repo:llorld43-gif@307716463/agentes@1462154844:*"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-ci-cd-role"
    ManagedBy   = "Terraform-Bootstrap"
    Security    = "OIDC-Federated-LeastPrivilege"
  }
}

# Política de permisos para que el pipeline gestione la infraestructura serverless
resource "aws_iam_policy" "pipeline_policy" {
  name        = "${var.project_name}-pipeline-policy"
  description = "Permisos necesarios para desplegar Serverless (S3, DynamoDB, Lambda, Cognito, API Gateway, CloudFront)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Gestión de S3 (Backend remoto y Frontend)
      {
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["*"]
      },
      # Gestión de DynamoDB (Citas y State Locking)
      {
        Effect   = "Allow"
        Action   = ["dynamodb:*"]
        Resource = ["*"]
      },
      # Gestión de AWS Lambda
      {
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = ["*"]
      },
      # Gestión de API Gateway v2
      {
        Effect   = "Allow"
        Action   = ["apigateway:*"]
        Resource = ["*"]
      },
      # Gestión de Amazon Cognito
      {
        Effect   = "Allow"
        Action   = ["cognito-idp:*"]
        Resource = ["*"]
      },
      # Gestión de CloudFront
      {
        Effect   = "Allow"
        Action   = [
          "cloudfront:CreateDistribution",
          "cloudfront:CreateDistributionWithTags",
          "cloudfront:GetDistribution",
          "cloudfront:GetDistributionConfig",
          "cloudfront:ListDistributions",
          "cloudfront:UpdateDistribution",
          "cloudfront:DeleteDistribution",
          "cloudfront:CreateInvalidation",
          "cloudfront:GetInvalidation",
          "cloudfront:CreateOriginAccessControl",
          "cloudfront:GetOriginAccessControl",
          "cloudfront:GetOriginAccessControlConfig",
          "cloudfront:UpdateOriginAccessControl",
          "cloudfront:DeleteOriginAccessControl",
          "cloudfront:ListOriginAccessControls",
          "cloudfront:TagResource",
          "cloudfront:UntagResource",
          "cloudfront:ListTagsForResource"
        ]
        Resource = ["*"]
      },
      # Gestión de Roles IAM del proyecto
      {
        Effect   = "Allow"
        Action   = [
          "iam:CreateRole",
          "iam:GetRole",
          "iam:DeleteRole",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PassRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:UpdateAssumeRolePolicy"
        ]
        Resource = ["arn:aws:iam::*:role/${var.project_name}-*"]
      },
      # Gestión de Políticas IAM administradas del proyecto
      {
        Effect   = "Allow"
        Action   = [
          "iam:CreatePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:DeletePolicy",
          "iam:TagPolicy",
          "iam:UntagPolicy",
          "iam:ListPolicyTags"
        ]
        Resource = ["arn:aws:iam::*:policy/${var.project_name}-*"]
      },
      # Amazon SES
      {
        Effect   = "Allow"
        Action   = ["ses:*"]
        Resource = ["*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "pipeline_attach" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = aws_iam_policy.pipeline_policy.arn
}

# ------------------------------------------------------------------------------
# 3. S3 BUCKET PARA EL ESTADO REMOTO DE TERRAFORM (terraform.tfstate)
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "tf_state" {
  bucket        = "${var.project_name}-tfstate-${random_string.suffix.result}"
  force_destroy = false

  tags = {
    Name        = "${var.project_name}-tfstate"
    Environment = "Bootstrap"
  }
}

# Versionado para historial y rollback seguro de estado
resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Cifrado en reposo obligatorio con AES-256
resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bloqueo total de acceso público
resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ------------------------------------------------------------------------------
# 4. TABLA DYNAMODB PARA STATE LOCKING (Evita ejecuciones concurrentes)
# ------------------------------------------------------------------------------
resource "aws_dynamodb_table" "tf_locks" {
  name         = "${var.project_name}-tflocks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-tflocks"
    Environment = "Bootstrap"
  }
}
