# Batch Processing Example

This example demonstrates migrating multiple Helm charts in a single batch operation.

## Overview

This example migrates 10 commonly used Helm charts for EKS deployments to ECR in a single batch.

**Charts Included:**
1. external-secrets - Secret management
2. aws-load-balancer-controller - ALB/NLB integration
3. metrics-server - Resource metrics
4. cluster-autoscaler - Node autoscaling
5. aws-ebs-csi-driver - EBS volume provisioning
6. aws-efs-csi-driver - EFS volume provisioning
7. kube-state-metrics - Cluster state metrics
8. cert-manager - Certificate management
9. ingress-nginx - Ingress controller
10. external-dns - DNS management

## Prerequisites

- AWS CLI configured with appropriate permissions
- Docker installed and running
- Helm 3.x installed
- ECR Repository Creation Templates deployed
- AWS KMS key created for ECR encryption
- Sufficient ECR storage quota (estimate: 10GB)

## Configuration Files

### charts-config.yaml

Defines all charts to migrate in batch:

```yaml
charts:
  - name: external-secrets
    repo_url: https://charts.external-secrets.io
    repo_name: external-secrets
    version: 0.9.11
    namespace: helmchart

  - name: aws-load-balancer-controller
    repo_url: https://aws.github.io/eks-charts
    repo_name: eks
    version: 1.7.1
    namespace: helmchart

  # ... (see full file for all charts)
```

### terraform.tfvars.example

Terraform variables for ECR infrastructure:

```hcl
aws_region = "us-east-1"
kms_key_alias = "ecr-encryption-key"
enable_key_rotation = true

repository_prefixes = [
  "helmchart/",
  "helmimages/"
]
```

## Step-by-Step Instructions

### Step 1: Deploy ECR Infrastructure

```bash
# Navigate to Terraform module
cd ../../terraform/modules/ecr-config

# Copy example tfvars
cp ../../../examples/batch-processing/terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars with your values
vim terraform.tfvars

# Initialize and apply
terraform init
terraform apply
```

### Step 2: Configure Batch Migration

```bash
# Navigate to example directory
cd ../../../examples/batch-processing

# Review configuration
cat charts-config.yaml

# Copy to scripts directory
cp charts-config.yaml ../../scripts/
```

### Step 3: Run Batch Migration

```bash
# Navigate to scripts directory
cd ../../scripts

# Set AWS credentials
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Run migration tool
./ecr-artifact-manager.sh \
  --config charts-config.yaml \
  --log-file batch-migration.log

# Monitor progress in another terminal
tail -f batch-migration.log
```

**Expected Duration:** 30-60 minutes depending on network speed

### Step 4: Verify Migration

```bash
# Check all repositories created
aws ecr describe-repositories \
  --region us-east-1 \
  --query 'repositories[].repositoryName' \
  --output table

# Count repositories
aws ecr describe-repositories \
  --region us-east-1 \
  --query 'length(repositories)' \
  --output text

# Verify specific chart
helm pull oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11
```

### Step 5: Deploy Charts from ECR

```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin \
  ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com

# Install external-secrets
helm install external-secrets \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/helmchart/external-secrets \
  --version 0.9.11 \
  --namespace external-secrets-system \
  --create-namespace

# Install aws-load-balancer-controller
helm install aws-load-balancer-controller \
  oci://${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/helmchart/aws-load-balancer-controller \
  --version 1.7.1 \
  --namespace kube-system \
  --set clusterName=my-cluster

# Verify deployments
kubectl get pods -A
```

## Expected Results

### Repositories Created

```
helmchart/external-secrets
helmchart/aws-load-balancer-controller
helmchart/metrics-server
helmchart/cluster-autoscaler
helmchart/aws-ebs-csi-driver
helmchart/aws-efs-csi-driver
helmchart/kube-state-metrics
helmchart/cert-manager
helmchart/ingress-nginx
helmchart/external-dns
```

### Images Migrated

Approximately 15-20 container images (including dependencies)

### Repository Settings

All repositories configured with:
- **Encryption:** AWS KMS (customer-managed key)
- **Tag Mutability:** IMMUTABLE
- **Scanning:** SCAN_ON_PUSH enabled
- **Lifecycle Policy:** Expire untagged images after 2 days

## Monitoring Progress

### Real-Time Monitoring

```bash
# Watch repository count
watch -n 30 'aws ecr describe-repositories --region us-east-1 --query "length(repositories)"'

# Monitor log file
tail -f batch-migration.log | grep -E "Processing|Successfully|Error"

# Check for errors
grep -i error batch-migration.log
```

