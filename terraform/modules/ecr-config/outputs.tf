# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "repository_template_prefixes" {
  description = "Map of repository template prefixes to their full ECR prefixes"
  value = var.enable_repository_creation_templates ? {
    for prefix, template in aws_ecr_repository_creation_template.templates : prefix => template.prefix
  } : {}
}

output "repository_templates" {
  description = "List of all repository template configurations"
  value = var.enable_repository_creation_templates ? [
    for prefix, template in aws_ecr_repository_creation_template.templates : {
      prefix      = prefix
      full_prefix = template.prefix
      description = template.description
    }
  ] : []
}

# Legacy outputs for backward compatibility (deprecated)
output "helm_charts_template_prefix" {
  description = "[DEPRECATED] Use repository_template_prefixes instead. Prefix for helm charts template."
  value = var.enable_repository_creation_templates ? try(
    aws_ecr_repository_creation_template.templates["helmchart"].prefix,
    null
  ) : null
}

output "eks_addons_template_prefix" {
  description = "[DEPRECATED] Use repository_template_prefixes instead. Prefix for EKS addons template."
  value = var.enable_repository_creation_templates ? try(
    aws_ecr_repository_creation_template.templates["helmimage"].prefix,
    null
  ) : null
}

output "ecr_template_role_arn" {
  description = "ARN of the IAM role used by ECR templates"
  value       = var.enable_repository_creation_templates ? aws_iam_role.ecr_template_role[0].arn : null
}

output "ecr_template_role_name" {
  description = "Name of the IAM role used by ECR templates"
  value       = var.enable_repository_creation_templates ? aws_iam_role.ecr_template_role[0].name : null
}

output "kms_key_id" {
  description = "ID of the AWS KMS key for ECR encryption"
  value       = aws_kms_key.ecr.id
}

output "kms_key_arn" {
  description = "ARN of the AWS KMS key for ECR encryption"
  value       = aws_kms_key.ecr.arn
}

output "kms_key_alias" {
  description = "Alias of the AWS KMS key for ECR encryption"
  value       = aws_kms_alias.ecr.name
}

output "registry_scanning_enabled" {
  description = "Whether registry-level scanning is enabled"
  value       = true
}
