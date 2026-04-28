# Migrating Existing Repositories

> **Important:** This is sample code. You should work with your security and legal teams to meet your organizational requirements before deployment.

This guide covers strategies for aligning existing ECR repositories with Repository Creation Template standards.

## Overview

### When to Use This Guide

This guide is for organizations that:
- Already have ECR repositories in production
- Want to adopt Repository Creation Templates for new repositories
- Need to align existing repositories with template standards
- Are migrating from manual repository management to automated templates

### AWS Service Constraint

**Important:** AWS Repository Creation Templates only apply to repositories created via CREATE_ON_PUSH. They cannot retroactively modify existing repositories. This is an AWS service limitation, not a pattern limitation.

However, you can achieve the same security configuration using the strategies in this guide.

## Decision Matrix

Choose the right strategy based on your requirements:

| Criteria | In-Place Update | Blue-Green Migration | Terraform Import |
|----------|----------------|---------------------|------------------|
| **Downtime** | None | None | None |
| **Complexity** | Low | Medium | High |
| **Template Management** | No | Yes | No |
| **Repository URLs Change** | No | Yes | No |
| **Best For** | Production systems | Non-production | IaC environments |
| **Rollback Ease** | Difficult | Easy | Medium |
| **Time Required** | 1-2 hours | 4-8 hours | 2-4 hours |

## Strategy 1: In-Place Update (Recommended for Production)

### Overview

Update existing repositories to match template settings without recreation.

### Pros and Cons

**Pros:**
- ✅ No downtime
- ✅ Preserves existing images
- ✅ Maintains repository URLs
- ✅ Quick implementation

**Cons:**
- ❌ Repositories not managed by templates
- ❌ Manual drift possible
- ❌ Requires careful validation
- ❌ AWS KMS encryption cannot be changed (if already using AES256)

### Prerequisites

- AWS CLI configured with appropriate permissions
- List of existing repositories
- Target template configuration
- Backup of current repository settings

### Step-by-Step Procedure

#### Step 1: Audit Existing Repositories

```bash
#!/bin/bash
# audit-repositories.sh

> **Important:** This is sample code. You should work with your security and legal teams to meet your organizational requirements before deployment.

AWS_REGION="us-east-1"
OUTPUT_FILE="repository-audit.csv"

echo "Repository,Encryption,Mutability,Scanning,LifecyclePolicy" > "$OUTPUT_FILE"

# Get all repositories
repositories=$(aws ecr describe-repositories \
  --region "$AWS_REGION" \
  --query 'repositories[].repositoryName' \
  --output text)

for repo in $repositories; do
  # Get repository details
  details=$(aws ecr describe-repositories \
    --repository-names "$repo" \
    --region "$AWS_REGION" \
    --query 'repositories[0]')
  
  encryption=$(echo "$details" | jq -r '.encryptionConfiguration.encryptionType')
  mutability=$(echo "$details" | jq -r '.imageTagMutability')
  
  # Check scanning configuration
  scanning=$(aws ecr get-repository-policy \
    --repository-name "$repo" \
    --region "$AWS_REGION" \
    --query 'imageScanningConfiguration.scanOnPush' \
    --output text 2>/dev/null || echo "false")
  
  # Check lifecycle policy
  lifecycle=$(aws ecr get-lifecycle-policy \
    --repository-name "$repo" \
    --region "$AWS_REGION" \
    --query 'lifecyclePolicyText' \
    --output text 2>/dev/null && echo "true" || echo "false")
  
  echo "$repo,$encryption,$mutability,$scanning,$lifecycle" >> "$OUTPUT_FILE"
done

echo "Audit complete. Results saved to $OUTPUT_FILE"
```

#### Step 2: Identify Gaps

```bash
#!/bin/bash
# identify-gaps.sh

# Target configuration (from template)
TARGET_ENCRYPTION="KMS"
TARGET_MUTABILITY="IMMUTABLE"
TARGET_SCANNING="true"
TARGET_LIFECYCLE="true"

# Read audit results
while IFS=',' read -r repo encryption mutability scanning lifecycle; do
  if [[ "$repo" == "Repository" ]]; then
    continue  # Skip header
  fi
  
  gaps=""
  
  # Check encryption (cannot be changed if already set)
  if [[ "$encryption" != "$TARGET_ENCRYPTION" && "$encryption" != "null" ]]; then
    gaps="$gaps ENCRYPTION_MISMATCH"
  fi
  
  # Check mutability
  if [[ "$mutability" != "$TARGET_MUTABILITY" ]]; then
    gaps="$gaps MUTABILITY"
  fi
  
  # Check scanning
  if [[ "$scanning" != "$TARGET_SCANNING" ]]; then
    gaps="$gaps SCANNING"
  fi
  
  # Check lifecycle
  if [[ "$lifecycle" != "$TARGET_LIFECYCLE" ]]; then
    gaps="$gaps LIFECYCLE"
  fi
  
  if [[ -n "$gaps" ]]; then
    echo "Repository: $repo"
    echo "  Gaps:$gaps"
    echo ""
  fi
done < repository-audit.csv
```

