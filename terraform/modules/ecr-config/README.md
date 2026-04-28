# ECR Configuration Terraform Module

This Terraform module deploys Amazon ECR infrastructure with Repository Creation Templates for automated, secure repository management.

## Features

- Repository Creation Templates with CREATE_ON_PUSH capability
- Customer-managed AWS KMS encryption with automatic rotation
- Immutable image tags
- Lifecycle policies for automatic cleanup
- Enhanced vulnerability scanning (SCAN_ON_PUSH + CONTINUOUS_SCAN)
- IAM service roles with least privilege

## Usage

```hcl
module "ecr_config" {
  source = "./modules/ecr-config"

  region                = "us-east-1"
  kms_key_alias         = "ecr-encryption-key"
  enable_key_rotation   = true
  
  # Repository Creation Templates
  templates = [
    {
      prefix              = "helmchart/"
      description         = "Helm charts from public repositories"
      encryption_type     = "KMS"
      image_tag_mutability = "IMMUTABLE"
      lifecycle_policy    = "expire_untagged_2days"
      scanning_enabled    = true
    },
    {
      prefix              = "helmimages/"
      description         = "EKS add-on container images"
      encryption_type     = "KMS"
      image_tag_mutability = "IMMUTABLE"
      lifecycle_policy    = "expire_untagged_2days"
      scanning_enabled    = true
    }
  ]

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
    Pattern     = "ecr-automation-air-gapped"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| region | AWS region for ECR resources | string | - | yes |
| kms_key_alias | Alias for KMS encryption key | string | "ecr-encryption-key" | no |
| enable_key_rotation | Enable automatic AWS KMS key rotation | bool | true | no |
| templates | List of Repository Creation Templates | list(object) | [] | yes |
| tags | Tags to apply to all resources | map(string) | {} | no |

## Outputs

| Name | Description |
|------|-------------|
| kms_key_id | KMS key ID for ECR encryption |
| kms_key_arn | KMS key ARN for ECR encryption |
| service_role_arn | IAM service role ARN for ECR |
| template_ids | List of created template IDs |

## Requirements

- Terraform >= 1.0
- AWS Provider >= 5.0

## Examples

See [../../examples/](../../examples/) directory for complete examples:
- [single-chart/](../../examples/single-chart/) - Single chart migration
- [batch-processing/](../../examples/batch-processing/) - Batch processing
- [multi-region/](../../examples/multi-region/) - Multi-region deployment

## Notes

- Repository Creation Templates only apply to NEW repositories created via CREATE_ON_PUSH
- Templates cannot retroactively modify existing repositories
- AWS KMS encryption type cannot be changed after repository creation
- One template can match multiple repository prefixes

## License

MIT-0 - See [../../../LICENSE](../../../LICENSE)
