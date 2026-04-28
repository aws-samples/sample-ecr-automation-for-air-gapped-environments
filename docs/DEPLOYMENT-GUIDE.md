# Deployment Guide

This guide provides step-by-step instructions for deploying the ECR Automation pattern for air-gapped environments.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1: Prepare Your Environment](#step-1-prepare-your-environment)
- [Step 2: Deploy Infrastructure](#step-2-deploy-infrastructure)
- [Step 3: Configure Artifact Migration](#step-3-configure-artifact-migration)
- [Step 4: Run Migration](#step-4-run-migration)
- [Step 5: Validate Deployment](#step-5-validate-deployment)
- [Step 6: Deploy to EKS](#step-6-deploy-to-eks)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### AWS Account Requirements
- Active AWS account with Amazon ECR enabled in target region(s)
- IAM permissions for ECR, AWS KMS, IAM, and CloudTrail operations
- AWS CLI v2.15.0 or later installed and configured
- AWS account must support Repository Creation Templates (available in all commercial regions)

### Technical Requirements
- **Terraform:** Version 1.0 or later
- **Docker:** Version 20.10 or later with BuildKit support
- **Helm:** Version 3.0 or later
- **Bash:** Version 4.0 or later
- **jq:** Version 1.6 or later
- **yq:** Version 4.0 or later
- **Network connectivity:** Internet access for initial artifact download

### Knowledge Prerequisites
- Basic understanding of container registries and Docker images
- Familiarity with Helm charts and Kubernetes concepts
- AWS IAM concepts and policy management
- Terraform basics for infrastructure deployment

## Step 1: Prepare Your Environment

### 1.1 Clone the Repository

```bash
git clone https://github.com/aws-samples/ecr-automation-air-gapped.git
cd ecr-automation-air-gapped
```

### 1.2 Verify Tool Installations

```bash
# Check Terraform
terraform version

# Check AWS CLI
aws --version

# Check Docker and BuildKit
docker version
docker buildx version

# Check Helm
helm version

# Check jq and yq
jq --version
yq --version

# Check Bash version
bash --version
```

### 1.3 Configure AWS Credentials

```bash
# Configure AWS CLI
aws configure

# Or use AWS SSO
aws sso login --profile your-profile

# Verify credentials
aws sts get-caller-identity
```

### 1.4 Set Environment Variables

```bash
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## Step 2: Deploy Infrastructure

### 2.1 Navigate to Terraform Directory

```bash
cd terraform
```

### 2.2 Create Terraform Variables File

```bash
# Copy example file
cp terraform.tfvars.example terraform.tfvars

# Edit with your values
vim terraform.tfvars
```

**Example terraform.tfvars:**

```hcl
region                = "us-east-1"
kms_key_alias         = "ecr-encryption-key"
enable_key_rotation   = true
multi_region_kms      = true

templates = [
  {
    prefix               = "helmchart/"
    description          = "Helm charts from public repositories"
    encryption_type      = "KMS"
    image_tag_mutability = "IMMUTABLE"
    lifecycle_policy     = "expire_untagged_2days"
    scanning_enabled     = true
  },
  {
    prefix               = "helmimages/"
    description          = "EKS add-on container images"
    encryption_type      = "KMS"
    image_tag_mutability = "IMMUTABLE"
    lifecycle_policy     = "expire_untagged_2days"
    scanning_enabled     = true
  }
]

enable_registry_scanning = true
scanning_type            = "ENHANCED"
scan_on_push             = true
continuous_scan          = true

tags = {
  Environment = "production"
  ManagedBy   = "terraform"
  Pattern     = "ecr-automation-air-gapped"
}
```

### 2.3 Initialize Terraform

```bash
terraform init
```

### 2.4 Review Terraform Plan

```bash
terraform plan
```

Review the output to ensure:
- AWS KMS key will be created with rotation enabled
- Repository Creation Templates match your requirements
- IAM roles have correct permissions
- Registry scanning is configured

### 2.5 Apply Terraform Configuration

```bash
terraform apply
```

Type `yes` when prompted to confirm.

### 2.6 Save Terraform Outputs

```bash
# Save outputs for later use
terraform output -json > terraform-outputs.json

# View AWS KMS key ARN
terraform output kms_key_arn

# View service role ARN
terraform output service_role_arn

# View template prefixes
terraform output template_prefixes
```

## Step 3: Configure Artifact Migration

### 3.1 Navigate to Scripts Directory

```bash
cd ../../../scripts
```

### 3.2 Create Charts Configuration

```bash
# Copy example file
cp charts-config.yaml.example charts-config.yaml

# Edit with your charts
vim charts-config.yaml
```

**Example charts-config.yaml:**

```yaml
charts:
  # AWS Load Balancer Controller
  - name: aws-load-balancer-controller
    repository: https://aws.github.io/eks-charts
    chart: eks/aws-load-balancer-controller
    version: 1.7.1

  # External Secrets Operator
  - name: external-secrets
    repository: https://charts.external-secrets.io
    chart: external-secrets/external-secrets
    version: 0.9.11

  # Metrics Server
  - name: metrics-server
    repository: https://kubernetes-sigs.github.io/metrics-server
    chart: metrics-server/metrics-server
    version: 3.12.0
```

### 3.3 Authenticate to Docker Hub (Optional but Recommended)

```bash
# Login to Docker Hub to avoid rate limits
docker login

# Enter your Docker Hub credentials
```

### 3.4 Test with Single Chart (Recommended)

```bash
# Test with one chart first
./ecr-artifact-manager.sh \
  --name metrics-server \
  --repository https://kubernetes-sigs.github.io/metrics-server \
  --chart metrics-server/metrics-server \
  --version 3.12.0 \
  --region $AWS_REGION
```

## Step 4: Run Migration

### 4.1 Run Full Migration

```bash
# Run migration with configuration file
./ecr-artifact-manager.sh \
  --config charts-config.yaml \
  --region $AWS_REGION \
  2>&1 | tee migration.log
```

### 4.2 Monitor Progress

The script will output detailed progress information:
- Chart downloads
- Image extraction
- Multi-architecture detection
- Image migration
- Chart updates
- Chart push to ECR

### 4.3 Review Summary

At the end, the script provides a summary:
- Successfully migrated charts
- Successfully migrated images
- Failed items (if any)
- Multi-architecture vs single-architecture images

### 4.4 Handle Failures (If Any)

If any items fail:

```bash
# Simply restart - tool automatically skips already-migrated items
./ecr-artifact-manager.sh \
  --config charts-config.yaml \
  --region $AWS_REGION
```

## Step 5: Validate Deployment

### 5.1 Verify Repository Creation Templates

```bash
# List templates
aws ecr describe-repository-creation-templates --region $AWS_REGION

# Verify template settings
aws ecr describe-repository-creation-templates \
  --region $AWS_REGION \
  --query 'repositoryCreationTemplates[*].[prefix,imageTagMutability,encryptionConfiguration.encryptionType]' \
  --output table
```

### 5.2 Verify Repositories

```bash
# List all repositories
aws ecr describe-repositories --region $AWS_REGION

# Check specific repository
aws ecr describe-repositories \
  --repository-names helmchart/metrics-server \
  --region $AWS_REGION
```

### 5.3 Verify Images

```bash
# List images in repository
aws ecr list-images \
  --repository-name helmchart/metrics-server \
  --region $AWS_REGION

# Check multi-architecture support
docker manifest inspect \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/helmchart/metrics-server:3.12.0
```

### 5.4 Verify Scanning

```bash
# Check scanning configuration
aws ecr get-registry-scanning-configuration --region $AWS_REGION

# Check scan results for an image
aws ecr describe-image-scan-findings \
  --repository-name helmchart/metrics-server \
  --image-id imageTag=3.12.0 \
  --region $AWS_REGION
```

### 5.5 Verify AWS KMS Encryption

```bash
# Check repository encryption
aws ecr describe-repositories \
  --repository-names helmchart/metrics-server \
  --region $AWS_REGION \
  --query 'repositories[0].encryptionConfiguration'
```

## Step 6: Deploy to EKS

### 6.1 Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig \
  --name your-cluster-name \
  --region $AWS_REGION
```

### 6.2 Authenticate Helm to ECR

```bash
# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  helm registry login \
  --username AWS \
  --password-stdin \
  $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
```

### 6.3 Deploy Helm Chart

```bash
# Install chart from ECR
helm install metrics-server \
  oci://$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/helmchart/metrics-server \
  --version 3.12.0 \
  --namespace kube-system
```

### 6.4 Verify Deployment

```bash
# Check pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server

# Check deployment
kubectl get deployment metrics-server -n kube-system

# Check logs
kubectl logs -n kube-system -l app.kubernetes.io/name=metrics-server
```

## Troubleshooting

### Issue: CREATE_ON_PUSH Not Working

**Solution:**
```bash
# Verify templates exist
aws ecr describe-repository-creation-templates --region $AWS_REGION

# Check template prefix matches repository name
# Template prefix: helmchart/
# Repository name must start with: helmchart/
```

### Issue: Docker Hub Rate Limiting

**Solution:**
```bash
# Login to Docker Hub
docker login

# Or use alternative registries
# Edit charts-config.yaml to use quay.io or ghcr.io
```

### Issue: Multi-Architecture Images Not Preserved

**Solution:**
```bash
# Verify Docker BuildKit is enabled
docker buildx version

# Check source image has multiple platforms
docker manifest inspect docker.io/nginx:latest
```

### Issue: Migration Script Fails

**Solution:**
```bash
# Simply restart - tool automatically skips already-migrated items
./ecr-artifact-manager.sh --config charts-config.yaml --region $AWS_REGION

# Or run with debug mode
bash -x ./ecr-artifact-manager.sh --config charts-config.yaml --region $AWS_REGION
```

For more troubleshooting scenarios, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Next Steps

1. **Review Security:** See [SECURITY.md](SECURITY.md) for security best practices
2. **Plan for Scale:** See [SCALING-GUIDE.md](SCALING-GUIDE.md) for large deployments
3. **Optimize Costs:** See [COST-ANALYSIS.md](COST-ANALYSIS.md) for cost optimization
4. **Migrate Existing Repositories:** See [MIGRATING-EXISTING-REPOSITORIES.md](MIGRATING-EXISTING-REPOSITORIES.md)

## Related Documentation

- [Architecture Overview](ARCHITECTURE.md) - System architecture
- [Security Best Practices](SECURITY.md) - Security configuration
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
- [Cost Analysis](COST-ANALYSIS.md) - Cost estimation and optimization
- [Scaling Guide](SCALING-GUIDE.md) - Large-scale deployments
