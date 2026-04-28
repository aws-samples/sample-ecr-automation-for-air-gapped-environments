# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ECR Module - Consolidated ECR Configuration
# This module provisions:
# 1. AWS KMS key for ECR encryption (following Golden EKS TF pattern)
# 2. Registry-level scanning configuration (applies to all repositories)
# 3. Repository Creation Templates with standardized settings
# Following Golden EKS TF patterns for encryption, lifecycle, and security

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

################################################################################
# AWS KMS Key for ECR Encryption (Golden EKS TF Pattern)
################################################################################

resource "aws_kms_key" "ecr" {
  description             = "AWS KMS key for ECR encryption - ${var.project_identifier}"
  key_usage               = "ENCRYPT_DECRYPT"
  is_enabled              = true
  enable_key_rotation     = true
  multi_region            = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable ECR Service Access"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" : "ecr.${data.aws_region.current.id}.amazonaws.com"
          }
        }
      },
      {
        Sid    = "Enable Key Administration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:CreateAlias",
          "kms:CreateGrant",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:ListGrants",
          "kms:ListKeyPolicies",
          "kms:PutKeyPolicy",
          "kms:RetireGrant",
          "kms:RevokeGrant",
          "kms:UpdateAlias",
          "kms:UpdateKeyDescription",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name    = "${var.resource_prefix}${var.project_identifier}-ecr-key"
      Service = "ECR"
    }
  )
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.resource_prefix}${var.project_identifier}-ecr"
  target_key_id = aws_kms_key.ecr.key_id
}

################################################################################
# Registry-Level Scanning Configuration (Golden EKS TF Pattern)
################################################################################

resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

################################################################################
# Repository Creation Templates (Dynamic)
################################################################################

# IAM role for ECR to assume when creating repositories with templates
# Required when using AWS KMS encryption or resource tags
resource "aws_iam_role" "ecr_template_role" {
  count = var.enable_repository_creation_templates ? 1 : 0

  name = "${var.resource_prefix}${var.project_identifier}-ecr-template-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecr.amazonaws.com"
      }
      Action = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" : data.aws_caller_identity.current.account_id
        }
      }
    }]
  })

  tags = var.tags
}

# IAM policy for ECR template role
resource "aws_iam_role_policy" "ecr_template_policy" {
  count = var.enable_repository_creation_templates ? 1 : 0

  name = "ecr-template-policy"
  role = aws_iam_role.ecr_template_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncrypt*"
        ]
        Resource = aws_kms_key.ecr.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:PutLifecyclePolicy",
          "ecr:SetRepositoryPolicy",
          "ecr:TagResource"
        ]
        Resource = "arn:aws:ecr:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:repository/*"
      }
    ]
  })
}

# Dynamic Repository Creation Templates
# Creates one template per entry in var.repository_templates
# Automatically applies settings to repositories matching the prefix pattern
resource "aws_ecr_repository_creation_template" "templates" {
  for_each = var.enable_repository_creation_templates ? {
    for idx, template in var.repository_templates : template.prefix => template
  } : {}

  prefix      = "${var.resource_prefix}${each.value.prefix}"
  description = "Template for ${each.value.description}"

  # AWS KMS encryption (following Golden EKS TF pattern)
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  # Image tag mutability - IMMUTABLE (Golden EKS TF standard)
  image_tag_mutability = var.image_tag_mutability

  # Lifecycle policy - Expire untagged after configured days (Golden EKS TF pattern)
  lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire Untagged Images Older than ${var.lifecycle_expiration_days} days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.lifecycle_expiration_days
      }
      action = {
        type = "expire"
      }
    }]
  })

  # Resource tags (following Golden EKS TF tagging strategy)
  resource_tags = var.tags

  # Custom role ARN (required for AWS KMS and tags)
  custom_role_arn = aws_iam_role.ecr_template_role[0].arn

  # Applied for CREATE_ON_PUSH
  applied_for = ["CREATE_ON_PUSH"]

  depends_on = [
    aws_iam_role_policy.ecr_template_policy,
    aws_kms_key.ecr
  ]
}