#### Step 3: Update Repository Settings

```bash
#!/bin/bash
# update-repository-settings.sh

AWS_REGION="us-east-1"
KMS_KEY_ID="arn:aws:kms:us-east-1:123456789012:key/xxxxx"
REPOSITORY_NAME="$1"

if [[ -z "$REPOSITORY_NAME" ]]; then
  echo "Usage: $0 <repository-name>"
  exit 1
fi

echo "Updating repository: $REPOSITORY_NAME"

# Update tag mutability
echo "Setting tag mutability to IMMUTABLE..."
aws ecr put-image-tag-mutability \
  --repository-name "$REPOSITORY_NAME" \
  --image-tag-mutability IMMUTABLE \
  --region "$AWS_REGION"

# Apply lifecycle policy
echo "Applying lifecycle policy..."
cat > lifecycle-policy.json <<EOF
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
EOF

aws ecr put-lifecycle-policy \
  --repository-name "$REPOSITORY_NAME" \
  --lifecycle-policy-text file://lifecycle-policy.json \
  --region "$AWS_REGION"

# Enable scanning
echo "Enabling image scanning..."
aws ecr put-image-scanning-configuration \
  --repository-name "$REPOSITORY_NAME" \
  --image-scanning-configuration scanOnPush=true \
  --region "$AWS_REGION"

echo "Repository updated successfully"
```

#### Step 4: Validate Changes

```bash
#!/bin/bash
# validate-repository.sh

AWS_REGION="us-east-1"
REPOSITORY_NAME="$1"

echo "Validating repository: $REPOSITORY_NAME"

# Get repository details
details=$(aws ecr describe-repositories \
  --repository-names "$REPOSITORY_NAME" \
  --region "$AWS_REGION" \
  --query 'repositories[0]')

encryption=$(echo "$details" | jq -r '.encryptionConfiguration.encryptionType')
mutability=$(echo "$details" | jq -r '.imageTagMutability')

echo "Encryption: $encryption (expected: AWS KMS)"
echo "Mutability: $mutability (expected: IMMUTABLE)"

# Check scanning
scanning=$(aws ecr describe-repositories \
  --repository-names "$REPOSITORY_NAME" \
  --region "$AWS_REGION" \
  --query 'repositories[0].imageScanningConfiguration.scanOnPush' \
  --output text)

echo "Scanning: $scanning (expected: true)"

# Check lifecycle policy
lifecycle=$(aws ecr get-lifecycle-policy \
  --repository-name "$REPOSITORY_NAME" \
  --region "$AWS_REGION" \
  --query 'lifecyclePolicyText' \
  --output text 2>/dev/null && echo "configured" || echo "not configured")

echo "Lifecycle Policy: $lifecycle (expected: configured)"
```

### Important Notes

**AWS KMS Encryption Limitation:**
- If a repository uses AWS-managed encryption (AES256), it **cannot** be changed to customer-managed AWS KMS encryption
- The only option is Strategy 2 (Blue-Green Migration) to create a new repository with AWS KMS encryption
- New repositories without encryption can have AWS KMS encryption enabled

**Validation:**
- validate changes before proceeding to next repository
- Test with non-production repositories first
- Keep audit trail of all changes

## Strategy 2: Blue-Green Migration (Recommended for Non-Production)

### Overview

Create new template-managed repositories and migrate images.

### Pros and Cons

**Pros:**
- ✅ New repositories fully managed by templates
- ✅ Easy rollback (keep old repositories)
- ✅ Clean slate with correct configuration
- ✅ Can change AWS KMS encryption

**Cons:**
- ❌ Requires application configuration updates
- ❌ Temporary storage duplication
- ❌ More complex migration process
- ❌ Repository URLs change

### Prerequisites

- Repository Creation Templates deployed
- List of repositories to migrate
- Application configuration access
- Sufficient ECR storage quota

### Step-by-Step Procedure

#### Step 1: Deploy Repository Creation Templates

