# Security Best Practices

> **Shared Responsibility Model:** Security and compliance are shared responsibilities between AWS and the customer. This pattern configures AWS service-level security controls, but customers are responsible for their own organizational security requirements, access management, network configuration, and compliance validation. For more information, see the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/).

> **Important:** This is sample code for demonstration and educational purposes. You should work with your security and legal teams to meet your organizational security, regulatory, and compliance requirements before deployment.

This document outlines security best practices for deploying and operating the ECR Automation pattern.

## Table of Contents

- [Infrastructure Security](#infrastructure-security)
- [Artifact Migration Security](#artifact-migration-security)
- [Compliance](#compliance)
- [Operational Security](#operational-security)
- [Air-Gapped Specific Security](#air-gapped-specific-security)

## Infrastructure Security

### 1. Deploy Templates Before Migration

- Deploy Repository Creation Templates via Terraform before running the Artifact Migration Tool
- Validate template configuration using `aws ecr describe-repository-creation-templates`
- Test CREATE_ON_PUSH functionality with a single test repository before bulk migration

### 2. Use Multi-Region AWS KMS Keys

- Configure AWS KMS keys with multi-region replication for disaster recovery
- Enable automatic key rotation (365-day rotation period)
- Document key ARNs and aliases for reference

**Example AWS KMS Key Configuration:**

```hcl
resource "aws_kms_key" "ecr" {
  description             = "ECR encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true

  tags = {
    Name        = "ecr-encryption-key"
    Environment = "production"
  }
}
```

### 3. Implement Least Privilege IAM

- Use dedicated IAM service roles for ECR operations
- Limit AWS KMS key access to only ECR service principal
- Avoid using root account credentials
- Regularly audit IAM permissions

**Example IAM Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRRepositoryCreation",
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository",
        "ecr:PutLifecyclePolicy",
        "ecr:SetRepositoryPolicy",
        "ecr:PutImageTagMutability",
        "ecr:PutImageScanningConfiguration"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KMSKeyAccess",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey"
      ],
      "Resource": "arn:aws:kms:*:*:key/*"
    }
  ]
}
```

### 4. Enable Comprehensive Logging

- Enable CloudTrail logging for all ECR API calls
- Configure CloudWatch log retention (recommend 90+ days)
- Monitor CloudWatch metrics for API throttling
- Set up alerts for failed repository creations

**Example CloudTrail Configuration:**

```hcl
resource "aws_s3_bucket" "cloudtrail" {
  bucket = "ecr-audit-trail-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  versioning_configuration {
    status     = "Enabled"
    mfa_delete = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.ecr.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail.arn,
          "${aws_s3_bucket.cloudtrail.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid       = "AllowCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "AllowCloudTrailACLCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      }
    ]
  })
}

resource "aws_s3_bucket_logging" "cloudtrail" {
  bucket        = aws_s3_bucket.cloudtrail.id
  target_bucket = aws_s3_bucket.cloudtrail.id
  target_prefix = "access-logs/"
}

resource "aws_cloudtrail" "ecr_audit" {
  name                          = "ecr-audit-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::ECR::Repository"
      values = ["arn:aws:ecr:*:*:repository/*"]
    }
  }
}
```

## Artifact Migration Security

### 5. Validate Multi-Architecture Images

- Verify all platforms are preserved after migration
- Use `docker manifest inspect` to confirm platform availability
- Test deployments on different architectures (amd64, arm64)
- Document any single-architecture images that couldn't be migrated

**Verification Command:**

```bash
# Check source image platforms
docker manifest inspect docker.io/nginx:latest | jq '.manifests[].platform'

