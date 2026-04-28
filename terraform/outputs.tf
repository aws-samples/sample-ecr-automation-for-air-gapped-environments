# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "repository_template_prefixes" {
  description = "Map of repository template prefixes to their full ECR prefixes"
  value       = module.ecr_config.repository_template_prefixes
}

output "kms_key_id" {
  description = "AWS KMS key ID for ECR encryption"
  value       = module.ecr_config.kms_key_id
}

output "kms_key_arn" {
  description = "AWS KMS key ARN for ECR encryption"
  value       = module.ecr_config.kms_key_arn
}

output "ecr_template_role_arn" {
  description = "IAM role ARN used by ECR templates"
  value       = module.ecr_config.ecr_template_role_arn
}
