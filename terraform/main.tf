# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Root Terraform configuration for ECR Automation
# Deploy this to set up ECR Repository Creation Templates with
# AWS KMS encryption, immutable tags, lifecycle policies, and enhanced scanning.

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "ecr_config" {
  source = "./modules/ecr-config"

  project_identifier                   = var.project_identifier
  resource_prefix                      = var.resource_prefix
  enable_repository_creation_templates = var.enable_repository_creation_templates
  repository_templates                 = var.repository_templates
  image_tag_mutability                 = var.image_tag_mutability
  lifecycle_expiration_days            = var.lifecycle_expiration_days
  tags                                 = var.tags
}
