# Single Chart Example

This example demonstrates migrating a single Helm chart with its dependencies to ECR.

## Overview

This example migrates the `external-secrets` Helm chart from the public Helm repository to a private ECR repository.

**Chart Details:**
- **Name:** external-secrets
- **Repository:** https://charts.external-secrets.io
- **Version:** 0.9.11
- **Dependencies:** None (self-contained)
- **Images:** 1 container image (multi-architecture)

## Prerequisites

- AWS CLI configured with appropriate permissions
- Docker installed and running
- Helm 3.x installed
- ECR Repository Creation Templates deployed
- AWS KMS key created for ECR encryption

## Configuration Files

### charts-config.yaml

Defines the chart to migrate:

```yaml
charts:
  - name: external-secrets
    repo_url: https://charts.external-secrets.io
    repo_name: external-secrets
    version: 0.9.11
    namespace: helmchart
```

### terraform.tfvars.example

Terraform variables for ECR infrastructure:

```hcl
aws_region = "us-east-1"
kms_key_alias = "ecr-encryption-key"
enable_key_rotation = true

repository_prefixes = [
  "helmchart/"
]
```

## Step-by-Step Instructions

### Step 1: Deploy ECR Infrastructure

```bash
# Navigate to Terraform module
cd ../../terraform/modules/ecr-config

# Copy example tfvars
cp ../../../examples/single-chart/terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
vim terraform.tfvars

# Initialize and apply
terraform init
terraform apply
```

### Step 2: Configure Chart Migration

```bash
# Navigate to example directory
cd ../../../examples/single-chart

# Review configuration
cat charts-config.yaml

# Copy to scripts directory
cp charts-config.yaml ../../scripts/
```

### Step 3: Run Migration

```bash
# Navigate to scripts directory
cd ../../scripts

# Set AWS credentials
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Run migration tool
./ecr-artifact-manager.sh \
  --config charts-config.yaml \
  --log-file migration.log

# Monitor progress
tail -f migration.log
```

### Step 4: Verify Migration

```bash
# Check repository created
aws ecr describe-repositories \
  --repository-names helmchart/external-secrets \
  --region us-east-1

# List images in repository
aws ecr list-images \
  --repository-name helmchart/external-secrets \
  --region us-east-1

# Verify chart pushed
helm pull oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11
```

### Step 5: Deploy Chart from ECR

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# Install chart from ECR
helm install external-secrets \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11 \
  --namespace external-secrets-system \
  --create-namespace

# Verify deployment
kubectl get pods -n external-secrets-system
```

## Expected Results

### Repositories Created

```
helmchart/external-secrets
```

### Images Migrated

```
ghcr.io/external-secrets/external-secrets:v0.9.11
```

### Repository Settings

- **Encryption:** AWS KMS (customer-managed key)
- **Tag Mutability:** IMMUTABLE
- **Scanning:** SCAN_ON_PUSH enabled
- **Lifecycle Policy:** Expire untagged images after 2 days

## Validation

### Check Repository Configuration

```bash
# Verify encryption
aws ecr describe-repositories \
  --repository-names helmchart/external-secrets \
  --query 'repositories[0].encryptionConfiguration' \
  --output json

# Verify tag mutability
aws ecr describe-repositories \
  --repository-names helmchart/external-secrets \
  --query 'repositories[0].imageTagMutability' \
  --output text

# Verify scanning enabled
aws ecr describe-repositories \
  --repository-names helmchart/external-secrets \
  --query 'repositories[0].imageScanningConfiguration' \
  --output json
```

### Check Image Details

```bash
# List all images
aws ecr describe-images \
  --repository-name helmchart/external-secrets \
  --region us-east-1

# Check image scan findings
aws ecr describe-image-scan-findings \
  --repository-name helmchart/external-secrets \
  --image-id imageTag=0.9.11 \
  --region us-east-1
```

## Troubleshooting

### Issue: Chart Not Found

```bash
# Verify chart exists in public repository
helm search repo external-secrets/external-secrets

# Update Helm repositories
helm repo update
```

### Issue: Authentication Failed

```bash
# Re-authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
```

### Issue: Repository Not Created

```bash
# Verify Repository Creation Templates exist
aws ecr describe-repository-creation-templates \
  --region us-east-1

# Check IAM permissions
aws iam get-role-policy \
  --role-name ECRServiceRole \
  --policy-name ECRServicePolicy
```

## Cost Estimate

**Monthly Costs:**
- AWS KMS Key: $1.00
- ECR Storage (1GB): $0.10
- Scanning: $0.09 (per image scan)
- **Total: ~$1.19/month**

## Cleanup

```bash
# Uninstall Helm release
helm uninstall external-secrets -n external-secrets-system

# Delete ECR repository
aws ecr delete-repository \
  --repository-name helmchart/external-secrets \
  --force \
  --region us-east-1

# Destroy Terraform infrastructure
cd ../../terraform/modules/ecr-config
terraform destroy
```

## Next Steps

- Try [batch-processing](../batch-processing/) example for multiple charts
- See [multi-region](../multi-region/) example for disaster recovery
- Review [TROUBLESHOOTING.md](../../docs/TROUBLESHOOTING.md) for common issues