# Check migrated image platforms
docker manifest inspect <account-id>.dkr.ecr.us-east-1.amazonaws.com/helmchart/nginx:latest | jq '.manifests[].platform'
```

### 6. Use Authenticated Registry Access

- Configure Docker Hub authentication to avoid rate limits (200 vs 100 pulls/6 hours)
- Use registry mirrors or caching proxies for large migrations
- Do not commit registry credentials to version control
- Use AWS Secrets Manager or Parameter Store for credential storage

### 7. Sanitize Logs

- Remove sensitive information from logs before sharing
- Avoid logging credentials, tokens, or API keys
- Use log redaction for sensitive fields
- Implement log retention policies

## Security and Compliance

### 8. Enforce Immutable Tags

- Use IMMUTABLE tag mutability in templates
- Prevents accidental or malicious tag overwrites
- Ensures image integrity and audit trail
- Required for compliance (SOC 2, PCI-DSS)

**Template Configuration:**

```hcl
resource "aws_ecr_repository_creation_template" "helmchart" {
  prefix = "helmchart/"
  
  image_tag_mutability = "IMMUTABLE"
  
  # ... other configuration
}
```

### 9. Enable Enhanced Vulnerability Scanning

- Use ENHANCED scanning mode (not BASIC)
- Enable both SCAN_ON_PUSH and CONTINUOUS_SCAN
- Integrate with AWS Security Hub for centralized findings
- Set up automated remediation workflows for critical vulnerabilities

**Scanning Configuration:**

```hcl
resource "aws_ecr_registry_scanning_configuration" "enhanced" {
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
```

### 10. Implement Lifecycle Policies

- Configure lifecycle policies to expire untagged images (recommend 2 days)
- Prevents storage bloat and reduces costs
- Maintain audit trail of deleted images via CloudTrail
- Review and adjust policies based on usage patterns

**Example Lifecycle Policy:**

```json
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire untagged images after 2 days",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 2
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
```

### 11. Use Customer-Managed AWS KMS Keys

- Do not use AWS-managed encryption (AES256) for production
- Customer-managed keys provide better control and audit trail
- Enable automatic key rotation
- Document key policies and access controls

**AWS KMS Key Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::ACCOUNT-ID:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow ECR to use the key",
      "Effect": "Allow",
      "Principal": {
        "Service": "ecr.amazonaws.com"
      },
      "Action": [
        "kms:Decrypt",
        "kms:Encrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
```

## Operational Security

### 12. Maintain Naming Conventions

- Use consistent repository naming patterns (e.g., helmchart/, helmimages/)
- Document naming conventions in team wiki
- Use prefixes to organize repositories by type or team
- Leverage template prefix matching for automatic categorization

### 13. Document Everything

- Maintain inventory of migrated charts and images
- Document any manual interventions or exceptions
- Keep migration logs for audit and troubleshooting
- Update documentation as patterns evolve

### 14. Monitor and Alert

Set up CloudWatch alarms for:
- Failed image pushes
- API throttling events
- AWS KMS key usage anomalies
- Scanning failures

Configure SNS notifications for critical events and review metrics weekly during initial deployment.

### 15. Plan for Disaster Recovery

- Use multi-region AWS KMS keys for cross-region replication
- Document recovery procedures
- Test failover scenarios
- Maintain backup of Terraform state files

## Air-Gapped Specific Security

### 16. Pre-Download All Dependencies

- Download all Helm chart dependencies before air-gap migration
- Verify all image references are accessible
- Document any external dependencies that need special handling
- Test complete deployment in isolated environment

### 17. Validate Network Isolation

- Confirm EKS cluster has no internet connectivity
- Verify all images pull from private ECR
- Test DNS resolution for ECR endpoints
- Document VPC endpoint configuration

**VPC Endpoint Verification:**

```bash
# Check ECR API endpoint
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.ecr.api" \
  --query 'VpcEndpoints[*].[VpcEndpointId,State]'

# Check ECR DKR endpoint
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.ecr.dkr" \
  --query 'VpcEndpoints[*].[VpcEndpointId,State]'

# Check S3 endpoint (for ECR layers)
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.s3" \
  --query 'VpcEndpoints[*].[VpcEndpointId,State]'
```

### 18. Plan for Updates

- Establish process for updating images in air-gapped environment
- Document procedures for emergency patches
- Maintain staging environment for testing updates
- Use version pinning for reproducible deployments

## Compliance

> **Note:** Compliance is a shared responsibility. This pattern provides security controls that can help support compliance efforts, but customers are responsible for validating that their specific implementation meets their regulatory and compliance requirements. Consult your compliance and legal teams before making compliance determinations.

The security controls in this pattern can help address requirements in the following frameworks:

### SOC 2 Requirements

- **CC6.1:** Logical and physical access controls (AWS KMS encryption, IAM)
- **CC6.6:** Vulnerability management (Enhanced scanning)
- **CC7.2:** System monitoring (CloudWatch, CloudTrail)

### PCI-DSS Requirements

- **Requirement 3:** Protect stored data (AWS KMS encryption)
- **Requirement 6:** Secure systems (Vulnerability scanning)
- **Requirement 10:** Track and monitor access (CloudTrail)

### HIPAA Security Rule

- **§164.312(a)(2)(iv):** Encryption (AWS KMS encryption at rest)
- **§164.312(b):** Audit controls (CloudTrail logging)
- **§164.308(a)(1)(ii)(D):** Risk analysis (Vulnerability scanning)

### NIST 800-53 Controls

- **SC-28:** Protection of Information at Rest (AWS KMS encryption)
- **AU-2:** Audit Events (CloudTrail logging)
- **SI-2:** Flaw Remediation (Vulnerability scanning)

## Security Scanning and Validation

Before publishing or deploying, run the following security scans:

**Terraform Code:**
```bash
# Run Checkov for Terraform security scanning
checkov -d terraform/ --output json > terraform-scan-results.json

# Run tfsec as an alternative
tfsec terraform/ --format json > tfsec-results.json
```

**Bash Scripts:**
```bash
# Run ShellCheck for bash script analysis
shellcheck ecr-manager-tool/ecr-artifact-manager.sh --format json > shellcheck-results.json

# Verify git-secrets hooks are configured
git secrets --scan
```

**Credential Detection:**
```bash
# Scan for hardcoded credentials
git secrets --scan-history
```

**Recommended scanning tools:**
- [Checkov](https://www.checkov.io/) — Terraform and IaC security scanning
- [ShellCheck](https://www.shellcheck.net/) — Bash script static analysis
- [git-secrets](https://github.com/awslabs/git-secrets) — Credential detection (included in hooks/)
- [AWS Holmes](https://portal.prod.holmes.aws.dev/) — AWS content security scanning

Address all Critical and High findings before deployment. Document scan results and any compensating controls.

## Security Checklist

Before deploying to production, verify:

- [ ] Repository Creation Templates deployed with AWS KMS encryption
- [ ] Immutable tags enforced
- [ ] Enhanced vulnerability scanning enabled
- [ ] Lifecycle policies configured
- [ ] CloudTrail logging enabled
- [ ] CloudWatch alarms configured
- [ ] IAM roles follow least privilege
- [ ] AWS KMS key rotation enabled
- [ ] VPC endpoints configured (air-gapped)
- [ ] Network isolation validated (air-gapped)
- [ ] All dependencies pre-downloaded (air-gapped)
- [ ] Disaster recovery plan documented
- [ ] Security incident response procedures established

## Related Documentation

- [Architecture Overview](ARCHITECTURE.md) - System architecture
- [Deployment Guide](DEPLOYMENT-GUIDE.md) - Deployment instructions
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
