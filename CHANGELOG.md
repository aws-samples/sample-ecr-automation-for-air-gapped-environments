# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-01-30

### Added
- Initial release of ECR Automation for Air-Gapped Environments
- Terraform module for ECR Repository Creation Templates
- Artifact Migration Tool (5,000+ lines) for Helm charts and container images
- Multi-architecture image support with platform preservation
- Comprehensive error handling and retry logic
- Support for air-gapped deployments
- Customer-managed AWS KMS encryption
- Immutable tag enforcement
- Enhanced vulnerability scanning
- Lifecycle policy automation
- Documentation suite:
  - Architecture overview
  - Deployment guide
  - Security best practices
  - Troubleshooting guide
  - Cost analysis
  - Scaling guide
- Examples for single-chart, batch processing, and multi-region deployments
- Validation scripts for deployment verification

### Features
- Zero-touch repository creation via CREATE_ON_PUSH
- Automatic dependency resolution for Helm charts
- Multi-tier image inspection with fallback mechanisms
- Exponential backoff retry for network failures
- Detailed logging with performance metrics
- Batch processing via YAML configuration
- Support for 50+ Helm charts and 100+ container images
- Compliance with SOC 2, PCI-DSS, HIPAA, NIST 800-53

### Security
- Customer-managed AWS KMS keys with automatic rotation
- Immutable image tags
- Enhanced vulnerability scanning (SCAN_ON_PUSH + CONTINUOUS_SCAN)
- CloudTrail audit logging
- Least privilege IAM roles
- VPC endpoint support for air-gapped environments

[1.0.0]: https://github.com/aws-samples/ecr-automation-air-gapped/releases/tag/v1.0.0
