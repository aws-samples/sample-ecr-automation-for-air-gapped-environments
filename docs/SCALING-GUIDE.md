# Scaling Guide

This guide covers scaling considerations for managing ECR repositories from small deployments to enterprise scale.

## AWS Service Quotas

### Default Limits

| Quota | Default Limit | Adjustable | Impact |
|-------|---------------|------------|--------|
| Repositories per region | 10,000 | Yes | Hard limit on total repositories |
| Images per repository | 10,000 | No | Limit per individual repository |
| Repository Creation Templates per region | 100 | Yes | Limit on template count, not repositories |
| API rate limits | Varies by API | No | Affects bulk operations speed |
| Concurrent image pushes | ~100 | No | Affects parallel migration speed |

### Requesting Quota Increases

1. Navigate to AWS Service Quotas console
2. Select Amazon Elastic Container Registry
3. Request quota increase for:
   - Repositories per region (if >10,000 needed)
   - Repository Creation Templates (if >100 templates needed)
4. Provide justification with use case and expected scale
5. Approval time: Typically 1-3 business days

## Deployment Sizes

### Small Deployments (1-20 repositories)

**Characteristics:**
- Setup time: 15-30 minutes
- Single execution of Artifact Migration Tool
- Default configuration sufficient
- Minimal monitoring required

**Configuration:**
```bash
# Use default settings
MAX_PARALLEL_JOBS=3
BATCH_SIZE=10
```

**Estimated Costs:**
- AWS KMS Key: $1/month
- ECR Storage (100GB): $10/month
- Data Transfer: $5/month
- **Total: $16/month**

### Medium Deployments (20-100 repositories)

**Characteristics:**
- Setup time: 1-3 hours
- Process charts in batches of 20-30
- Use authenticated Docker Hub access
- Basic monitoring recommended

**Configuration:**
```bash
# Optimize for medium scale
MAX_PARALLEL_JOBS=5
BATCH_SIZE=20
MAX_REQUESTS_PER_SECOND=10
```

**Best Practices:**
- Split migration into 3-4 batches
- Use authenticated Docker Hub access (200 pulls/6 hours)
- Monitor API rate limits
- Run during off-peak hours

**Estimated Costs:**
- AWS KMS Key: $1/month
- ECR Storage (300GB): $30/month
- Data Transfer: $15/month
- Scanning: $20/month
- **Total: $66/month**

### Large Deployments (100-500 repositories)

**Characteristics:**
- Setup time: 3-15 hours
- Run multiple script instances in parallel
- Use dedicated EC2 instance with high bandwidth
- Comprehensive monitoring required

**Configuration:**
```bash
# Optimize for large scale
MAX_PARALLEL_JOBS=10
BATCH_SIZE=30
MAX_REQUESTS_PER_SECOND=15
MAX_RETRIES=5
RETRY_DELAY=30
```

**Best Practices:**
- Split into 10-15 batches
- Run multiple tool instances in parallel (different batches)
- Use EC2 t3.xlarge or larger in same region as ECR
- Implement rate limiting and backoff strategies
- Consider multi-day migration window
- Set up CloudWatch dashboards for monitoring

**Infrastructure:**
```bash
# Launch EC2 instance for migration
aws ec2 run-instances \
  --image-id ami-0c55b159cbfafe1f0 \
  --instance-type t3.xlarge \
  --subnet-id subnet-xxxxx \
  --security-group-ids sg-xxxxx \
  --iam-instance-profile Name=ECRMigrationRole \
  --user-data file://migration-userdata.sh
```

**Estimated Costs:**
- AWS KMS Key: $1/month
- ECR Storage (1TB): $100/month
- Data Transfer: $30/month
- Scanning: $100/month
- **Total: $231/month**

### Enterprise Scale (500+ repositories)

**Characteristics:**
- Setup time: 15+ hours (multi-day migration)
- Split into multiple batches
- Run parallel migration instances
- Use EC2 with enhanced networking
- Comprehensive monitoring and alerting
- Request AWS quota increases if needed

**Configuration:**
```bash
# Optimize for enterprise scale
MAX_PARALLEL_JOBS=15
BATCH_SIZE=50
MAX_REQUESTS_PER_SECOND=20
MAX_RETRIES=10
RETRY_DELAY=60
ENABLE_DETAILED_LOGGING=true
```

**Best Practices:**
- Split into 20-30 batches
- Run 5-10 parallel migration instances
- Use EC2 c5n.2xlarge or larger (enhanced networking)
- Implement comprehensive monitoring
- Set up automated alerting
- Plan multi-day migration window
- Have rollback procedures ready
- Coordinate with AWS TAM for support

**Infrastructure:**
```bash
# Launch multiple EC2 instances for parallel migration
for i in {1..5}; do
  aws ec2 run-instances \
    --image-id ami-0c55b159cbfafe1f0 \
    --instance-type c5n.2xlarge \
    --subnet-id subnet-xxxxx \
    --security-group-ids sg-xxxxx \
    --iam-instance-profile Name=ECRMigrationRole \
    --user-data file://migration-userdata-batch-$i.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ecr-migration-$i}]"
done
```

**Estimated Costs:**
- AWS KMS Key: $1/month
- ECR Storage (5TB): $500/month
- Data Transfer: $100/month
- Scanning: $400/month
- **Total: $1,001/month**

## Performance Optimization

### Network Optimization

**Bandwidth Considerations:**
- Typical: 100 Mbps = ~12 MB/s = ~43 GB/hour
- Enhanced: 10 Gbps = ~1.25 GB/s = ~4.5 TB/hour