```bash
# Deploy Terraform module
cd terraform/modules/ecr-config
terraform init
terraform plan
terraform apply
```

#### Step 2: Create Migration Plan

```bash
#!/bin/bash
# create-migration-plan.sh

# List existing repositories
aws ecr describe-repositories \
  --region us-east-1 \
  --query 'repositories[].repositoryName' \
  --output text > existing-repos.txt

# Create migration plan
while read -r repo; do
  echo "Old: $repo"
  echo "New: ${repo}-v2"
  echo "---"
done < existing-repos.txt > migration-plan.txt
```

#### Step 3: Copy Images to New Repositories

```bash
#!/bin/bash
# migrate-images.sh

AWS_REGION="us-east-1"
ECR_URL="123456789012.dkr.ecr.us-east-1.amazonaws.com"
OLD_REPO="$1"
NEW_REPO="${OLD_REPO}-v2"

echo "Migrating from $OLD_REPO to $NEW_REPO"

# Get all image tags
tags=$(aws ecr list-images \
  --repository-name "$OLD_REPO" \
  --region "$AWS_REGION" \
  --query 'imageIds[?imageTag!=`null`].imageTag' \
  --output text)

# Copy each image
for tag in $tags; do
  echo "Copying tag: $tag"
  
  # Pull from old repository
  docker pull "$ECR_URL/$OLD_REPO:$tag"
  
  # Tag for new repository
  docker tag "$ECR_URL/$OLD_REPO:$tag" "$ECR_URL/$NEW_REPO:$tag"
  
  # Push to new repository (auto-created via CREATE_ON_PUSH)
  docker push "$ECR_URL/$NEW_REPO:$tag"
  
  # Clean up local images
  docker rmi "$ECR_URL/$OLD_REPO:$tag"
  docker rmi "$ECR_URL/$NEW_REPO:$tag"
done

echo "Migration complete for $OLD_REPO"
```

#### Step 4: Update Application Configurations

```bash
# Example: Update Kubernetes deployments
kubectl get deployments -A -o yaml | \
  sed "s|$ECR_URL/$OLD_REPO|$ECR_URL/$NEW_REPO|g" | \
  kubectl apply -f -

# Example: Update Helm values
sed -i "s|repository: $OLD_REPO|repository: $NEW_REPO|g" values.yaml
```

#### Step 5: Validate New Repositories

```bash
#!/bin/bash
# validate-new-repository.sh

NEW_REPO="$1"

# Verify repository exists
aws ecr describe-repositories \
  --repository-names "$NEW_REPO" \
  --region us-east-1

# Verify template settings applied
aws ecr describe-repositories \
  --repository-names "$NEW_REPO" \
  --region us-east-1 \
  --query 'repositories[0].{Encryption:encryptionConfiguration.encryptionType,Mutability:imageTagMutability}'

# Verify images copied
old_count=$(aws ecr list-images --repository-name "$OLD_REPO" --region us-east-1 --query 'length(imageIds)')
new_count=$(aws ecr list-images --repository-name "$NEW_REPO" --region us-east-1 --query 'length(imageIds)')

echo "Old repository images: $old_count"
echo "New repository images: $new_count"
```

#### Step 6: Decommission Old Repositories

```bash
#!/bin/bash
# decommission-old-repository.sh

OLD_REPO="$1"
GRACE_PERIOD_DAYS=30

echo "Decommissioning $OLD_REPO after $GRACE_PERIOD_DAYS days grace period"

# Add tag to mark for deletion
aws ecr tag-resource \
  --resource-arn "arn:aws:ecr:us-east-1:123456789012:repository/$OLD_REPO" \
  --tags Key=Status,Value=Deprecated Key=DeleteAfter,Value=$(date -d "+$GRACE_PERIOD_DAYS days" +%Y-%m-%d)

# After grace period, delete repository
# aws ecr delete-repository --repository-name "$OLD_REPO" --force
```

## Strategy 3: Terraform Import (For IaC-Managed Environments)

### Overview

Import existing repositories into Terraform and align with template settings.

### Pros and Cons

**Pros:**
- ✅ Infrastructure as Code management
- ✅ Drift detection and prevention
- ✅ Consistent configuration
- ✅ No repository URL changes

**Cons:**
- ❌ Requires Terraform expertise
- ❌ Initial import effort
- ❌ Not template-managed (manual Terraform updates needed)
- ❌ Cannot change AWS KMS encryption if already set

### Prerequisites

- Terraform installed and configured
- AWS credentials with ECR permissions
- List of existing repositories
- Terraform state management configured

