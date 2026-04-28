## Troubleshooting

### Issue 1: CREATE_ON_PUSH Not Working

**Symptoms:**
- Repository not created automatically when pushing image
- Error: "repository does not exist"
- Push fails with 404 error

**Possible Causes:**
- Repository Creation Templates not deployed
- Template prefix doesn't match repository name
- IAM permissions missing
- Region doesn't support CREATE_ON_PUSH

**Solutions:**
1. Verify templates exist:
   ```bash
   aws ecr describe-repository-creation-templates --region us-east-1
   ```

2. Check template prefix matches repository name:
   - Template prefix: `helmchart/`
   - Repository name must start with: `helmchart/`

3. Verify IAM service role has permissions:
   ```bash
   aws iam get-role --role-name ECRRepositoryCreationRole
   ```

4. Fallback: Create repository manually:
   ```bash
   aws ecr create-repository \
     --repository-name helmchart/my-chart \
     --encryption-configuration encryptionType=KMS,kmsKey=<key-arn> \
     --image-tag-mutability IMMUTABLE
   ```

---

### Issue 2: Docker Hub Rate Limiting

**Symptoms:**
- Error: "toomanyrequests: You have reached your pull rate limit"
- Image pull fails after multiple attempts
- Migration slows down significantly

**Possible Causes:**
- Anonymous Docker Hub access (100 pulls/6 hours limit)
- Multiple migrations running simultaneously
- Shared IP address with other users

**Solutions:**
1. Use authenticated Docker Hub access:
   ```bash
   docker login
   # Enter Docker Hub credentials
   ```

2. Use alternative registries:
   - Try Quay.io, ghcr.io, or gcr.io as fallback
   - Configure multiple registry mirrors

3. Implement retry logic with delays:
   - Artifact Migration Tool has built-in retry logic
   - Increase RETRY_DELAY if hitting limits frequently

4. Spread migration over time:
   - Process charts in smaller batches
   - Add delays between batches

---

### Issue 3: Multi-Architecture Images Not Preserved

**Symptoms:**
- Only one platform available after migration (e.g., only amd64)
- Deployment fails on ARM nodes
- `docker manifest inspect` shows single platform

**Possible Causes:**
- Docker BuildKit not enabled
- Using `docker pull/push` instead of `buildx imagetools`
- Source image is single-architecture

**Solutions:**
1. Verify Docker BuildKit is enabled:
   ```bash
   docker buildx version
   ```

2. Check source image has multiple platforms:
   ```bash
   docker manifest inspect docker.io/nginx:latest
   ```

3. Use correct migration command:
   ```bash
   # Correct (preserves all platforms)
   docker buildx imagetools create \
     --tag <ecr-url>/nginx:latest \
     docker.io/nginx:latest
   
   # Incorrect (only copies current platform)
   docker pull docker.io/nginx:latest
   docker tag docker.io/nginx:latest <ecr-url>/nginx:latest
   docker push <ecr-url>/nginx:latest
   ```

4. Verify all platforms after migration:
   ```bash
   docker manifest inspect <ecr-url>/nginx:latest
   ```

---

### Issue 4: AWS KMS Encryption Errors

**Symptoms:**
- Error: "AWS KMS key not found"
- Error: "Access denied to AWS KMS key"
- Repository created but not encrypted with AWS KMS

**Possible Causes:**
- AWS KMS key doesn't exist in region
- IAM service role lacks AWS KMS permissions
- Key policy doesn't allow ECR service

**Solutions:**
1. Verify AWS KMS key exists:
   ```bash
   aws kms describe-key --key-id <key-arn>
   ```

2. Check key policy allows ECR:
   ```bash
   aws kms get-key-policy --key-id <key-arn> --policy-name default
   ```

3. Update key policy to allow ECR service:
   ```json
   {
     "Sid": "Allow ECR to use the key",
     "Effect": "Allow",
     "Principal": {
       "Service": "ecr.amazonaws.com"
     },
     "Action": [
       "kms:Decrypt",
       "kms:Encrypt",
       "kms:GenerateDataKey"
     ],
     "Resource": "*"
   }
   ```

4. Verify IAM service role has AWS KMS permissions:
   ```bash
   aws iam list-attached-role-policies \
     --role-name ECRRepositoryCreationRole
   ```

---

### Issue 5: Helm Chart Push Fails

**Symptoms:**
- Error: "failed to push chart"
- Error: "unauthorized: authentication required"
- Chart push times out

**Possible Causes:**
- Not logged into ECR
- ECR authentication token expired
- Repository doesn't exist
- Network connectivity issues

**Solutions:**
1. Re-authenticate to ECR:
   ```bash
   aws ecr get-login-password --region us-east-1 | \
     docker login --username AWS --password-stdin \
     <account-id>.dkr.ecr.us-east-1.amazonaws.com
   ```

2. Verify repository exists:
   ```bash
   aws ecr describe-repositories \
     --repository-names helmchart/my-chart
   ```

3. Check Helm OCI support:
   ```bash
   helm version  # Should be 3.8.0 or later for best OCI support
   ```

4. Test with verbose output:
   ```bash
   helm push my-chart-1.0.0.tgz oci://<ecr-url> --debug
   ```

---

### Issue 6: Template Settings Not Applied

**Symptoms:**
- Repository created but using AES256 encryption instead of AWS KMS
- Tags are mutable instead of immutable
- Lifecycle policy not applied