**Best Practices:**
- Run migration from EC2 instance in same region as ECR
- Use enhanced networking (up to 100 Gbps)
- Minimize network hops
- Use VPC endpoints for ECR (no internet gateway needed)

### Parallel Processing

**Tool Behavior:**
- Single instance processes charts sequentially
- For parallel processing, run multiple tool instances
- Each instance processes independent batches

**Example: Running Multiple Instances**
```bash
# Terminal 1: Process batch 1
./scripts/ecr-artifact-manager.sh \
  --config charts-config-batch1.yaml \
  --log-file migration-batch1.log

# Terminal 2: Process batch 2
./scripts/ecr-artifact-manager.sh \
  --config charts-config-batch2.yaml \
  --log-file migration-batch2.log

# Terminal 3: Process batch 3
./scripts/ecr-artifact-manager.sh \
  --config charts-config-batch3.yaml \
  --log-file migration-batch3.log
```

### Rate Limiting

**Docker Hub Limits:**
- Anonymous: 100 pulls per 6 hours per IP
- Authenticated: 200 pulls per 6 hours
- Pro/Team: Higher limits available

**AWS API Limits:**
- ECR DescribeRepositories: ~20 TPS
- ECR PutImage: ~10 TPS per repository
- AWS KMS Decrypt: ~5,500 TPS (shared across account)

**Mitigation Strategies:**
```bash
# Use authenticated Docker Hub access
docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD

# Implement exponential backoff (built into tool)
MAX_RETRIES=5
RETRY_DELAY=30  # seconds, doubles on each retry

# Spread operations over time
BATCH_DELAY=60  # seconds between batches
```

## Monitoring at Scale

### Progress Tracking

```bash
# Monitor repository count
watch -n 30 'aws ecr describe-repositories \
  --region us-east-1 \
  --query "length(repositories)" \
  --output text'

# Check migration progress
tail -f migration.log | grep "Successfully pushed"

# Count successful migrations
grep -c "Successfully pushed" migration.log
```

### API Throttling Detection

```bash
# Monitor ECR API throttling
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECR \
  --metric-name ThrottledRequests \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum \
  --region us-east-1
```

### Failed Operations

```bash
# Check for failed pushes
aws ecr describe-images \
  --repository-name my-repo \
  --query 'imageDetails[?imagePushedAt==null]' \
  --output table

# Review error logs
grep -i "error\|failed" migration.log
```

## Cost Management at Scale

### Storage Optimization

**Lifecycle Policies:**
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
    },
    {
      "rulePriority": 2,
      "description": "Keep only last 10 images",
      "selection": {
        "tagStatus": "any",
        "countType": "imageCountMoreThan",
        "countNumber": 10
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
```

### Scanning Cost Optimization

**Strategies:**
- Use SCAN_ON_PUSH for production repositories
- Use CONTINUOUS_SCAN only for critical repositories
- Disable scanning for non-production repositories
- Set up filters to scan only specific tags

### Data Transfer Optimization

**Best Practices:**
- Keep ECR and EKS in same region (no cross-region charges)
- Use VPC endpoints (no NAT gateway charges)
- Minimize image layers and sizes
- Use multi-stage builds

## Real-World Example

### Financial Services Customer

**Scale:**
- 87 Helm charts with dependencies
- 200+ container images (multi-architecture)
- Total data: ~500 GB

**Approach:**
- Split into 2 batches (50 charts each)
- Ran 2 parallel instances on t3.xlarge
- Used authenticated Docker Hub access
- Implemented comprehensive monitoring

**Results:**
- Total time: 8 hours
- Success rate: 99.5% (1 chart required manual intervention)
- Cost: $0.50 for EC2, $15 for data transfer
- Ongoing cost: $85/month for ECR storage and scanning

**Lessons Learned:**
- Authenticated Docker Hub access essential
- Parallel processing reduced time by 60%
- Comprehensive logging critical for troubleshooting
- Pre-flight validation caught 3 configuration issues

## Troubleshooting at Scale

### Common Issues

**Issue: API Rate Limiting**
```bash
# Symptom
Error: Rate exceeded for operation: DescribeRepositories

# Solution
# Reduce MAX_REQUESTS_PER_SECOND
MAX_REQUESTS_PER_SECOND=5

# Increase retry delay
RETRY_DELAY=60
```

**Issue: Docker Hub Rate Limits**
```bash
# Symptom
Error: toomanyrequests: You have reached your pull rate limit

# Solution
# Use authenticated access
docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD

# Or wait and retry
sleep 3600  # Wait 1 hour
```

**Issue: Out of Memory**
```bash
# Symptom
Killed (OOM)

# Solution
# Use larger EC2 instance
# Or reduce parallel jobs
MAX_PARALLEL_JOBS=3
```

## Best Practices Summary

1. **Start Small:** Test with 5-10 repositories before full migration
2. **Batch Processing:** Split large migrations into manageable batches
3. **Parallel Execution:** Run multiple instances for independent batches
4. **Monitor Progress:** Set up CloudWatch dashboards and alerts
5. **Rate Limiting:** Respect API limits and implement backoff
6. **Authentication:** Use authenticated access to public registries
7. **Logging:** Enable detailed logging for troubleshooting
8. **Validation:** Verify each batch before proceeding
9. **Rollback Plan:** Have procedures ready for issues
10. **Documentation:** Keep detailed records of migration process

## Next Steps

- Review [ARCHITECTURE.md](ARCHITECTURE.md) for infrastructure details
- See [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) for step-by-step instructions
- Check [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues
- Refer to [COST-ANALYSIS.md](COST-ANALYSIS.md) for cost optimization
