# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "enable_repository_creation_templates" {
  description = "Enable ECR Repository Creation Templates for automatic repository creation"
  type        = bool
  default     = true
}

variable "resource_prefix" {
  description = <<-EOT
    Optional resource prefix for naming. Two patterns supported:
    1. No prefix (default): prefix becomes the ECR prefix directly → helmchart/chart-name
    2. Environment prefix: {env}-{region}-{org}-{project}- → d-euc1-myteam-app-helmchart/chart-name
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.resource_prefix == "" || can(regex("^[a-z0-9-]+-$", var.resource_prefix))
    error_message = "Resource prefix must be empty or end with a hyphen (e.g., 'd-euc1-myteam-app-')"
  }
}

variable "project_identifier" {
  description = "Project identifier used for resource naming (e.g., 'ecr-automation', 'golden-eks')"
  type        = string
  default     = "ecr-automation"
}

# New flexible approach - list of repository templates
variable "repository_templates" {
  description = <<-EOT
    List of repository template configurations. Each template defines a prefix and description.
    The full ECR prefix will be automatically constructed as: resource_prefix + prefix
    Example:
    [
      { prefix = "helmchart", description = "Helm charts repositories" },
      { prefix = "helmimage", description = "Container images from Helm charts" },
      { prefix = "appimage", description = "Application container images" }
    ]
  EOT
  type = list(object({
    prefix      = string
    description = string
  }))
  default = [
    {
      prefix      = "helmchart"
      description = "Helm charts repositories with standardized settings"
    },
    {
      prefix      = "helmimage"
      description = "Container images from Helm charts with standardized settings"
    }
  ]

  validation {
    condition     = alltrue([for t in var.repository_templates : can(regex("^[a-z0-9]+$", t.prefix))])
    error_message = "All repository template prefixes must contain only lowercase letters and numbers (no hyphens for prefix compatibility)."
  }

  validation {
    condition     = length(var.repository_templates) > 0
    error_message = "At least one repository template must be defined."
  }
}

# Legacy variables for backward compatibility (deprecated)
variable "helm_charts_prefix" {
  description = "[DEPRECATED] Use repository_templates instead. Prefix for Helm charts repositories."
  type        = string
  default     = null
}

variable "eks_addons_prefix" {
  description = "[DEPRECATED] Use repository_templates instead. Prefix for EKS addons container images."
  type        = string
  default     = null
}

variable "image_tag_mutability" {
  description = "Image tag mutability setting"
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "Image tag mutability must be either MUTABLE or IMMUTABLE"
  }
}

variable "lifecycle_expiration_days" {
  description = "Days before untagged images expire (Golden EKS TF default: 2)"
  type        = number
  default     = 2
}

variable "tags" {
  description = "Resource tags (following Golden EKS TF tagging strategy)"
  type        = map(string)
  default     = {}
}