**Possible Causes:**
- Repository created manually before template deployment
- Template prefix doesn't match
- Template configuration error

**Solutions:**
1. Verify repository was created via CREATE_ON_PUSH:
   ```bash
   aws ecr describe-repositories \
     --repository-names helmchart/my-chart \
     --query 'repositories[0].createdAt'
   ```

2. Check template configuration:
   ```bash
   aws ecr describe-repository-creation-templates \
     --region us-east-1
   ```

3. Delete and recreate repository:
   ```bash
   # Delete repository
   aws ecr delete-repository \
     --repository-name helmchart/my-chart \
     --force
   
   # Push again to trigger CREATE_ON_PUSH
   docker push <ecr-url>/helmchart/my-chart:latest
   ```

4. Manually apply settings if recreation not possible:
   ```bash
   # Update tag mutability
   aws ecr put-image-tag-mutability \
     --repository-name helmchart/my-chart \
     --image-tag-mutability IMMUTABLE
   
   # Apply lifecycle policy
   aws ecr put-lifecycle-policy \
     --repository-name helmchart/my-chart \
     --lifecycle-policy-text file://lifecycle-policy.json
   ```

---

### Issue 7: Artifact Migration Tool Fails

**Symptoms:**
- Script exits with error
- Partial migration completed
- Error messages in logs

**Possible Causes:**
- Missing dependencies (jq, yq, helm, docker)
- Network connectivity issues
- Invalid configuration file
- Insufficient disk space

**Solutions:**
1. Verify all dependencies installed:
   ```bash
   which jq yq helm docker aws
   jq --version
   yq --version
   helm version
   docker version
   aws --version
   ```

2. Check disk space:
   ```bash
   df -h
   # Need at least 10GB free for large migrations
   ```

3. Validate configuration file:
   ```bash
   yq eval charts-config.yaml
   ```

4. Run with verbose logging:
   ```bash
   bash -x ecr-artifact-manager.sh --config charts-config.yaml
   ```

5. Simply restart the tool - it automatically skips already-migrated items:
   ```bash
   ./ecr-artifact-manager.sh --config charts-config.yaml
   ```
   
   The tool will skip items already in ECR and continue with remaining items. Use --force flag only if you need to re-migrate existing items.

---

### Issue 8: AWS API Throttling

**Symptoms:**
- Error: "Rate exceeded"
- Error: "ThrottlingException"
- Migration slows down significantly

**Possible Causes:**
- Too many concurrent operations
- Exceeding API rate limits
- Multiple users/processes using same account

**Solutions:**
1. Reduce processing load:
   ```bash
   # Process smaller batches
   # Split charts-config.yaml into smaller files
   # Run one batch at a time
   ```

2. Implement delays between charts:
   - Tool has built-in retry logic with exponential backoff
   - For additional control, process charts in smaller batches

3. Spread operations over time:
   ```bash
   # Process batch 1
   ./ecr-artifact-manager.sh --config batch1.yaml
   
   # Wait between batches
   sleep 300  # Wait 5 minutes
   
   # Process batch 2
   ./ecr-artifact-manager.sh --config batch2.yaml
   ```

4. Request quota increase:
   - Navigate to AWS Service Quotas console
   - Request increase for ECR API operations

---

### Issue 9: EKS Deployment Fails After Migration

**Symptoms:**
- Pods stuck in ImagePullBackOff
- Error: "failed to pull image"
- Error: "unauthorized: authentication required"

**Possible Causes:**
- EKS nodes can't reach ECR
- IAM role lacks ECR permissions
- VPC endpoints not configured (air-gapped)
- Image reference incorrect

**Solutions:**
1. Verify VPC endpoints exist (air-gapped):
   ```bash
   aws ec2 describe-vpc-endpoints \
     --filters "Name=service-name,Values=com.amazonaws.us-east-1.ecr.api" \
     --query 'VpcEndpoints[*].[VpcEndpointId,State]'
   ```

2. Check node IAM role has ECR permissions:
   ```bash
   aws iam get-role-policy \
     --role-name <node-role-name> \
     --policy-name ECRReadOnly
   ```

3. Verify image reference in deployment:
   ```yaml
   # Should be full ECR URL
   image: <account-id>.dkr.ecr.us-east-1.amazonaws.com/helmchart/my-app:v1.0.0
   ```

4. Test image pull from node:
   ```bash
   # SSH to node
   docker pull <ecr-url>/helmchart/my-app:v1.0.0
   ```

---

### Issue 10: Scanning Failures

**Symptoms:**
- Images not scanned after push
- Scanning status shows "FAILED"
- No vulnerability findings

**Possible Causes:**
- Enhanced scanning not enabled
- Image too large (>10GB limit)
- Unsupported image format
- Scanning service issues

**Solutions:**
1. Verify enhanced scanning enabled:
   ```bash
   aws ecr get-registry-scanning-configuration
   ```

2. Check image size:
   ```bash
   aws ecr describe-images \
     --repository-name helmchart/my-chart \
     --query 'imageDetails[*].[imageSizeInBytes]'
   ```

3. Manually trigger scan:
   ```bash
   aws ecr start-image-scan \
     --repository-name helmchart/my-chart \
     --image-id imageTag=latest
   ```

4. Check scan findings:
   ```bash
   aws ecr describe-image-scan-findings \
     --repository-name helmchart/my-chart \
     --image-id imageTag=latest
   ```