### Progress Summary

```bash
# Count successful migrations
grep -c "Successfully pushed" batch-migration.log

# Count failed migrations
grep -c "Failed to" batch-migration.log

# List failed charts
grep "Failed to" batch-migration.log | awk '{print $NF}'
```

## Validation

### Comprehensive Validation Script

```bash
#!/bin/bash
# validate-batch-migration.sh

EXPECTED_REPOS=(
  "helmchart/external-secrets"
  "helmchart/aws-load-balancer-controller"
  "helmchart/metrics-server"
  "helmchart/cluster-autoscaler"
  "helmchart/aws-ebs-csi-driver"
  "helmchart/aws-efs-csi-driver"
  "helmchart/kube-state-metrics"
  "helmchart/cert-manager"
  "helmchart/ingress-nginx"
  "helmchart/external-dns"
)

echo "Validating batch migration..."
echo ""

success_count=0
fail_count=0

for repo in "${EXPECTED_REPOS[@]}"; do
  if aws ecr describe-repositories --repository-names "$repo" --region us-east-1 &>/dev/null; then
    echo "✓ $repo - exists"
    
    # Check encryption
    encryption=$(aws ecr describe-repositories \
      --repository-names "$repo" \
      --query 'repositories[0].encryptionConfiguration.encryptionType' \
      --output text)
    
    if [[ "$encryption" == "AWS KMS" ]]; then
      echo "  ✓ AWS KMS encryption enabled"
    else
      echo "  ✗ AWS KMS encryption not enabled (found: $encryption)"
    fi
    
    success_count=$((success_count + 1))
  else
    echo "✗ $repo - missing"
    fail_count=$((fail_count + 1))
  fi
  echo ""
done

echo "Summary:"
echo "  Success: $success_count/${#EXPECTED_REPOS[@]}"
echo "  Failed: $fail_count/${#EXPECTED_REPOS[@]}"
```

## Troubleshooting

### Issue: Some Charts Failed to Migrate

```bash
# Check log for specific errors
grep -A 5 "Failed to" batch-migration.log

# Retry failed charts only
# Edit charts-config.yaml to include only failed charts
./ecr-artifact-manager.sh --config charts-config-retry.yaml
```

### Issue: Docker Hub Rate Limit

```bash
# Symptom in log
Error: toomanyrequests: You have reached your pull rate limit

# Solution: Use authenticated Docker Hub access
docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD

# Or wait and retry
sleep 3600  # Wait 1 hour
./ecr-artifact-manager.sh --config charts-config.yaml
```

### Issue: Out of Disk Space

```bash
# Check disk space
df -h

# Clean up Docker images
docker system prune -a -f

# Retry migration
./ecr-artifact-manager.sh --config charts-config.yaml
```

## Performance Optimization

### For Faster Migration

```bash
# Use EC2 instance with high bandwidth
# t3.xlarge or larger recommended

# Run from same region as ECR
# Reduces network latency

# Use authenticated Docker Hub access
# Increases rate limit from 100 to 200 pulls/6 hours
```

### Parallel Processing

```bash
# Split charts into multiple batches
# Run multiple instances in parallel

# Terminal 1: Batch 1 (charts 1-5)
./ecr-artifact-manager.sh --config batch1.yaml

# Terminal 2: Batch 2 (charts 6-10)
./ecr-artifact-manager.sh --config batch2.yaml
```

## Cost Estimate

**Monthly Costs:**
- AWS KMS Key: $1.00
- ECR Storage (10GB): $1.00
- Scanning (10 repositories): $0.90
- Data Transfer: $5.00
- **Total: ~$7.90/month**

**One-Time Migration Costs:**
- EC2 Instance (t3.large, 1 hour): $0.08
- Data Transfer (download): $5.00
- **Total: ~$5.08**

## Cleanup

```bash
# Uninstall all Helm releases
helm list -A | awk 'NR>1 {print $1, $2}' | while read name namespace; do
  helm uninstall $name -n $namespace
done

# Delete all ECR repositories
for repo in "${EXPECTED_REPOS[@]}"; do
  aws ecr delete-repository \
    --repository-name "$repo" \
    --force \
    --region us-east-1
done

# Destroy Terraform infrastructure
cd ../../terraform/modules/ecr-config
terraform destroy
```

## Next Steps

- Try [multi-region](../multi-region/) example for disaster recovery
- Review [SCALING-GUIDE.md](../../docs/SCALING-GUIDE.md) for larger deployments
- See [TROUBLESHOOTING.md](../../docs/TROUBLESHOOTING.md) for common issues
