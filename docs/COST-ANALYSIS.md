# Cost Analysis

This document provides detailed cost analysis and optimization strategies for the ECR Automation pattern.

## Table of Contents

- [Cost Components](#cost-components)
- [Cost Breakdown by Deployment Size](#cost-breakdown-by-deployment-size)
- [ROI Analysis](#roi-analysis)
- [Cost Optimization Strategies](#cost-optimization-strategies)
- [Cost Monitoring](#cost-monitoring)

## Cost Components

### AWS Service Costs

#### 1. Amazon ECR Storage

**Pricing:** $0.10 per GB-month

**Calculation:**
```
Monthly Cost = Storage (GB) × $0.10
```

**Example:**
- 100 GB storage = $10/month
- 500 GB storage = $50/month
- 1 TB storage = $100/month

#### 2. AWS KMS

**Pricing:**
- Customer-managed key: $1.00/month per key
- API requests: $0.03 per 10,000 requests

**Typical Usage:**
- 1 AWS KMS key per region: $1.00/month
- API requests (encrypt/decrypt): ~$0.50/month for 100 repositories

**Total AWS KMS Cost:** ~$1.50/month per region

#### 3. Data Transfer

**Pricing:**
- Data transfer IN: Free
- Data transfer OUT to internet: $0.09 per GB (first 10 TB)
- Data transfer OUT to same region: Free
- Data transfer OUT to other AWS regions: $0.02 per GB

**Typical Usage:**
- Initial migration (download from public registries): One-time cost
- EKS pulls from ECR (same region): Free
- Cross-region replication: $0.02 per GB

#### 4. CloudTrail (Optional)

**Pricing:**
- First trail: Free
- Additional trails: $2.00 per 100,000 events
- S3 storage for logs: $0.023 per GB-month

**Typical Usage:**
- Single trail: Free
- S3 storage (10 GB): $0.23/month

**Total CloudTrail Cost:** ~$0.25/month

#### 5. CloudWatch (Optional)

**Pricing:**
- Metrics: First 10 metrics free, then $0.30 per metric
- Logs: $0.50 per GB ingested
- Alarms: $0.10 per alarm per month

**Typical Usage:**
- ECR metrics (automatic): Free
- Custom alarms (5): $0.50/month

**Total CloudWatch Cost:** ~$0.50/month

### One-Time Migration Costs

#### 1. EC2 Instance (Optional)

**Pricing:** Varies by instance type

**Recommended Instances:**
- Small migration (1-20 repos): t3.medium ($0.0416/hour)
- Medium migration (20-100 repos): t3.large ($0.0832/hour)
- Large migration (100-500 repos): c5n.4xlarge ($0.864/hour)

**Example Costs:**
- 2-hour migration on t3.large: $0.17
- 8-hour migration on c5n.4xlarge: $6.91

#### 2. Data Transfer (Initial Migration)

**Pricing:** $0.09 per GB for downloads from internet

**Example Costs:**
- 50 GB of images: $4.50
- 200 GB of images: $18.00
- 1 TB of images: $90.00

## Cost Breakdown by Deployment Size

### Small Deployment (1-20 repositories)

**Infrastructure:**
- ECR Storage (50 GB): $5.00/month
- AWS KMS Key: $1.00/month
- Data Transfer (minimal): $1.00/month
- CloudTrail: $0.25/month
- CloudWatch: $0.50/month
- **Total Monthly: $7.75/month**

**One-Time Migration:**
- EC2 Instance (t3.medium, 2 hours): $0.08
- Data Transfer (50 GB): $4.50
- **Total Migration: $4.58**

**Annual Cost:** $93 + $4.58 = **$97.58**

### Medium Deployment (20-100 repositories)

**Infrastructure:**
- ECR Storage (500 GB): $50.00/month
- AWS KMS Key: $1.00/month
- Data Transfer (minimal): $5.00/month
- CloudTrail: $0.25/month
- CloudWatch: $0.50/month
- **Total Monthly: $56.75/month**

**One-Time Migration:**
- EC2 Instance (t3.large, 4 hours): $0.33
- Data Transfer (200 GB): $18.00
- **Total Migration: $18.33**

**Annual Cost:** $681 + $18.33 = **$699.33**

### Large Deployment (100-500 repositories)

**Infrastructure:**
- ECR Storage (2 TB): $200.00/month
- AWS KMS Key: $1.00/month
- Data Transfer (moderate): $10.00/month
- CloudTrail: $0.25/month
- CloudWatch: $0.50/month
- **Total Monthly: $211.75/month**

**One-Time Migration:**
- EC2 Instance (c5n.4xlarge, 8 hours): $6.91
- Data Transfer (1 TB): $90.00
- **Total Migration: $96.91**

**Annual Cost:** $2,541 + $96.91 = **$2,637.91**

### Enterprise Deployment (500+ repositories)

**Infrastructure:**
- ECR Storage (5 TB): $500.00/month
- AWS KMS Key: $1.00/month
- Data Transfer (high): $20.00/month
- CloudTrail: $0.25/month
- CloudWatch: $0.50/month
- **Total Monthly: $521.75/month**

**One-Time Migration:**
- EC2 Instance (c5n.4xlarge, 24 hours): $20.74
- Data Transfer (3 TB): $270.00
- **Total Migration: $290.74**

**Annual Cost:** $6,261 + $290.74 = **$6,551.74**

## ROI Analysis

### Cost Comparison: Manual vs Automated

#### Manual Repository Management

**Labor Costs (per 50 repositories):**
- Initial setup: 2-3 hours × $100/hour = $250
- Error remediation (15-20% error rate): 1 hour × $100/hour = $100
- Ongoing maintenance: 2 hours/month × $100/hour = $200/month

**Annual Labor Cost:** $250 + $100 + ($200 × 12) = **$2,750**

#### Automated Pattern (This Solution)

**Infrastructure Cost (per 50 repositories):**
- Monthly: $56.75
- Annual: $681

**Labor Costs:**
- Initial setup: 0.5 hours × $100/hour = $50
- Error remediation (<1% error rate): 0.1 hours × $100/hour = $10
- Ongoing maintenance: 0.2 hours/month × $100/hour = $20/month

**Annual Labor Cost:** $50 + $10 + ($20 × 12) = **$300**

**Total Annual Cost:** $681 + $300 = **$981**

### Savings Analysis

**Annual Savings:** $2,750 - $981 = **$1,769**

**ROI:** ($1,769 / $981) × 100 = **180%**

**Payback Period:** $981 / ($1,769 / 12) = **6.7 months**

### Additional Benefits (Not Quantified)

- **Reduced Risk:** 100% compliance vs 80-85% with manual process
- **Faster Time to Market:** 90% reduction in setup time
- **Improved Security:** Template-enforced security standards
- **Better Audit Trail:** Complete CloudTrail logging

## Cost Optimization Strategies

### 1. Implement Lifecycle Policies

**Impact:** 20-30% storage cost reduction

**Implementation:**
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

**Savings Example:**
- Before: 500 GB storage = $50/month
- After: 350 GB storage = $35/month
- **Savings: $15/month ($180/year)**

### 2. Optimize Image Sizes

**Impact:** 30-50% storage cost reduction

**Strategies:**
- Use multi-stage Docker builds
- Remove unnecessary files and layers
- Use distroless or Alpine base images
- Compress layers

**Example:**
```dockerfile
# Before: 1.2 GB image
FROM node:18
COPY . .
RUN npm install
CMD ["node", "app.js"]

# After: 400 MB image (67% reduction)
FROM node:18-alpine AS builder
COPY package*.json ./
RUN npm ci --only=production

FROM node:18-alpine
COPY --from=builder /node_modules ./node_modules
COPY app.js ./
CMD ["node", "app.js"]
```

**Savings Example:**
- 100 images × 800 MB reduction = 80 GB saved
- **Savings: $8/month ($96/year)**

### 3. Leverage Layer Deduplication

**Impact:** 10-20% storage cost reduction

**Strategy:**
- Use common base images across applications
- Share layers between related images
- Standardize base image versions

**ECR automatically deduplicates identical layers**

**Savings Example:**
- 500 GB storage with 15% deduplication = 75 GB saved
- **Savings: $7.50/month ($90/year)**

### 4. Use Single Region (When Possible)

**Impact:** Eliminate cross-region data transfer costs

**Consideration:**
- Deploy in region closest to workloads
- Use multi-region only when required for DR

**Savings Example:**
- Avoid 100 GB/month cross-region transfer
- **Savings: $2/month ($24/year)**

### 5. Clean Up Unused Repositories

**Impact:** Variable, depends on usage

**Strategy:**
- Quarterly review of repository usage
- Delete repositories not accessed in 90+ days
- Archive old images to S3 Glacier

**Savings Example:**
- Remove 20% unused repositories (100 GB)
- **Savings: $10/month ($120/year)**

### 6. Optimize Scanning

**Impact:** Minimal cost, but improves efficiency

**Strategy:**
- Use ENHANCED scanning only for production images
- Use BASIC scanning for development images
- Disable scanning for base images (scan once)

**Note:** Enhanced scanning is included in ECR pricing

### 7. Use Reserved Capacity (For Large Deployments)

**Impact:** Not applicable (ECR doesn't offer reserved capacity)

**Alternative:**
- Use AWS Savings Plans for EC2 instances used in CI/CD
- Commit to 1-year or 3-year terms for 30-50% savings

## Cost Monitoring

### Set Up Cost Alerts

```bash
# Create CloudWatch alarm for ECR costs
aws cloudwatch put-metric-alarm \
  --alarm-name ecr-monthly-cost-alert \
  --alarm-description "Alert when ECR costs exceed $100/month" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 86400 \
  --evaluation-periods 1 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=ServiceName,Value=AmazonECR
```

### Monitor Storage Growth

```bash
# Get total storage across all repositories
aws ecr describe-repositories --region us-east-1 \
  --query 'repositories[*].[repositoryName]' \
  --output text | while read repo; do
    aws ecr describe-images --repository-name "$repo" --region us-east-1 \
      --query 'sum(imageDetails[*].imageSizeInBytes)' --output text
  done | awk '{sum+=$1} END {print "Total Storage: " sum/1024/1024/1024 " GB"}'
```

### Review Cost Explorer

1. Navigate to AWS Cost Explorer
2. Filter by Service: Amazon ECR
3. Group by: Usage Type
4. Time range: Last 3 months
5. Analyze trends and anomalies

### Monthly Cost Review Checklist

- [ ] Review total ECR storage usage
- [ ] Check for unused repositories
- [ ] Verify lifecycle policies are working
- [ ] Review image sizes and optimization opportunities
- [ ] Check data transfer costs
- [ ] Validate AWS KMS key usage
- [ ] Review CloudTrail and CloudWatch costs

## Summary

### Cost Optimization Potential

| Strategy | Savings | Effort |
|----------|---------|--------|
| Lifecycle policies | 20-30% | Low |
| Image optimization | 30-50% | Medium |
| Layer deduplication | 10-20% | Low |
| Single region | Variable | Low |
| Clean up unused repos | Variable | Low |

### Total Potential Savings

For a medium deployment (500 GB storage):
- Baseline cost: $56.75/month
- After optimization: $28-40/month
- **Savings: $17-29/month ($204-348/year)**

### Recommendations

1. **Implement lifecycle policies immediately** - Quick win with minimal effort
2. **Optimize image sizes** - Highest impact, requires development effort
3. **Review quarterly** - Identify unused repositories and optimization opportunities
4. **Monitor continuously** - Set up alerts and review Cost Explorer monthly

## Related Documentation

- [Architecture Overview](ARCHITECTURE.md) - System architecture
- [Deployment Guide](DEPLOYMENT-GUIDE.md) - Deployment instructions
- [Scaling Guide](SCALING-GUIDE.md) - Large-scale deployments
