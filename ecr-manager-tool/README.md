# Scripts

This directory contains the Artifact Migration Tool and related scripts for migrating Helm charts and container images to Amazon ECR.

## Main Scripts

### ecr-artifact-manager.sh

Production-grade automation tool (4,200+ lines) for managing Helm charts and standalone container images in Amazon ECR.

**Features:**
- Helm charts with automatic image extraction
- Standalone container images (direct processing)
- Multi-architecture image support with platform preservation
- Terraform configuration auto-sync
- Flexible team-specific naming conventions
- Comprehensive error handling and retry logic
- Batch processing via YAML configuration
- Automatic dependency resolution
- Detailed categorized logging and performance metrics
- Sequential processing (skips already-migrated items by default)

**Usage:**

```bash
# Configuration file mode with charts and standalone images (recommended)
./ecr-artifact-manager.sh --config charts-config.yaml --region us-east-1

# Single Helm chart
./ecr-artifact-manager.sh \
  --name ingress-nginx \
  --repository https://kubernetes.github.io/ingress-nginx \
  --chart ingress-nginx/ingress-nginx \
  --version 4.9.0 \
  --region us-east-1

# Single standalone image
./ecr-artifact-manager.sh \
  --image docker.io/library/nginx:1.25.0 \
  --region us-east-1

# Multiple images from file
./ecr-artifact-manager.sh \
  --image-file images.txt \
  --region us-east-1

# Custom naming for team
./ecr-artifact-manager.sh \
  --config charts-config.yaml \
  --resource-prefix "p-usw2-myteam-" \
  --helm-suffix "charts" \
  --image-suffix "images" \
  --region us-east-1

# Force re-migration of existing items
./ecr-artifact-manager.sh --config charts-config.yaml --force

# Skip image processing (charts only)
./ecr-artifact-manager.sh --config charts-config.yaml --no-images

# Clean up downloaded files after success
./ecr-artifact-manager.sh --config charts-config.yaml --cleanup
```

**Command-Line Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `-c, --config FILE` | YAML configuration file (charts + images) | charts-config.yaml |
| `--image IMAGE:TAG` | Process single standalone image | - |
| `--image-file FILE` | Process multiple images from file | - |
| `--terraform-dir DIR` | Load naming from Terraform directory | Auto-detect |
| `--resource-prefix STR` | Resource prefix: {env}-{region}-{org}-{project}- | d-use1-myorg-eks- |
| `--helm-suffix STR` | Suffix for Helm chart repos | helmchart |
| `--image-suffix STR` | Suffix for image repos | helmimages |
| `-r, --region STRING` | AWS region | Current region |
| `-a, --account STRING` | AWS account ID | Current account |
| `--profile STRING` | AWS profile | Default profile |
| `-n, --no-create-repos` | Skip auto repository creation | false |
| `--no-images` | Skip image processing | false |
| `--cleanup` | Clean up files after success | false |
| `--force` | Force update existing items | false |
| `-h, --help` | Show help message | - |

### validate-deployment.sh

Validation script to verify successful deployment of ECR infrastructure and migrated artifacts.

**Usage:**

```bash
./validate-deployment.sh --region us-east-1
```

## Configuration Files

### charts-config.yaml.example

Example configuration file for batch processing multiple Helm charts.

**Format:**

```yaml
# Helm charts section (optional)
charts:
  - name: chart-name
    repository: https://helm-repo-url
    chart: repo-name/chart-name
    version: x.y.z

# Standalone images section (optional)
standalone_images:
  - docker.io/library/nginx:1.25.0
  - docker.io/library/alpine:3.18
```

**Usage:**

```bash
# Copy example to create your configuration
cp charts-config.yaml.example charts-config.yaml

# Edit with your charts
vim charts-config.yaml

# Run migration
./ecr-artifact-manager.sh --config charts-config.yaml
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `LOG_LEVEL` | Logging level (DEBUG, INFO, WARNING, ERROR) | INFO |
| `ENABLE_TIMING_LOGS` | Enable timing logs | true |
| `AWS_PROFILE` | AWS profile to use | default |

## Examples

### Migrate Single Chart

```bash
./ecr-artifact-manager.sh \
  --name aws-load-balancer-controller \
  --repository https://aws.github.io/eks-charts \
  --chart eks/aws-load-balancer-controller \
  --version 1.7.1 \
  --region us-east-1
```

### Migrate Multiple Charts

```bash
# Create configuration
cat > my-charts.yaml << EOF
charts:
  - name: external-secrets
    repository: https://charts.external-secrets.io
    chart: external-secrets/external-secrets
    version: 0.9.11
  - name: metrics-server
    repository: https://kubernetes-sigs.github.io/metrics-server
    chart: metrics-server/metrics-server
    version: 3.12.0
EOF

# Run migration
./ecr-artifact-manager.sh --config my-charts.yaml --region us-east-1
```

### Debug Mode

```bash
# Enable debug logging
LOG_LEVEL=DEBUG ./ecr-artifact-manager.sh --config charts-config.yaml

# Or use bash debug mode
bash -x ./ecr-artifact-manager.sh --config charts-config.yaml
```

## Troubleshooting

### Common Issues

1. **Docker Hub Rate Limiting**
   - Solution: Login to Docker Hub before running
   ```bash
   docker login
   ```

2. **Multi-Architecture Images Not Preserved**
   - Verify Docker BuildKit is enabled
   ```bash
   docker buildx version
   ```

3. **Script Fails Mid-Migration**
   - Simply restart - tool automatically skips already-migrated items
   ```bash
   ./ecr-artifact-manager.sh --config charts-config.yaml
   ```

See [../docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) for comprehensive troubleshooting guide.

## Performance Tips

- Run from EC2 instance in same region as ECR for best performance
- Use authenticated Docker Hub access to avoid rate limits
- For large migrations (100+ charts), split into batches
- Run multiple script instances in parallel for independent batches

## Security Notes

- Never commit credentials or sensitive data
- Sanitize logs before sharing
- Use IAM roles instead of access keys when possible
- Review and validate all migrated artifacts before production use

## License

MIT-0 - See [../LICENSE](../LICENSE)