### Step-by-Step Procedure

#### Step 1: Create Terraform Configuration

```hcl
# existing-repositories.tf

# Import existing repository
# Run: terraform import aws_ecr_repository.my_app my-app-repo

resource "aws_ecr_repository" "my_app" {
  name                 = "my-app-repo"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
    kms_key        = aws_kms_key.ecr.arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

resource "aws_ecr_lifecycle_policy" "my_app" {
  repository = aws_ecr_repository.my_app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 2 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 2
      }
      action = {
        type = "expire"
      }
    }]
  })
}
```

#### Step 2: Import Existing Repositories

```bash
#!/bin/bash
# import-repositories.sh

# List of repositories to import
repositories=(
  "my-app-repo"
  "my-service-repo"
  "my-worker-repo"
)

for repo in "${repositories[@]}"; do
  echo "Importing repository: $repo"
  
  # Import repository
  terraform import "aws_ecr_repository.${repo//-/_}" "$repo"
  
  # Import lifecycle policy (if exists)
  terraform import "aws_ecr_lifecycle_policy.${repo//-/_}" "$repo" || true
done
```

#### Step 3: Align Configuration with Template Standards

```bash
# Run Terraform plan to see differences
terraform plan

# Apply changes to align with template standards
terraform apply
```

#### Step 4: Enable Drift Detection

```hcl
# drift-detection.tf

resource "aws_config_config_rule" "ecr_repository_compliance" {
  name = "ecr-repository-compliance"

  source {
    owner             = "AWS"
    source_identifier = "ECR_PRIVATE_IMAGE_SCANNING_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder.main]
}
```

## Validation Checklist

After completing migration, verify:

- [ ] All repositories have AWS KMS encryption (or documented exception)
- [ ] All repositories have IMMUTABLE tag mutability
- [ ] All repositories have lifecycle policies configured
- [ ] All repositories have scanning enabled
- [ ] Application deployments work with new repositories (Strategy 2)
- [ ] Terraform state is up to date (Strategy 3)
- [ ] Old repositories are tagged for decommissioning (Strategy 2)
- [ ] Documentation updated with new repository names
- [ ] Monitoring and alerting configured for new repositories
- [ ] Backup of old repository configurations saved

## Rollback Procedures

### Strategy 1 (In-Place Update)

```bash
# Restore previous settings from backup
aws ecr put-image-tag-mutability \
  --repository-name "$REPO_NAME" \
  --image-tag-mutability MUTABLE

# Remove lifecycle policy
aws ecr delete-lifecycle-policy \
  --repository-name "$REPO_NAME"
```

### Strategy 2 (Blue-Green Migration)

```bash
# Revert application configurations
kubectl get deployments -A -o yaml | \
  sed "s|$NEW_REPO|$OLD_REPO|g" | \
  kubectl apply -f -

# Keep old repositories until validation complete
```

### Strategy 3 (Terraform Import)

```bash
# Revert Terraform changes
terraform apply -target=aws_ecr_repository.my_app \
  -var="image_tag_mutability=MUTABLE"
```

## Common Issues and Solutions

### Issue: AWS KMS Encryption Cannot Be Changed

**Symptom:**
```
Error: Cannot change encryption configuration after repository creation
```

**Solution:**
Use Strategy 2 (Blue-Green Migration) to create new repository with AWS KMS encryption.

### Issue: Images Too Large to Copy

**Symptom:**
```
Error: Image size exceeds 10GB
```

**Solution:**
- Use `docker buildx imagetools create` for efficient copying
- Copy manifest lists instead of individual images
- Use AWS DataSync for very large images

### Issue: Application Downtime During Migration

**Symptom:**
Pods failing to pull images during migration

**Solution:**
- Use blue-green deployment strategy
- Keep old repositories active during transition
- Update deployments gradually (canary or rolling update)

## Best Practices

1. **Test First:** Always test migration process with non-production repositories
2. **Backup:** Save current repository configurations before making changes
3. **Validate:** Verify each step before proceeding
4. **Document:** Keep detailed records of migration process
5. **Monitor:** Set up alerts for migration failures
6. **Gradual:** Migrate repositories in batches, not all at once
7. **Rollback Plan:** Have procedures ready for issues
8. **Communication:** Notify teams before migrating their repositories

## Next Steps

- Review [ARCHITECTURE.md](ARCHITECTURE.md) for infrastructure details
- See [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) for new repository setup
- Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues
- Refer to [SCALING-GUIDE.md](SCALING-GUIDE.md) for large-scale migrations
