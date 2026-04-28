# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "region" {
  description = "AWS region for ECR resources"
  type        = string
  default     = "us-east-1"
}

variable "project_identifier" {
  description = "Project identifier used for resource naming (e.g., 'ecr-automation', 'my-platform')"
  type        = string
  default     = "ecr-automation"
}

variable "resource_prefix" {
  description = <<-EOT
    Optional resource prefix for naming. Two patterns supported:
    1. No prefix (default): helmchart/chart-name
    2. Environment prefix: d-use1-myorg-eks-helmchart/chart-name
  EOT
  type        = string
  default     = ""
}

variable "enable_repository_creation_templates" {
  description = "Enable ECR Repository Creation Templates for automatic repository creation"
  type        = bool
  default     = true
}

variable "repository_templates" {
  description = "List of repository template configurations with prefix and description"
  type = list(object({
    prefix      = string
    description = string
  }))
  default = [
    {
      prefix      = "helmchart"
      description = "Helm charts from public and private repositories"
    },
    {
      prefix      = "helmimage"
      description = "Container images extracted from Helm charts"
    }
  ]
}

variable "image_tag_mutability" {
  description = "Image tag mutability setting (IMMUTABLE recommended)"
  type        = string
  default     = "IMMUTABLE"
}

variable "lifecycle_expiration_days" {
  description = "Days before untagged images expire"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Pattern   = "ecr-automation-air-gapped"
  }
}
