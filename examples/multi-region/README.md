# Multi-Region Example

This example demonstrates deploying ECR infrastructure across multiple AWS regions for disaster recovery and high availability.

## Overview

This example deploys the same ECR configuration to three regions:
- **Primary:** us-east-1 (N. Virginia)
- **Secondary:** us-west-2 (Oregon)
- **Tertiary:** eu-west-1 (Ireland)

**Benefits:**
- Disaster recovery and business continuity
- Reduced latency for global deployments
- Compliance with data residency requirements
- High availability across regions

## Prerequisites

- AWS CLI configured with appropriate permissions
- Docker installed and running
- Helm 3.x installed
- Terraform installed
- Access to multiple AWS regions
- Sufficient ECR storage quota in each region

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Multi-Region Setup                      │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐ │
│  │  us-east-1   │    │  us-west-2   │    │  eu-west-1   │ │
│  │  (Primary)   │    │ (Secondary)  │    │  (Tertiary)  │ │
│  │              │    │              │    │              │ │
│  │ • AWS KMS Key    │    │ • AWS KMS Key    │    │ • AWS KMS Key    │ │
│  │ • Templates  │    │ • Templates  │    │ • Templates  │ │
│  │ • ECR Repos  │    │ • ECR Repos  │    │ • ECR Repos  │ │
│  └──────────────┘    └──────────────┘    └──────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

## Configuration Files

### terraform.tfvars.example

Terraform variables for multi-region deployment:

```hcl
# Primary region
primary_region = "us-east-1"

# Additional regions for replication
additional_regions = [
  "us-west-2",
  "eu-west-1"
]

# AWS KMS key configuration
kms_key_alias = "ecr-encryption-key"
enable_key_rotation = true
enable_multi_region_key = true

# Repository prefixes
repository_prefixes = [
  "helmchart/",
  "helmimages/"
]
```

### charts-config.yaml

Same chart configuration, deployed to all regions:

```yaml
charts:
  - name: external-secrets
    repo_url: https://charts.external-secrets.io
    repo_name: external-secrets
    version: 0.9.11
    namespace: helmchart
```

## Step-by-Step Instructions

### Step 1: Deploy ECR Infrastructure to All Regions

```bash
# Navigate to Terraform module
cd ../../terraform/modules/ecr-config

# Copy example tfvars
cp ../../../examples/multi-region/terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
vim terraform.tfvars

# Initialize Terraform
terraform init

# Plan deployment
terraform plan

# Apply to all regions
terraform apply
```

### Step 2: Migrate Charts to Primary Region

```bash
# Navigate to scripts directory
cd ../../../scripts

# Set primary region
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Run migration tool for primary region
./ecr-artifact-manager.sh \
  --config ../examples/multi-region/charts-config.yaml \
  --log-file migration-us-east-1.log
```

### Step 3: Replicate to Secondary Regions

#### Option A: Re-run Migration Tool (Recommended)

```bash
# Migrate to us-west-2
export AWS_REGION=us-west-2
./ecr-artifact-manager.sh \
  --config ../examples/multi-region/charts-config.yaml \
  --log-file migration-us-west-2.log

# Migrate to eu-west-1
export AWS_REGION=eu-west-1
./ecr-artifact-manager.sh \
  --config ../examples/multi-region/charts-config.yaml \
  --log-file migration-eu-west-1.log
```

#### Option B: Copy from Primary Region

```bash
#!/bin/bash
# replicate-to-regions.sh

PRIMARY_REGION="us-east-1"
SECONDARY_REGIONS=("us-west-2" "eu-west-1")
REPOSITORY="helmchart/external-secrets"
TAG="0.9.11"

# Get primary ECR URL
PRIMARY_ECR="${AWS_ACCOUNT_ID}.dkr.ecr.${PRIMARY_REGION}.amazonaws.com"

# Pull from primary
docker pull "${PRIMARY_ECR}/${REPOSITORY}:${TAG}"

# Push to secondary regions
for region in "${SECONDARY_REGIONS[@]}"; do
  echo "Replicating to $region..."
  
  # Login to secondary region
  aws ecr get-login-password --region "$region" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com"
  
  # Tag for secondary region
  docker tag "${PRIMARY_ECR}/${REPOSITORY}:${TAG}" \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com/${REPOSITORY}:${TAG}"
  
  # Push to secondary region
  docker push "${AWS_ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com/${REPOSITORY}:${TAG}"
done
```

### Step 4: Verify Multi-Region Deployment

```bash
#!/bin/bash
# verify-multi-region.sh

REGIONS=("us-east-1" "us-west-2" "eu-west-1")
REPOSITORY="helmchart/external-secrets"

for region in "${REGIONS[@]}"; do
  echo "Checking $region..."
  
  # Check repository exists
  if aws ecr describe-repositories \
    --repository-names "$REPOSITORY" \
    --region "$region" &>/dev/null; then
    echo "  ✓ Repository exists"
    
    # Count images
    image_count=$(aws ecr list-images \
      --repository-name "$REPOSITORY" \
      --region "$region" \
      --query 'length(imageIds)')
    echo "  ✓ Images: $image_count"
  else
    echo "  ✗ Repository not found"
  fi
  echo ""
done
```

### Step 5: Configure Regional EKS Clusters

