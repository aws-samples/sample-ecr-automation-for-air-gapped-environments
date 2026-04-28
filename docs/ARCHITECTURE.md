# Architecture Overview

> **Note:** Security is a shared responsibility between AWS and the customer. See the [AWS Shared Responsibility Model](https://aws.amazon.com/compliance/shared-responsibility-model/).

This document describes the architecture of the ECR Automation pattern for air-gapped environments.

## Table of Contents

- [Source Technology Stack](#source-technology-stack)
- [Target Technology Stack](#target-technology-stack)
- [Architecture Diagrams](#architecture-diagrams)
- [Component Details](#component-details)
- [Automation and Scale](#automation-and-scale)
- [Monitoring and Observability](#monitoring-and-observability)

## Source Technology Stack

### Source Systems (Pre-Migration)

**Public Container Registries:**
- Docker Hub (docker.io)
- Quay.io (quay.io)
- GitHub Container Registry (ghcr.io)
- Google Container Registry (gcr.io)
- Other OCI-compliant registries

**Artifact Types:**
- Container images (single and multi-architecture)
- Helm charts (with dependencies)
- OCI artifacts

**Network Environment:**
- Internet-connected environment for initial download
- Public registry access via HTTPS

## Target Technology Stack

### Core AWS Services

- **Amazon Elastic Container Registry (ECR):** Private container registry with Repository Creation Templates
- **AWS Key Management Service (AWS KMS):** Customer-managed encryption keys with automatic rotation
- **AWS Identity and Access Management (IAM):** Service roles and policies for ECR operations
- **AWS CloudTrail:** Audit logging for all ECR operations
- **Amazon CloudWatch:** Monitoring and logging

### Infrastructure as Code

- **Terraform:** ECR configuration module with Repository Creation Templates
- **Terraform AWS Provider:** Version 5.0 or later

### Container Runtime

- **Docker:** Image building and pushing (20.10 or later with BuildKit)
- **Helm:** Chart packaging and pushing (3.0 or later)

### Deployment Platform (Optional)

- **Amazon EKS:** Kubernetes cluster for deploying containerized workloads
- **Amazon EKS Auto Mode:** Simplified cluster management
- **AWS VPC:** Network isolation for air-gapped environments

### Security Components

- **Repository Creation Templates:** Automatic repository provisioning with security settings
- **AWS KMS Customer-Managed Keys:** Encryption at rest
- **Immutable Image Tags:** Prevent tag overwrites
- **Lifecycle Policies:** Automatic cleanup of untagged images
- **Enhanced Vulnerability Scanning:** SCAN_ON_PUSH and CONTINUOUS_SCAN modes

## Architecture Diagrams

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     AWS Cloud (Air-Gapped VPC)                  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                  Amazon ECR (Private)                     │  │
│  │                                                           │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │  Repository Creation Templates                      │  │  │
│  │  │  • CREATE_ON_PUSH enabled                          │  │  │
│  │  │  • AWS KMS encryption (customer-managed key)           │  │  │
│  │  │  • IMMUTABLE tags                                  │  │  │
│  │  │  • Lifecycle policies (expire untagged after 2d)   │  │  │
│  │  │  • Enhanced scanning (SCAN_ON_PUSH + CONTINUOUS)   │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  │                                                           │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │  ECR Repositories (Auto-Created)                   │  │  │
│  │  │  • helmchart/external-secrets                      │  │  │
│  │  │  • helmchart/aws-load-balancer-controller          │  │  │
│  │  │  • helmimages/vpc-cni                                │  │  │
│  │  │  • helmimages/kube-proxy                             │  │  │
│  │  │  • ... (50-100+ repositories)                      │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    AWS KMS                                │  │
│  │  • Customer-managed key (multi-region)                   │  │
│  │  • Automatic key rotation enabled                        │  │
│  │  • Key policy for ECR service access                     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                 Amazon EKS Cluster                        │  │
│  │  • Pulls images from private ECR                         │  │
│  │  • Deploys Helm charts from ECR                          │  │
│  │  • No internet connectivity required                     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│              Migration Workflow (One-Time)                      │
│                                                                 │
│  ┌──────────────┐    ┌──────────────────┐    ┌──────────────┐ │
│  │   Public     │───▶│  Artifact        │───▶│   Private    │ │
│  │  Registries  │    │  Migration Tool  │    │     ECR      │ │
│  │              │    │                  │    │              │ │
│  │ • Docker Hub │    │ • Download       │    │ • Auto-      │ │
│  │ • Quay.io    │    │ • Process        │    │   created    │ │
│  │ • ghcr.io    │    │ • Push           │    │ • Secured    │ │
│  └──────────────┘    └──────────────────┘    └──────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Detailed Component Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Terraform Infrastructure                     │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  ECR Configuration Module                                 │  │
│  │                                                           │  │
│  │  1. AWS KMS Key                                              │  │
│  │     ├─ Multi-region replication                         │  │
│  │     ├─ Automatic rotation (365 days)                    │  │
│  │     └─ Key policy (ECR service principal)               │  │
│  │                                                           │  │
│  │  2. IAM Service Role                                     │  │
│  │     ├─ Trust policy (ecr.amazonaws.com)                 │  │
│  │     └─ Permissions (AWS KMS decrypt/encrypt)                │  │
│  │                                                           │  │
│  │  3. Repository Creation Templates                        │  │
│  │     ├─ Helm Charts Template (prefix: helmchart/)        │  │
│  │     │   ├─ AWS KMS encryption                               │  │
│  │     │   ├─ IMMUTABLE tags                               │  │
│  │     │   ├─ Lifecycle policy                             │  │
│  │     │   └─ Enhanced scanning                            │  │
│  │     │                                                    │  │
│  │     └─ EKS Addons Template (prefix: helmimages/)          │  │
│  │         ├─ AWS KMS encryption                               │  │
│  │         ├─ IMMUTABLE tags                               │  │
│  │         ├─ Lifecycle policy                             │  │
│  │         └─ Enhanced scanning                            │  │
│  │                                                           │  │
│  │  4. Registry Scanning Configuration                      │  │
│  │     ├─ ENHANCED scanning mode                           │  │
│  │     ├─ SCAN_ON_PUSH enabled                             │  │
│  │     └─ CONTINUOUS_SCAN enabled                          │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Component Details

### Artifact Migration Tool Workflow

**Step 1: Helm Chart Download**
- Add Helm repository: `helm repo add <repo-name> <repo-url>`
- Update repository index: `helm repo update`
- Pull chart: `helm pull <chart> --version <version>`
- Extract chart and dependencies

**Step 2: Image Extraction**
- Parse values.yaml and Chart.yaml
- Extract image references
- Detect multi-architecture images
- Build image list with platforms

**Step 3: Image Migration**
- Inspect multi-architecture manifests: `docker buildx imagetools inspect`
- Copy all platforms: `docker buildx imagetools create --tag`
- Verify all platforms copied
- Repository auto-created via CREATE_ON_PUSH

**Step 4: Chart Update**
- Update values.yaml with ECR URLs
- Update Chart.yaml dependencies
- Repackage chart

**Step 5: Chart Push**
- Push to ECR: `helm push <chart>.tgz oci://<ecr-url>`
- Repository auto-created via CREATE_ON_PUSH
- Template settings applied automatically

## Automation and Scale

### Automation Capabilities

**Infrastructure Automation (Terraform):**
- Fully automated deployment of ECR infrastructure
- Repository Creation Templates configured via code
- AWS KMS keys with automatic rotation
- IAM roles and policies
- Registry-level scanning configuration
- Multi-region support with single configuration
- Idempotent deployments (safe to re-run)

**Artifact Migration Automation:**
- Batch processing of multiple Helm charts via YAML configuration
- Automatic dependency resolution and processing
- Multi-architecture image detection and preservation
- Sequential processing with comprehensive error handling
- Automatic retry with exponential backoff for network failures
- Detailed logging and audit trail
- Skips already-migrated items when run without --force flag

**Note:** Tool processes charts sequentially. For parallel processing of independent charts, run multiple instances of the tool with different configuration files.

### Scaling Characteristics

| Deployment Size | Repositories | Setup Time | Cost/Month |
|----------------|--------------|------------|------------|
| Small (1-20) | 1-20 | 15-30 min | $16 |
| Medium (20-100) | 20-100 | 1-3 hours | $66 |
| Large (100-500) | 100-500 | 3-15 hours | $131-500 |
| Enterprise (500+) | 500+ | 15+ hours | $500+ |

### Performance Optimization

**Network Optimization:**
- Run migration from EC2 instance in same region as ECR
- Use enhanced networking (up to 100 Gbps)
- Minimize network hops

**Parallel Processing:**
- Tool processes charts sequentially within a single instance
- For parallel processing, run multiple tool instances with different configuration files
- Each instance can process independent batches
- Respect API rate limits across all instances

**Rate Limiting:**
- Built-in exponential backoff for network failures and API throttling
- Use authenticated Docker Hub access (200 pulls/6 hours vs 100)
- Spread operations over time for large migrations

**Restart Capability:**
- By default, tool skips already-migrated images and charts
- Use --force flag to re-migrate existing items
- Safe to interrupt and restart - will continue from where it left off

## Monitoring and Observability

### AWS Service Metrics (Automatic)

- **ECR API metrics:** PutImage, GetAuthorizationToken - automatically available in CloudWatch
- **AWS KMS key usage metrics:** Automatically available in CloudWatch
- These metrics are generated by AWS services, not by the tool

### CloudTrail Logging (Automatic)

- All ECR API calls logged automatically when CloudTrail is enabled
- Repository creation events
- Image push events
- Template application events

### Migration Tool Logging

- Detailed logs with timestamps to stdout/stderr
- Success/failure tracking per artifact
- Error classification and recovery actions
- Performance metrics for operations
- Summary report at completion
- Logs can be redirected to files for analysis

**Note:** The tool provides comprehensive logging to stdout/stderr but does not directly push custom metrics to CloudWatch. AWS service metrics (ECR, AWS KMS) are automatically available in CloudWatch when those services are used.

## Related Documentation

- [Deployment Guide](DEPLOYMENT-GUIDE.md) - Step-by-step deployment instructions
- [Security Best Practices](SECURITY.md) - Security configuration
- [Scaling Guide](SCALING-GUIDE.md) - Large-scale deployments
- [Cost Analysis](COST-ANALYSIS.md) - Cost estimation and optimization