```bash
# Deploy to us-east-1 cluster
export AWS_REGION=us-east-1
aws eks update-kubeconfig --name my-cluster-east --region us-east-1

helm install external-secrets \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11 \
  --namespace external-secrets-system \
  --create-namespace

# Deploy to us-west-2 cluster
export AWS_REGION=us-west-2
aws eks update-kubeconfig --name my-cluster-west --region us-west-2

helm install external-secrets \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11 \
  --namespace external-secrets-system \
  --create-namespace

# Deploy to eu-west-1 cluster
export AWS_REGION=eu-west-1
aws eks update-kubeconfig --name my-cluster-eu --region eu-west-1

helm install external-secrets \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.eu-west-1.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11 \
  --namespace external-secrets-system \
  --create-namespace
```

## Disaster Recovery Scenarios

### Scenario 1: Primary Region Failure

```bash
# Automatically failover to secondary region
export AWS_REGION=us-west-2

# Update kubeconfig to secondary cluster
aws eks update-kubeconfig --name my-cluster-west --region us-west-2

# Deploy from secondary region ECR
helm install external-secrets \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11 \
  --namespace external-secrets-system \
  --create-namespace
```

### Scenario 2: Regional ECR Outage

```bash
# Use images from alternate region
# Update deployment to use different ECR URL

kubectl set image deployment/external-secrets \
  external-secrets=${AWS_ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com/helmchart/external-secrets:0.9.11 \
  -n external-secrets-system
```

## Cost Analysis

### Monthly Costs per Region

**Single Region:**
- AWS KMS Key: $1.00
- ECR Storage (10GB): $1.00
- Scanning: $0.90
- **Subtotal: $2.90/region**

**Three Regions:**
- Total: $8.70/month

### Cross-Region Data Transfer

**Replication Costs:**
- us-east-1 → us-west-2: $0.02/GB
- us-east-1 → eu-west-1: $0.02/GB
- One-time transfer (10GB): $0.40

**Ongoing Costs:**
- Minimal (only new images)
- Estimate: $5-10/month for active development

### Total Monthly Cost

- Infrastructure: $8.70
- Data Transfer: $7.50 (average)
- **Total: ~$16.20/month**

## Best Practices

### 1. Use Multi-Region AWS KMS Keys

```hcl
resource "aws_kms_key" "ecr" {
  description             = "ECR encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true  # Enable multi-region

  tags = {
    Name = "ecr-encryption-key"
  }
}

# Replicate to secondary regions
resource "aws_kms_replica_key" "ecr_west" {
  provider = aws.us-west-2
  
  description             = "ECR encryption key replica"
  primary_key_arn        = aws_kms_key.ecr.arn
  deletion_window_in_days = 30
}
```

### 2. Automate Replication

```bash
# Use AWS EventBridge to trigger replication
# When image pushed to primary region, replicate to secondary regions

# Example: Lambda function triggered by ECR events
aws events put-rule \
  --name ecr-replication \
  --event-pattern '{
    "source": ["aws.ecr"],
    "detail-type": ["ECR Image Action"],
    "detail": {
      "action-type": ["PUSH"],
      "result": ["SUCCESS"]
    }
  }'
```

### 3. Monitor Replication Status

```bash
# CloudWatch dashboard for multi-region monitoring
aws cloudwatch put-dashboard \
  --dashboard-name ecr-multi-region \
  --dashboard-body file://dashboard.json
```

### 4. Test Failover Regularly

```bash
# Quarterly DR drill
# 1. Simulate primary region failure
# 2. Failover to secondary region
# 3. Verify all services operational
# 4. Document lessons learned
```

## Troubleshooting

### Issue: Replication Lag

```bash
# Check replication status
for region in us-east-1 us-west-2 eu-west-1; do
  echo "Region: $region"
  aws ecr describe-images \
    --repository-name helmchart/external-secrets \
    --region "$region" \
    --query 'imageDetails[0].imagePushedAt' \
    --output text
done
```

### Issue: Cross-Region Authentication

```bash
# Ensure credentials work in all regions
for region in us-east-1 us-west-2 eu-west-1; do
  echo "Testing $region..."
  aws ecr get-login-password --region "$region" | \
    docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com"
done
```

### Issue: Inconsistent Repository Settings

```bash
# Verify settings match across regions
for region in us-east-1 us-west-2 eu-west-1; do
  echo "Region: $region"
  aws ecr describe-repositories \
    --repository-names helmchart/external-secrets \
    --region "$region" \
    --query 'repositories[0].{Encryption:encryptionConfiguration.encryptionType,Mutability:imageTagMutability}'
done
```

## Cleanup

```bash
# Delete repositories in all regions
for region in us-east-1 us-west-2 eu-west-1; do
  echo "Cleaning up $region..."
  aws ecr delete-repository \
    --repository-name helmchart/external-secrets \
    --force \
    --region "$region"
done

# Destroy Terraform infrastructure
cd ../../terraform/modules/ecr-config
terraform destroy
```

## Next Steps

- Review [SCALING-GUIDE.md](../../docs/SCALING-GUIDE.md) for performance optimization
- See [COST-ANALYSIS.md](../../docs/COST-ANALYSIS.md) for cost optimization strategies
- Check [TROUBLESHOOTING.md](../../docs/TROUBLESHOOTING.md) for common issues
