#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# ECR Artifact Manager - Tool for Amazon Elastic Container Registry (Amazon ECR) Management
#
# This tool manages Helm charts and container images in Amazon ECR for air-gapped environments.
#
# IMPORTANT: This is sample code for demonstration and educational purposes.
# You should work with your security and legal teams to meet your organizational
# security, regulatory, and compliance requirements before deployment.
#
# Security Responsibility:
#   - AWS manages the Amazon ECR service infrastructure security
#   - Customers are responsible for securing credentials, IAM policies, and network access
#   - Credentials are handled via AWS Secrets Manager and passed using --password-stdin
#   - No credentials are logged or stored on disk by this tool
#
# Required IAM Permissions:
#   - ecr:GetAuthorizationToken, ecr:BatchCheckLayerAvailability, ecr:PutImage
#   - ecr:InitiateLayerUpload, ecr:UploadLayerPart, ecr:CompleteLayerUpload
#   - ecr:CreateRepository (if --use-templates is disabled)
#   - ecr:DescribeRepositories, ecr:DescribeImages, ecr:BatchGetImage
#   - ecr:DescribeRepositoryCreationTemplates
#   - secretsmanager:GetSecretValue (only if using source_auth)
#   - sts:GetCallerIdentity
#   - kms:Decrypt, kms:GenerateDataKey (if using AWS KMS encrypted repositories)
#
# Features:
#   - Push Helm charts and extract/push their container images
#   - Push standalone container images directly to Amazon ECR
#   - Multi-architecture image support with automatic detection
#   - Private registry authentication via AWS Secrets Manager
#   - Configurable naming conventions with team-specific suffixes
#   - Repository Creation Templates integration
#   - Comprehensive error handling and retry mechanisms with exponential backoff
#   - Plan mode for dry-run preview of operations

set -euo pipefail

# Color codes for better readability
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Set script defaults - configurable naming pattern with suffixes
# These will be overridden if Terraform configuration is found
DEFAULT_RESOURCE_PREFIX=""
DEFAULT_HELM_SUFFIX="helmchart"
DEFAULT_IMAGE_SUFFIX="eksaddon"
DEFAULT_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
DEFAULT_CONFIG_FILE="charts-config.yaml"

# Function to read Terraform configuration
read_terraform_config() {
  local tf_dir="$1"
  local tfvars_file="${tf_dir}/terraform.tfvars"
  
  # Check if terraform.tfvars exists
  if [[ ! -f "$tfvars_file" ]]; then
    return 1
  fi
  
  # Extract resource prefix
  local tf_prefix=$(grep -E '^ecr_resource_prefix[[:space:]]*=' "$tfvars_file" | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '\n')
  
  # Try to read new format: ecr_repository_templates list
  # Extract all suffix values from the list
  local templates_section=$(awk '/^ecr_repository_templates[[:space:]]*=/, /^\]/' "$tfvars_file")
  
  if [[ -n "$templates_section" ]]; then
    # Parse suffixes from the new format
    local suffixes=($(echo "$templates_section" | grep -E 'suffix[[:space:]]*=' | sed 's/.*suffix[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/'))
    
    if [[ ${#suffixes[@]} -gt 0 ]]; then
      # Use first suffix for helm charts (default behavior)
      DEFAULT_HELM_SUFFIX="${suffixes[0]}"
      
      # Use second suffix for images if available, otherwise use first
      if [[ ${#suffixes[@]} -gt 1 ]]; then
        DEFAULT_IMAGE_SUFFIX="${suffixes[1]}"
      else
        DEFAULT_IMAGE_SUFFIX="${suffixes[0]}"
      fi
      
      # Store all available suffixes for reference
      AVAILABLE_SUFFIXES=("${suffixes[@]}")
      TF_TEMPLATES_FORMAT="new"
    fi
  fi
  
  # Fall back to legacy format if new format not found
  if [[ -z "$TF_TEMPLATES_FORMAT" ]]; then
    local tf_helm_suffix=$(grep -E '^ecr_helm_charts_suffix[[:space:]]*=' "$tfvars_file" | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '\n')
    local tf_image_suffix=$(grep -E '^ecr_eks_addons_suffix[[:space:]]*=' "$tfvars_file" | sed 's/.*=[[:space:]]*"\(.*\)".*/\1/' | tr -d '\n')
    
    if [[ -n "$tf_helm_suffix" ]]; then
      DEFAULT_HELM_SUFFIX="$tf_helm_suffix"
      AVAILABLE_SUFFIXES+=("$tf_helm_suffix")
    fi
    
    if [[ -n "$tf_image_suffix" ]]; then
      DEFAULT_IMAGE_SUFFIX="$tf_image_suffix"
      AVAILABLE_SUFFIXES+=("$tf_image_suffix")
    fi
    
    if [[ -n "$tf_helm_suffix" || -n "$tf_image_suffix" ]]; then
      TF_TEMPLATES_FORMAT="legacy"
    fi
  fi
  
  # Update resource prefix if found
  if [[ -n "$tf_prefix" ]]; then
    DEFAULT_RESOURCE_PREFIX="$tf_prefix"
  fi
  
  # Return success if at least one value was found
  if [[ -n "$tf_prefix" || -n "$TF_TEMPLATES_FORMAT" ]]; then
    return 0
  fi
  
  return 1
}

# Try to auto-detect Terraform configuration
# Look in parent directory (assuming script is in scripts/ subdirectory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Array to store available suffixes from Terraform
declare -a AVAILABLE_SUFFIXES=()
TF_TEMPLATES_FORMAT=""

if read_terraform_config "$TF_ROOT_DIR"; then
  TF_CONFIG_LOADED=true
else
  TF_CONFIG_LOADED=false
fi

# Global variables
RESOURCE_PREFIX="${DEFAULT_RESOURCE_PREFIX}"
HELM_SUFFIX="${DEFAULT_HELM_SUFFIX}"
IMAGE_SUFFIX="${DEFAULT_IMAGE_SUFFIX}"
ECR_PREFIX="${RESOURCE_PREFIX}${HELM_SUFFIX}"
IMAGE_PREFIX="${RESOURCE_PREFIX}${IMAGE_SUFFIX}"
REGION="${DEFAULT_REGION}"
ACCOUNT_ID=""
CREATE_REPOS=true
CLEANUP_FILES=false
FORCE_UPDATE=false
CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
PROCESS_IMAGES=true
USE_CREATION_TEMPLATES=true  # Default to true for Golden EKS TF pattern

# Command line mode variables
CLI_MODE=false
CLI_NAME=""
CLI_REPOSITORY=""
CLI_CHART=""
CLI_VERSION=""

# Standalone image mode variables
STANDALONE_IMAGE_MODE=false
STANDALONE_IMAGE=""
STANDALONE_IMAGE_TAG=""
STANDALONE_IMAGE_FILE=""

# Plan mode - show what would happen without executing
PLAN_MODE=false

# Global arrays for tracking
declare -a PROCESSED_CHARTS=()
declare -a PROCESSED_IMAGES=()
declare -a PROCESSED_STANDALONE_IMAGES=()
declare -a FAILED_CHARTS=()
declare -a FAILED_IMAGES=()
declare -a SKIPPED_AUTH_IMAGES=()  # Track images skipped due to authentication requirements
declare -a CHART_NAMES=()
declare -a CHART_IMAGE_DETAILS=()
declare -a CHART_DEP_DETAILS=()
declare -a PROCESSED_DEPENDENCIES=()  # Add missing array for dependencies
declare -a FAILED_DEPENDENCIES=()     # Add missing array for failed dependencies

# New tracking arrays for accurate classification
declare -a MULTIARCH_IMAGES=()        # Successfully pushed multi-arch images
declare -a SINGLEARCH_IMAGES=()       # Successfully pushed single-arch images
declare -a SKIPPED_IMAGES=()          # Images skipped (auth, inspection failures, etc)
declare -a PARTIAL_SUCCESS_IMAGES=()  # Images with manifests in ECR but untagged

# Enhanced processing statistics tracking
declare -a MULTIARCH_IMAGES_PROCESSED=()
declare -a SINGLEARCH_IMAGES_PROCESSED=()
declare -a FALLBACK_OPERATIONS=()
declare -a AUTHENTICATION_FAILURES=()
declare -a NETWORK_FAILURES=()
declare -a VERIFICATION_RESULTS=()
declare -a OPERATION_TIMINGS=()
declare -a ERROR_CLASSIFICATIONS=()

# Private registry authentication cache (simple string list, bash 3.2 compatible)
AUTHENTICATED_REGISTRIES_LIST=""

# Processing statistics counters
STATS_MULTIARCH_SUCCESS=0
STATS_MULTIARCH_FALLBACK=0
STATS_SINGLEARCH_PROCESSED=0
STATS_AUTH_FAILURES=0
STATS_NETWORK_RETRIES=0
STATS_VERIFICATION_FAILURES=0
STATS_TOTAL_OPERATIONS=0
STATS_TOTAL_ERRORS=0

# Script usage function
usage() {
  cat << EOF
Usage: $0 [OPTIONS] [MODE]

ECR Artifact Manager - Comprehensive tool for managing Helm charts and container images in Amazon ECR.
Supports air-gapped environments with configurable naming conventions and multi-architecture images.

=== MODES ===

1. Configuration File Mode (Helm Charts):
   $0 [OPTIONS]

2. Command Line Mode (Single Helm Chart):
   $0 --name CHART_NAME --repository REPO_URL --chart CHART_PATH --version VERSION [OPTIONS]

3. Standalone Image Mode (Container Images):
   $0 --image IMAGE_NAME:TAG [OPTIONS]
   $0 --image-file IMAGES_FILE [OPTIONS]

=== OPTIONS ===

Configuration:
  -c, --config FILE          YAML configuration file with chart definitions (default: charts-config.yaml)
  
Naming Convention (Golden EKS TF Pattern):
  --terraform-dir DIR        Load naming configuration from Terraform directory (auto-detects parent dir)
  --resource-prefix STRING   Resource prefix: {env}-{region}-{org}-{project}- (default: "${DEFAULT_RESOURCE_PREFIX}")
  --helm-suffix STRING       Suffix for Helm chart repos (default: "${DEFAULT_HELM_SUFFIX}")
  --image-suffix STRING      Suffix for container image repos (default: "${DEFAULT_IMAGE_SUFFIX}")
  
  Legacy Options (deprecated, use above instead):
  -p, --prefix STRING        ECR repository prefix for charts (computed from resource-prefix + helm-suffix)
  --image-prefix STRING      ECR repository prefix for images (computed from resource-prefix + image-suffix)

AWS Configuration:
  -r, --region STRING        AWS region for ECR repositories (default: "${DEFAULT_REGION}")
  -a, --account STRING       AWS account ID (default: current account)
  --profile STRING           AWS profile to use (default: current profile or default)

Repository Management:
  -n, --no-create-repos      Skip automatic repository creation
  --use-templates            Use ECR Repository Creation Templates (default: enabled)
  --no-templates             Disable Repository Creation Templates and use manual creation

Processing Options:
  --no-images                Skip image processing and push only charts (Helm mode only)
  --cleanup                  Clean up downloaded files after successful push
  --force                    Force update charts/images even if they exist
  --plan                     Show what would be processed without pulling or pushing anything
  -h, --help                 Show this help message

=== HELM CHART MODE PARAMETERS ===

  --name STRING              Chart name for ECR repository
  --repository STRING        Helm repository URL
  --chart STRING             Chart path (e.g., repo-name/chart-name)
  --version STRING           Chart version

=== STANDALONE IMAGE MODE PARAMETERS ===

  --image STRING             Single image to push (format: registry/image:tag or image:tag)
  --image-file FILE          File containing list of images (one per line)

=== CONFIGURATION FILE FORMAT (YAML) ===

The configuration file supports both Helm charts and standalone images:

charts:
  - name: chart-name
    repository: https://helm-repo-url
    chart: repo-name/chart-name
    version: x.y.z

standalone_images:
  - docker.io/nginx:1.25.0
  - quay.io/prometheus/prometheus:v2.45.0
  - gcr.io/google-containers/pause:3.9

Both sections are optional. The script will process whatever is present.

=== EXAMPLES ===

# Process both Helm charts and standalone images from config file
$0 --config my-charts.yaml --region us-west-2

# Process Helm chart with custom suffixes
$0 --name ingress-nginx \\
   --repository https://kubernetes.github.io/ingress-nginx \\
   --chart ingress-nginx/ingress-nginx \\
   --version 4.8.3 \\
   --resource-prefix "p-usw2-myteam-app-" \\
   --helm-suffix "charts" \\
   --image-suffix "images"

# Process single standalone image
$0 --image docker.io/nginx:1.25.0 --region us-west-2

# Process multiple standalone images from separate file
$0 --image-file images-list.txt --region us-west-2

=== NAMING PATTERN ===

Golden EKS TF Pattern: {resource-prefix}{suffix}/repository-name

Examples:
  - Helm charts:  d-use1-myorg-eks-helmchart/ingress-nginx
  - Images:       d-use1-myorg-eks-helmimages/nginx
  - Custom:       p-usw2-myteam-app-charts/my-chart

EOF
}

# Enhanced logging system with timing and detailed multi-arch processing logs
SCRIPT_START_TIME=$(date +%s)
CURRENT_OPERATION_START_TIME=""
LOG_LEVEL="${LOG_LEVEL:-INFO}"  # DEBUG, INFO, WARNING, ERROR
ENABLE_TIMING_LOGS="${ENABLE_TIMING_LOGS:-true}"

# Logging functions with enhanced capabilities
log_debug() {
  if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $(get_timestamp) $1" >&2
  fi
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $(get_timestamp) $1" >&2
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $(get_timestamp) $1" >&2
}

log_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $(get_timestamp) $1" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $(get_timestamp) $1" >&2
}

# Multi-arch specific logging functions
log_multiarch_start() {
  local image="$1"
  local operation="$2"
  log_info "🏗️  Multi-arch operation started: $operation for image $image"
  start_operation_timer "$operation"
}

log_multiarch_detection() {
  local image="$1"
  local arch_count="$2"
  local platforms="$3"
  local manifest_type="$4"
  
  log_info "🔍 Architecture detection for $image:"
  log_info "   📊 Architecture count: $arch_count"
  log_info "   🏛️  Platforms detected: $platforms"
  log_info "   📋 Manifest type: $manifest_type"
  
  if [[ $arch_count -gt 1 ]]; then
    log_success "   ✅ Multi-architecture image confirmed ($arch_count architectures)"
  else
    log_info "   ℹ️  Single-architecture image detected"
  fi
}

log_multiarch_decision() {
  local image="$1"
  local decision="$2"
  local reason="$3"
  
  log_info "🤔 Processing decision for $image:"
  log_info "   📝 Decision: $decision"
  log_info "   💭 Reason: $reason"
}

log_multiarch_fallback() {
  local image="$1"
  local original_method="$2"
  local fallback_method="$3"
  local reason="$4"
  
  log_warning "⚠️  Multi-arch fallback triggered for $image:"
  log_warning "   🔄 From: $original_method"
  log_warning "   ➡️  To: $fallback_method"
  log_warning "   💡 Reason: $reason"
}

log_multiarch_verification() {
  local image="$1"
  local expected_platforms="$2"
  local actual_platforms="$3"
  local verification_result="$4"
  
  log_info "🔍 Multi-arch verification for $image:"
  log_info "   🎯 Expected platforms: $expected_platforms"
  log_info "   📊 Actual platforms: $actual_platforms"
  
  if [[ "$verification_result" == "success" ]]; then
    log_success "   ✅ Multi-arch preservation verified"
  else
    log_error "   ❌ Multi-arch preservation failed"
  fi
}

log_processing_step() {
  local step="$1"
  local image="$2"
  local details="$3"
  
  log_debug "🔧 Processing step: $step"
  log_debug "   🖼️  Image: $image"
  [[ -n "$details" ]] && log_debug "   📝 Details: $details"
}

log_authentication_attempt() {
  local image="$1"
  local method="$2"
  local result="$3"
  
  log_info "🔐 Authentication attempt for $image:"
  log_info "   🔑 Method: $method"
  
  if [[ "$result" == "success" ]]; then
    log_success "   ✅ Authentication successful"
  else
    log_warning "   ❌ Authentication failed"
  fi
}

log_network_retry() {
  local operation="$1"
  local attempt="$2"
  local max_attempts="$3"
  local delay="$4"
  
  log_warning "🔄 Network retry for $operation:"
  log_warning "   📊 Attempt: $attempt/$max_attempts"
  [[ -n "$delay" ]] && log_warning "   ⏱️  Retry delay: ${delay}s"
}

log_error_analysis() {
  local image="$1"
  local error_type="$2"
  local error_details="$3"
  local suggested_action="$4"
  
  log_error "🔍 Error analysis for $image:"
  log_error "   🏷️  Error type: $error_type"
  log_error "   📝 Details: $error_details"
  [[ -n "$suggested_action" ]] && log_error "   💡 Suggested action: $suggested_action"
}

# Timing functions
get_timestamp() {
  if [[ "$ENABLE_TIMING_LOGS" == "true" ]]; then
    date '+%H:%M:%S'
  fi
}

start_operation_timer() {
  local operation="$1"
  CURRENT_OPERATION_START_TIME=$(date +%s)
  log_debug "⏱️  Timer started for operation: $operation"
}

end_operation_timer() {
  local operation="$1"
  if [[ -n "$CURRENT_OPERATION_START_TIME" ]]; then
    local end_time=$(date +%s)
    local duration=$((end_time - CURRENT_OPERATION_START_TIME))
    log_info "⏱️  Operation completed: $operation (${duration}s)"
    CURRENT_OPERATION_START_TIME=""
  fi
}

get_script_runtime() {
  local current_time=$(date +%s)
  local runtime=$((current_time - SCRIPT_START_TIME))
  echo "${runtime}s"
}

# Performance tracking
log_performance_metrics() {
  local operation="$1"
  local start_time="$2"
  local end_time="$3"
  local additional_info="$4"
  
  local duration=$((end_time - start_time))
  log_info "📊 Performance metrics for $operation:"
  log_info "   ⏱️  Duration: ${duration}s"
  [[ -n "$additional_info" ]] && log_info "   📝 Additional info: $additional_info"
  
  # Track operation timing for statistics
  OPERATION_TIMINGS+=("$operation:${duration}s:$additional_info")
}

# Processing statistics tracking functions
# Note: Using STATS_VAR=$((STATS_VAR + 1)) instead of ((STATS_VAR++)) throughout
# because ((0++)) returns exit code 1, causing silent termination under set -e
track_multiarch_success() {
  local image="$1"
  local platforms="$2"
  MULTIARCH_IMAGES_PROCESSED+=("$image:$platforms")
  STATS_MULTIARCH_SUCCESS=$((STATS_MULTIARCH_SUCCESS + 1))
  STATS_TOTAL_OPERATIONS=$((STATS_TOTAL_OPERATIONS + 1))
  log_debug "📊 Tracked multi-arch success: $image ($platforms)"
}

track_multiarch_fallback() {
  local image="$1"
  local reason="$2"
  FALLBACK_OPERATIONS+=("$image:$reason")
  STATS_MULTIARCH_FALLBACK=$((STATS_MULTIARCH_FALLBACK + 1))
  STATS_TOTAL_OPERATIONS=$((STATS_TOTAL_OPERATIONS + 1))
  log_debug "📊 Tracked multi-arch fallback: $image ($reason)"
}

track_singlearch_processed() {
  local image="$1"
  local platform="$2"
  SINGLEARCH_IMAGES_PROCESSED+=("$image:$platform")
  STATS_SINGLEARCH_PROCESSED=$((STATS_SINGLEARCH_PROCESSED + 1))
  STATS_TOTAL_OPERATIONS=$((STATS_TOTAL_OPERATIONS + 1))
  log_debug "📊 Tracked single-arch processing: $image ($platform)"
}

track_authentication_failure() {
  local image="$1"
  local error_details="$2"
  AUTHENTICATION_FAILURES+=("$image:$error_details")
  STATS_AUTH_FAILURES=$((STATS_AUTH_FAILURES + 1))
  STATS_TOTAL_ERRORS=$((STATS_TOTAL_ERRORS + 1))
  log_debug "📊 Tracked authentication failure: $image"
}

track_network_retry() {
  local operation="$1"
  local attempt="$2"
  local image="$3"
  STATS_NETWORK_RETRIES=$((STATS_NETWORK_RETRIES + 1))
  log_debug "📊 Tracked network retry: $operation (attempt $attempt) for $image"
}

track_verification_result() {
  local image="$1"
  local result="$2"
  local details="$3"
  VERIFICATION_RESULTS+=("$image:$result:$details")
  if [[ "$result" != "success" ]]; then
    STATS_VERIFICATION_FAILURES=$((STATS_VERIFICATION_FAILURES + 1))
    STATS_TOTAL_ERRORS=$((STATS_TOTAL_ERRORS + 1))
  fi
  log_debug "📊 Tracked verification result: $image ($result)"
}

track_error_classification() {
  local image="$1"
  local error_type="$2"
  local error_details="$3"
  ERROR_CLASSIFICATIONS+=("$image:$error_type:$error_details")
  STATS_TOTAL_ERRORS=$((STATS_TOTAL_ERRORS + 1))
  log_debug "📊 Tracked error classification: $image ($error_type)"
}

# Statistics reporting functions
get_processing_statistics() {
  echo "=== PROCESSING STATISTICS ==="
  echo "Total operations: $STATS_TOTAL_OPERATIONS"
  echo "Multi-arch successes: $STATS_MULTIARCH_SUCCESS"
  echo "Multi-arch fallbacks: $STATS_MULTIARCH_FALLBACK"
  echo "Single-arch processed: $STATS_SINGLEARCH_PROCESSED"
  echo "Authentication failures: $STATS_AUTH_FAILURES"
  echo "Network retries: $STATS_NETWORK_RETRIES"
  echo "Verification failures: $STATS_VERIFICATION_FAILURES"
  echo "Total errors: $STATS_TOTAL_ERRORS"
  
  # Calculate success rates
  if [[ $STATS_TOTAL_OPERATIONS -gt 0 ]]; then
    local success_rate=$(( (STATS_MULTIARCH_SUCCESS + STATS_SINGLEARCH_PROCESSED) * 100 / STATS_TOTAL_OPERATIONS ))
    echo "Overall success rate: ${success_rate}%"
    
    if [[ $STATS_MULTIARCH_SUCCESS -gt 0 || $STATS_MULTIARCH_FALLBACK -gt 0 ]]; then
      local multiarch_attempts=$((STATS_MULTIARCH_SUCCESS + STATS_MULTIARCH_FALLBACK))
      local multiarch_success_rate=$((STATS_MULTIARCH_SUCCESS * 100 / multiarch_attempts))
      echo "Multi-arch success rate: ${multiarch_success_rate}%"
    fi
  fi
}

get_detailed_statistics() {
  echo
  echo "=== DETAILED PROCESSING STATISTICS ==="
  
  # Multi-arch successes
  if [[ ${#MULTIARCH_IMAGES_PROCESSED[@]} -gt 0 ]]; then
    echo
    echo "Multi-arch images successfully processed:"
    for entry in "${MULTIARCH_IMAGES_PROCESSED[@]:-}"; do
      local image=$(echo "$entry" | cut -d: -f1)
      local platforms=$(echo "$entry" | cut -d: -f2-)
      echo "  ✅ $image ($platforms)"
    done
  fi
  
  # Fallback operations
  if [[ ${#FALLBACK_OPERATIONS[@]} -gt 0 ]]; then
    echo
    echo "Multi-arch fallback operations:"
    for entry in "${FALLBACK_OPERATIONS[@]:-}"; do
      local image=$(echo "$entry" | cut -d: -f1)
      local reason=$(echo "$entry" | cut -d: -f2-)
      echo "  🔄 $image (reason: $reason)"
    done
  fi
  
  # Authentication failures
  if [[ ${#AUTHENTICATION_FAILURES[@]} -gt 0 ]]; then
    echo
    echo "Authentication failures:"
    for entry in "${AUTHENTICATION_FAILURES[@]:-}"; do
      local image=$(echo "$entry" | cut -d: -f1)
      local details=$(echo "$entry" | cut -d: -f2-)
      echo "  🔐 $image ($details)"
    done
  fi
  
  # Verification results
  if [[ ${#VERIFICATION_RESULTS[@]} -gt 0 ]]; then
    echo
    echo "Verification results:"
    for entry in "${VERIFICATION_RESULTS[@]:-}"; do
      local image=$(echo "$entry" | cut -d: -f1)
      local result=$(echo "$entry" | cut -d: -f2)
      local details=$(echo "$entry" | cut -d: -f3-)
      if [[ "$result" == "success" ]]; then
        echo "  ✅ $image (verified: $details)"
      else
        echo "  ❌ $image (failed: $details)"
      fi
    done
  fi
  
  # Performance summary
  if [[ ${#OPERATION_TIMINGS[@]} -gt 0 ]]; then
    echo
    echo "Performance summary (slowest operations):"
    printf '%s\n' "${OPERATION_TIMINGS[@]:-}" | \
      sed 's/.*:\([0-9]*\)s:.*/\1 &/' | \
      sort -nr | \
      head -5 | \
      sed 's/^[0-9]* //' | \
      while IFS=: read -r operation duration info; do
        echo "  ⏱️  $operation: $duration ($info)"
      done
  fi
}

reset_statistics() {
  # Reset all statistics arrays and counters
  MULTIARCH_IMAGES_PROCESSED=()
  SINGLEARCH_IMAGES_PROCESSED=()
  FALLBACK_OPERATIONS=()
  AUTHENTICATION_FAILURES=()
  NETWORK_FAILURES=()
  VERIFICATION_RESULTS=()
  OPERATION_TIMINGS=()
  ERROR_CLASSIFICATIONS=()
  
  STATS_MULTIARCH_SUCCESS=0
  STATS_MULTIARCH_FALLBACK=0
  STATS_SINGLEARCH_PROCESSED=0
  STATS_AUTH_FAILURES=0
  STATS_NETWORK_RETRIES=0
  STATS_VERIFICATION_FAILURES=0
  STATS_TOTAL_OPERATIONS=0
  STATS_TOTAL_ERRORS=0
  
  log_debug "📊 Statistics tracking reset"
}

# Enhanced image inspection with multiple fallback methods (Task 1.1)
enhanced_inspect_image() {
  local source_image="$1"
  local inspect_output=""
  local arch_count=0
  local platforms=()
  local manifest_type=""
  
  log_multiarch_start "$source_image" "image_inspection"
  log_processing_step "enhanced_inspection_start" "$source_image" "Starting multi-method inspection"
  
  # Method 1: Try docker buildx imagetools inspect (most reliable for multi-arch)
  if command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
    log_processing_step "buildx_inspection_attempt" "$source_image" "Using docker buildx imagetools inspect"
    
    local method_start_time=$(date +%s)
    if inspect_output=$(docker buildx imagetools inspect "$source_image" 2>/dev/null); then
      local method_end_time=$(date +%s)
      
      arch_count=$(echo "$inspect_output" | grep -c "Platform:" || echo "0")
      manifest_type=$(echo "$inspect_output" | grep "MediaType:" | head -1 | awk '{print $2}')
      arch_count=$(echo "$arch_count" | tr -d '\n' | tr -d '\r' | awk '{print $1}')  # Strip newlines and take first value
      
      # Extract platforms
      while IFS= read -r line; do
        if [[ "$line" =~ Platform:[[:space:]]*(.+) ]]; then
          platforms+=("${BASH_REMATCH[1]}")
        fi
      done <<< "$(echo "$inspect_output" | grep "Platform:")"
      
      log_performance_metrics "buildx_inspection" "$method_start_time" "$method_end_time" "Method 1 - Primary"
      log_processing_step "buildx_inspection_success" "$source_image" "Buildx inspection completed successfully"
      
      # Log detailed detection results
      log_multiarch_detection "$source_image" "$arch_count" "${platforms[*]:-}" "$manifest_type"
      
      end_operation_timer "image_inspection"
      printf '%s\n' "$arch_count" "${platforms[@]:-}" "$manifest_type"
      return 0
    else
      local method_end_time=$(date +%s)
      log_performance_metrics "buildx_inspection_failed" "$method_start_time" "$method_end_time" "Method 1 - Failed"
      log_processing_step "buildx_inspection_failed" "$source_image" "Buildx inspection failed, trying fallback"
    fi
  else
    log_processing_step "buildx_unavailable" "$source_image" "Docker buildx not available, skipping method 1"
  fi
  
  # Method 2: Try docker manifest inspect (alternative method)
  if command -v docker >/dev/null 2>&1; then
    log_processing_step "manifest_inspection_attempt" "$source_image" "Using docker manifest inspect"
    
    local method_start_time=$(date +%s)
    if inspect_output=$(docker manifest inspect "$source_image" 2>/dev/null); then
      local method_end_time=$(date +%s)
      
      # Check if it's a manifest list (multi-arch) or single manifest
      if echo "$inspect_output" | grep -q '"manifests"'; then
        arch_count=$(echo "$inspect_output" | jq -r '.manifests | length' 2>/dev/null || echo "0")
        manifest_type="application/vnd.docker.distribution.manifest.list.v2+json"
        arch_count=$(echo "$arch_count" | tr -d '\n' | tr -d '\r' | awk '{print $1}')  # Strip newlines and take first value
        
        # Extract platforms from manifest list
        if command -v jq >/dev/null 2>&1; then
          while IFS= read -r platform; do
            [[ -n "$platform" && "$platform" != "null" ]] && platforms+=("$platform")
          done <<< "$(echo "$inspect_output" | jq -r '.manifests[]?.platform | "\(.os)/\(.architecture)"' 2>/dev/null)"
        fi
        
        log_performance_metrics "manifest_inspection" "$method_start_time" "$method_end_time" "Method 2 - Multi-arch manifest"
        log_processing_step "manifest_inspection_success" "$source_image" "Multi-arch manifest detected"
        
        # Log detailed detection results
        log_multiarch_detection "$source_image" "$arch_count" "${platforms[*]:-}" "$manifest_type"
        
        end_operation_timer "image_inspection"
        printf '%s\n' "$arch_count" "${platforms[@]:-}" "$manifest_type"
        return 0
      else
        # Single architecture manifest
        arch_count=1
        manifest_type="application/vnd.docker.distribution.manifest.v2+json"
        
        # Try to extract architecture from single manifest
        local arch=$(echo "$inspect_output" | jq -r '.architecture // "amd64"' 2>/dev/null || echo "amd64")
        local os=$(echo "$inspect_output" | jq -r '.os // "linux"' 2>/dev/null || echo "linux")
        platforms+=("$os/$arch")
        
        log_performance_metrics "manifest_inspection" "$method_start_time" "$method_end_time" "Method 2 - Single-arch manifest"
        log_processing_step "manifest_inspection_success" "$source_image" "Single-arch manifest detected: $os/$arch"
        
        # Log detailed detection results
        log_multiarch_detection "$source_image" "$arch_count" "${platforms[*]:-}" "$manifest_type"
        
        end_operation_timer "image_inspection"
        printf '%s\n' "$arch_count" "${platforms[@]:-}" "$manifest_type"
        return 0
      fi
    else
      local method_end_time=$(date +%s)
      log_performance_metrics "manifest_inspection_failed" "$method_start_time" "$method_end_time" "Method 2 - Failed"
      log_processing_step "manifest_inspection_failed" "$source_image" "Manifest inspection failed, trying fallback"
    fi
  fi
  
  # Method 3: Try docker inspect (basic fallback)
  if command -v docker >/dev/null 2>&1; then
    log_processing_step "docker_inspect_attempt" "$source_image" "Using docker inspect (basic fallback)"
    
    local method_start_time=$(date +%s)
    if inspect_output=$(docker inspect "$source_image" 2>/dev/null); then
      local method_end_time=$(date +%s)
      
      arch_count=1
      manifest_type="application/vnd.docker.container.image.v1+json"
      
      # Extract architecture from docker inspect
      local arch=$(echo "$inspect_output" | jq -r '.[0].Architecture // "amd64"' 2>/dev/null || echo "amd64")
      local os=$(echo "$inspect_output" | jq -r '.[0].Os // "linux"' 2>/dev/null || echo "linux")
      platforms+=("$os/$arch")
      
      log_performance_metrics "docker_inspect" "$method_start_time" "$method_end_time" "Method 3 - Basic fallback"
      log_processing_step "docker_inspect_success" "$source_image" "Basic inspection successful: $os/$arch"
      
      # Log detailed detection results
      log_multiarch_detection "$source_image" "$arch_count" "${platforms[*]:-}" "$manifest_type"
      
      end_operation_timer "image_inspection"
      printf '%s\n' "$arch_count" "${platforms[@]:-}" "$manifest_type"
      return 0
    else
      local method_end_time=$(date +%s)
      log_performance_metrics "docker_inspect_failed" "$method_start_time" "$method_end_time" "Method 3 - Failed"
      log_processing_step "docker_inspect_failed" "$source_image" "Basic inspection failed"
    fi
  fi
  
  # All methods failed
  log_error_analysis "$source_image" "INSPECTION_FAILURE" "All inspection methods failed" "Check image availability and Docker daemon status"
  end_operation_timer "image_inspection"
  return 1
}

# Analyze and classify different types of errors for better handling (Task 2.1)
analyze_copy_error() {
  local error_output="$1"
  local source_image="$2"
  
  log_processing_step "error_analysis" "$source_image" "Analyzing error output for classification"
  
  # Convert to lowercase for easier matching
  local error_lower=$(echo "$error_output" | tr '[:upper:]' '[:lower:]')
  
  # Authentication errors
  if [[ "$error_lower" =~ (unauthorized|authentication|denied|forbidden|401|403|login|credential) ]]; then
    log_debug "Error classified as AUTH_ERROR for $source_image"
    echo "AUTH_ERROR"
    return 0
  fi
  
  # Network errors
  if [[ "$error_lower" =~ (timeout|connection.*refused|connection.*reset|network|dns|resolve|unreachable|temporary failure) ]]; then
    log_debug "Error classified as NETWORK_ERROR for $source_image"
    echo "NETWORK_ERROR"
    return 0
  fi
  
  # Image not found errors
  if [[ "$error_lower" =~ (not found|does not exist|no such|404|pull access denied) ]]; then
    log_debug "Error classified as IMAGE_NOT_FOUND for $source_image"
    echo "IMAGE_NOT_FOUND"
    return 0
  fi
  
  # Docker daemon errors
  if [[ "$error_lower" =~ (daemon|docker.*not.*running|cannot connect.*daemon|docker.*socket) ]]; then
    log_debug "Error classified as DAEMON_ERROR for $source_image"
    echo "DAEMON_ERROR"
    return 0
  fi
  
  # Buildx specific errors
  if [[ "$error_lower" =~ (buildx|builder|buildkit) ]]; then
    log_debug "Error classified as BUILDX_ERROR for $source_image"
    echo "BUILDX_ERROR"
    return 0
  fi
  
  # Registry/repository errors
  if [[ "$error_lower" =~ (registry|repository.*not.*found|invalid.*reference) ]]; then
    log_debug "Error classified as REGISTRY_ERROR for $source_image"
    echo "REGISTRY_ERROR"
    return 0
  fi
  
  # Manifest errors
  if [[ "$error_lower" =~ (manifest.*unknown|unsupported.*manifest|invalid.*manifest) ]]; then
    log_debug "Error classified as MANIFEST_ERROR for $source_image"
    echo "MANIFEST_ERROR"
    return 0
  fi
  
  # Rate limiting
  if [[ "$error_lower" =~ (rate.*limit|too many requests|429) ]]; then
    log_debug "Error classified as RATE_LIMIT_ERROR for $source_image"
    echo "RATE_LIMIT_ERROR"
    return 0
  fi
  
  # Unknown error
  log_debug "Error classified as UNKNOWN_ERROR for $source_image"
  echo "UNKNOWN_ERROR"
  return 0
}

# ============================================================================
# PRIVATE REGISTRY AUTHENTICATION (AWS Secrets Manager)
# ============================================================================
# Authenticates against source registries before pulling artifacts.
# Credentials are fetched from AWS Secrets Manager at runtime and cached
# in memory for the session. No credentials are written to disk or logged.
#
# Security Responsibility:
#   - Customers are responsible for managing Secrets Manager access controls
#   - Customers should rotate credentials regularly (ECR tokens expire in 12 hours)
#   - Credentials are passed to Docker/Helm via --password-stdin (not CLI args)
#
# Required IAM Permissions:
#   - secretsmanager:GetSecretValue on the specified secret ARN
#
# Config YAML format:
#   source_auth:
#     secret_name: my-registry/credentials
#     secret_region: eu-west-2          # optional, defaults to script region
#
# Secret JSON format in AWS Secrets Manager:
#   {
#     "registry_url": "harbor.company.com",
#     "username": "robot$ci-user",
#     "password": "xyztoken123"
#   }
#
# For Amazon ECR source registries, the secret would contain:
#   {
#     "registry_url": "123456789.dkr.ecr.eu-west-2.amazonaws.com",
#     "username": "AWS",
#     "password": "<ecr-auth-token>"
#   }
# ============================================================================

# Track which registries we've already authenticated to (avoid repeated logins)
# Note: AUTHENTICATED_REGISTRIES_LIST declared in global variables section above

# Source auth config (populated from YAML)
SOURCE_AUTH_SECRET_NAME=""
SOURCE_AUTH_SECRET_REGION=""

# Cached credentials from Secrets Manager
_SOURCE_AUTH_REGISTRY=""
_SOURCE_AUTH_USERNAME=""
_SOURCE_AUTH_PASSWORD=""
_SOURCE_AUTH_FETCHED=false

# Helper: check if registry is already authenticated
_is_registry_authenticated() {
  local host="$1"
  echo "$AUTHENTICATED_REGISTRIES_LIST" | grep -qF "|${host}|"
}

# Helper: mark registry as authenticated
_mark_registry_authenticated() {
  local host="$1"
  AUTHENTICATED_REGISTRIES_LIST="${AUTHENTICATED_REGISTRIES_LIST}|${host}|"
}

# Fetch credentials from Secrets Manager (cached, only fetched once)
_fetch_source_auth_credentials() {
  if [[ "$_SOURCE_AUTH_FETCHED" == true ]]; then
    return 0
  fi

  if [[ -z "$SOURCE_AUTH_SECRET_NAME" ]]; then
    return 1
  fi

  local secret_region="${SOURCE_AUTH_SECRET_REGION:-$REGION}"
  log_info "   🔑 Fetching credentials from Secrets Manager: $SOURCE_AUTH_SECRET_NAME (region: $secret_region)"

  local secret_value
  if ! secret_value=$(aws secretsmanager get-secret-value \
      --secret-id "$SOURCE_AUTH_SECRET_NAME" \
      --region "$secret_region" \
      --query 'SecretString' \
      --output text 2>/dev/null); then
    log_warning "   ❌ Failed to fetch secret: $SOURCE_AUTH_SECRET_NAME"
    return 1
  fi

  # Parse JSON fields
  _SOURCE_AUTH_REGISTRY=$(echo "$secret_value" | python3 -c "import sys,json; print(json.load(sys.stdin).get('registry_url',''))" 2>/dev/null || echo "")
  _SOURCE_AUTH_USERNAME=$(echo "$secret_value" | python3 -c "import sys,json; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")
  _SOURCE_AUTH_PASSWORD=$(echo "$secret_value" | python3 -c "import sys,json; print(json.load(sys.stdin).get('password',''))" 2>/dev/null || echo "")

  if [[ -z "$_SOURCE_AUTH_REGISTRY" || -z "$_SOURCE_AUTH_USERNAME" || -z "$_SOURCE_AUTH_PASSWORD" ]]; then
    log_warning "   ❌ Secret missing required fields (registry_url, username, password)"
    return 1
  fi

  _SOURCE_AUTH_FETCHED=true
  log_success "   ✅ Credentials fetched for registry: $_SOURCE_AUTH_REGISTRY"
  return 0
}

# Parse source_auth block from config YAML
# Validates config file exists and is readable before parsing
parse_source_auth_config() {
  local config_file="$1"

  if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
    return 0
  fi

  # Parse source_auth section
  local secret_name=""
  local secret_region=""

  secret_name=$(awk '
    BEGIN { in_auth = 0 }
    /^source_auth:/ { in_auth = 1; next }
    /^[a-zA-Z]/ && in_auth { in_auth = 0 }
    in_auth && /secret_name:/ {
      gsub(/^[[:space:]]*secret_name:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
    }
  ' "$config_file")

  secret_region=$(awk '
    BEGIN { in_auth = 0 }
    /^source_auth:/ { in_auth = 1; next }
    /^[a-zA-Z]/ && in_auth { in_auth = 0 }
    in_auth && /secret_region:/ {
      gsub(/^[[:space:]]*secret_region:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
    }
  ' "$config_file")

  if [[ -n "$secret_name" ]]; then
    SOURCE_AUTH_SECRET_NAME="$secret_name"
    SOURCE_AUTH_SECRET_REGION="$secret_region"
    log_info "🔐 Source auth configured: secret=$SOURCE_AUTH_SECRET_NAME, region=${SOURCE_AUTH_SECRET_REGION:-$REGION}"
  fi
}

authenticate_source_registry() {
  local source_ref="$1"  # image ref or OCI URL
  local registry_host=""

  # Extract registry host from image reference or OCI URL
  local clean_ref="$source_ref"
  clean_ref="${clean_ref#oci://}"

  # Extract host (everything before the first /)
  if [[ "$clean_ref" =~ ^([^/]+\.[^/]+)/ ]]; then
    registry_host="${BASH_REMATCH[1]}"
  elif [[ "$clean_ref" =~ ^([^/]+)/ ]] && [[ "${BASH_REMATCH[1]}" == *"."* || "${BASH_REMATCH[1]}" == *":"* ]]; then
    registry_host="${BASH_REMATCH[1]}"
  fi

  # No registry host detected = Docker Hub public, skip auth
  if [[ -z "$registry_host" ]]; then
    log_debug "No private registry detected for: $source_ref"
    return 0
  fi

  # Skip well-known public registries that don't need private auth
  case "$registry_host" in
    docker.io|registry-1.docker.io|registry.hub.docker.com| \
    ghcr.io|public.ecr.aws|registry.k8s.io)
      log_debug "Public registry detected, skipping auth: $registry_host"
      return 0
      ;;
  esac

  # Skip if we already authenticated to this registry in this session
  if _is_registry_authenticated "$registry_host"; then
    log_debug "Already authenticated to: $registry_host (cached)"
    return 0
  fi

  log_info "🔐 Authenticating to source registry: $registry_host"

  # Fetch credentials from Secrets Manager
  if [[ -n "$SOURCE_AUTH_SECRET_NAME" ]]; then
    if _fetch_source_auth_credentials; then
      # Check if the fetched credentials match this registry
      if [[ "$registry_host" == "$_SOURCE_AUTH_REGISTRY" ]]; then
        log_info "   🔑 Method: AWS Secrets Manager ($SOURCE_AUTH_SECRET_NAME)"

        # Docker login
        if echo "$_SOURCE_AUTH_PASSWORD" | docker login "$registry_host" \
            --username "$_SOURCE_AUTH_USERNAME" --password-stdin >/dev/null 2>&1; then
          log_authentication_attempt "$source_ref" "secrets_manager_docker" "success"

          # Also login Helm for OCI chart pulls
          echo "$_SOURCE_AUTH_PASSWORD" | helm registry login "$registry_host" \
            --username "$_SOURCE_AUTH_USERNAME" --password-stdin >/dev/null 2>&1 || true

          _mark_registry_authenticated "$registry_host"
          log_success "   ✅ Authenticated to: $registry_host (via Secrets Manager)"
          return 0
        else
          log_authentication_attempt "$source_ref" "secrets_manager" "failed"
          log_warning "   ❌ Docker login failed with Secrets Manager credentials"
        fi
      else
        # Credentials are for a different registry — allow unauthenticated pull attempt
        log_debug "   Secret registry ($_SOURCE_AUTH_REGISTRY) doesn't match source ($registry_host), allowing unauthenticated pull"
        return 0
      fi
    fi
  fi

  # No source_auth configured at all — allow unauthenticated pull attempt
  # The pull itself will fail if the registry actually requires auth
  log_debug "   No matching credentials for: $registry_host, attempting unauthenticated pull"
  return 0
}

# Handle authentication errors with credential refresh and fallback (Task 2.2)
handle_authentication_error() {
  local source_image="$1"
  local error_details="$2"
  
  log_processing_step "auth_error_handling" "$source_image" "Starting authentication error recovery"
  track_authentication_failure "$source_image" "$error_details"
  
  # Step 1: Try to refresh Docker credentials
  log_processing_step "credential_refresh" "$source_image" "Attempting Docker credential refresh"
  if aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null; then
    log_authentication_attempt "$source_image" "credential_refresh" "success"
    return 0
  else
    log_authentication_attempt "$source_image" "credential_refresh" "failed"
  fi
  
  # Step 2: Try public registry fallback
  log_processing_step "public_fallback" "$source_image" "Attempting public registry fallback"
  if try_public_image_fallback "$source_image"; then
    log_authentication_attempt "$source_image" "public_fallback" "success"
    return 0
  else
    log_authentication_attempt "$source_image" "public_fallback" "failed"
  fi
  
  # Step 3: All authentication recovery methods failed
  log_error_analysis "$source_image" "AUTH_RECOVERY_FAILED" "All authentication recovery methods failed" "Check registry credentials and image availability"
  return 1
}

# Retry mechanism with exponential backoff for network issues (Task 2.3)
retry_with_backoff() {
  local operation="$1"
  local source_image="$2"
  local max_retries="${3:-3}"
  local base_delay="${4:-1}"
  shift 4
  local command=("$@")
  
  log_processing_step "retry_start" "$source_image" "Starting retry operation: $operation (max: $max_retries)"
  
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    log_processing_step "retry_attempt" "$source_image" "Attempt $attempt/$max_retries for $operation"
    track_network_retry "$operation" "$attempt" "$source_image"
    
    local attempt_start_time=$(date +%s)
    if "${command[@]}" 2>/dev/null; then
      local attempt_end_time=$(date +%s)
      log_performance_metrics "retry_success" "$attempt_start_time" "$attempt_end_time" "$operation - Attempt $attempt"
      log_processing_step "retry_success" "$source_image" "$operation succeeded on attempt $attempt"
      return 0
    else
      local attempt_end_time=$(date +%s)
      log_performance_metrics "retry_failed" "$attempt_start_time" "$attempt_end_time" "$operation - Attempt $attempt"
      
      if [[ $attempt -lt $max_retries ]]; then
        local delay=$((base_delay * (2 ** (attempt - 1))))  # Exponential backoff: 1s, 2s, 4s
        log_network_retry "$operation" "$attempt" "$max_retries" "$delay"
        sleep "$delay"
      else
        log_processing_step "retry_exhausted" "$source_image" "$operation failed after $max_retries attempts"
      fi
    fi
  done
  
  log_error_analysis "$source_image" "RETRY_EXHAUSTED" "$operation failed after $max_retries attempts" "Check network connectivity and service availability"
  return 1
}

# Function to try pulling from public registry as fallback (Enhanced for Task 5.2)
try_public_image_fallback() {
  local source_image="$1"
  
  log_processing_step "public_fallback_start" "$source_image" "Starting public registry fallback search"
  
  # Extract image name and tag
  local image_name_tag=$(echo "${source_image}" | sed 's|^[^/]*/||' | sed 's|^[^/]*/||')
  local image_name=$(echo "${image_name_tag}" | cut -d: -f1)
  local tag=$(echo "${image_name_tag}" | cut -d: -f2)
  
  log_processing_step "image_parsing" "$source_image" "Parsed image: name=$image_name, tag=$tag"
  
  # Common public registry mappings with preference ordering
  local public_alternatives=()
  
  case "${source_image}" in
    registry.k8s.io/*)
      public_alternatives+=("k8s.gcr.io/${image_name_tag}")
      public_alternatives+=("docker.io/library/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Kubernetes registry alternatives identified"
      ;;
    ghcr.io/dexidp/*)
      public_alternatives+=("docker.io/dexidp/${image_name}:${tag}")
      public_alternatives+=("quay.io/dexidp/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "DexIDP alternatives identified"
      ;;
    ghcr.io/*)
      public_alternatives+=("docker.io/${image_name}:${tag}")
      public_alternatives+=("quay.io/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "GitHub Container Registry alternatives identified"
      ;;
    *azurecr.io/*)
      public_alternatives+=("docker.io/${image_name}:${tag}")
      public_alternatives+=("ghcr.io/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Azure Container Registry alternatives identified"
      ;;
    istio/*|docker.io/istio/*|gcr.io/istio-release/*)
      public_alternatives+=("gcr.io/istio-release/${image_name}:${tag}")
      public_alternatives+=("docker.io/istio/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Istio registry alternatives identified"
      ;;
    bitnami/*)
      public_alternatives+=("docker.io/bitnami/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Bitnami alternatives identified"
      ;;
    public.ecr.aws/*)
      # Try Docker Hub as alternative for AWS public ECR
      public_alternatives+=("docker.io/${image_name}:${tag}")
      public_alternatives+=("docker.io/amazon/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "AWS Public ECR alternatives identified"
      ;;
    redis:*|docker.io/redis:*|docker.io/library/redis:*)
      # Redis-specific fallback mappings (addresses Redis multi-arch issue)
      public_alternatives+=("docker.io/library/redis:${tag}")
      public_alternatives+=("docker.io/redis:${tag}")
      public_alternatives+=("redis:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Redis-specific alternatives identified"
      ;;
    *)
      public_alternatives+=("docker.io/${image_name_tag}")
      public_alternatives+=("docker.io/library/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Generic Docker Hub alternatives identified"
      ;;
  esac
  
  log_processing_step "fallback_alternatives" "$source_image" "Found ${#public_alternatives[@]} alternative registries to try"
  
  # Try each public alternative with retry logic
  local fallback_start_time=$(date +%s)
  for alt_image in "${public_alternatives[@]:-}"; do
    log_processing_step "fallback_attempt" "$source_image" "Trying alternative: ${alt_image}"
    
    # Use retry mechanism for each fallback attempt
    if retry_with_backoff "fallback_pull" "$source_image" 2 1 docker pull "${alt_image}"; then
      log_authentication_attempt "$source_image" "public_registry_${alt_image}" "success"
      
      # Tag the alternative image with the original name
      if docker tag "${alt_image}" "${source_image}"; then
        log_processing_step "fallback_success" "$source_image" "Successfully tagged alternative as original image"
        local fallback_end_time=$(date +%s)
        log_performance_metrics "total_fallback_operation" "$fallback_start_time" "$fallback_end_time" "Successful fallback to ${alt_image}"
        return 0
      else
        log_processing_step "fallback_tag_failed" "$source_image" "Failed to tag alternative image"
      fi
    else
      log_authentication_attempt "$source_image" "public_registry_${alt_image}" "failed"
    fi
  done
  
  local fallback_end_time=$(date +%s)
  log_performance_metrics "total_fallback_operation_failed" "$fallback_start_time" "$fallback_end_time" "All alternatives failed"
  log_processing_step "fallback_exhausted" "$source_image" "All public registry alternatives failed"
  
  return 1
}

# Helper functions for chart tracking
set_chart_details() {
  local chart_name="$1"
  local image_details="$2"
  local dep_details="$3"
  
  # Find if chart already exists in arrays
  local index=-1
  for i in "${!CHART_NAMES[@]}"; do
    if [[ "${CHART_NAMES[$i]}" == "$chart_name" ]]; then
      index=$i
      break
    fi
  done
  
  if [[ $index -eq -1 ]]; then
    # Add new entry
    CHART_NAMES+=("$chart_name")
    CHART_IMAGE_DETAILS+=("$image_details")
    CHART_DEP_DETAILS+=("$dep_details")
  else
    # Update existing entry
    CHART_IMAGE_DETAILS[$index]="$image_details"
    CHART_DEP_DETAILS[$index]="$dep_details"
  fi
}

get_chart_image_details() {
  local chart_name="$1"
  for i in "${!CHART_NAMES[@]}"; do
    if [[ "${CHART_NAMES[$i]}" == "$chart_name" ]]; then
      echo "${CHART_IMAGE_DETAILS[$i]}"
      return
    fi
  done
  echo ""
}

get_chart_dep_details() {
  local chart_name="$1"
  for i in "${!CHART_NAMES[@]}"; do
    if [[ "${CHART_NAMES[$i]}" == "$chart_name" ]]; then
      echo "${CHART_DEP_DETAILS[$i]}"
      return
    fi
  done
  echo ""
}

# ============================================================================
# NEW HELPER FUNCTIONS FOR TAGGING RECOVERY
# ============================================================================

# Check if a manifest digest is a multi-arch manifest list
is_multiarch_manifest() {
  local ecr_image_with_digest="$1"
  
  local manifest_type=$(docker buildx imagetools inspect "$ecr_image_with_digest" 2>/dev/null | \
    grep "MediaType:" | head -1 | awk '{print $2}')
  
  if [[ "$manifest_type" == *"manifest.list"* ]] || [[ "$manifest_type" == *"image.index"* ]]; then
    return 0  # Is multi-arch
  else
    return 1  # Not multi-arch
  fi
}

# Detect if multi-arch copy partially succeeded (manifests in ECR but untagged)
detect_partial_copy_success() {
  local ecr_repo="$1"
  local expected_tag="$2"
  
  # Check if untagged manifests exist in ECR
  local untagged_manifests=$(aws ecr describe-images \
    --repository-name "$ecr_repo" \
    --region "$REGION" \
    --query "imageDetails[?imageTags==null].imageDigest" \
    --output text 2>/dev/null || echo "")
  
  if [[ -z "$untagged_manifests" ]]; then
    return 1  # No untagged manifests
  fi
  
  # Check if any untagged manifest is a multi-arch manifest list
  for digest in $untagged_manifests; do
    local ecr_image_with_digest="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ecr_repo}@${digest}"
    
    if is_multiarch_manifest "$ecr_image_with_digest"; then
      echo "$digest"  # Return the digest
      return 0
    fi
  done
  
  return 1  # No multi-arch manifest list found
}

# Recover untagged manifest by tagging it
recover_untagged_manifest() {
  local ecr_repo="$1"
  local digest="$2"
  local tag="$3"
  local max_attempts=3
  local attempt=1
  
  log_info "🔄 Attempting to tag untagged manifest: $digest"
  
  while [[ $attempt -le $max_attempts ]]; do
    # First, get the manifest content
    local manifest
    local manifest_error
    manifest=$(aws ecr batch-get-image \
      --repository-name "$ecr_repo" \
      --region "$REGION" \
      --image-ids imageDigest="$digest" \
      --query 'images[0].imageManifest' \
      --output text 2>&1)
    manifest_error=$?
    
    if [[ $manifest_error -ne 0 ]] || [[ -z "$manifest" ]] || [[ "$manifest" == *"error"* ]] || [[ "$manifest" == "None" ]]; then
      log_error "❌ Failed to retrieve manifest on attempt $attempt (exit code: $manifest_error)"
      [[ "$DEBUG" == "true" ]] && log_debug "Manifest output: ${manifest:0:200}"
      
      if [[ $attempt -lt $max_attempts ]]; then
        log_info "   Retrying in 5 seconds..."
        sleep 5
        ((attempt++))
        continue
      else
        return 1
      fi
    fi
    
    # Now put the manifest with the new tag
    local put_output
    local put_error
    put_output=$(aws ecr put-image \
      --repository-name "$ecr_repo" \
      --region "$REGION" \
      --image-tag "$tag" \
      --image-manifest "$manifest" 2>&1)
    put_error=$?
    
    if [[ $put_error -eq 0 ]]; then
      log_success "✅ Successfully tagged manifest: $tag"
      return 0
    else
      log_error "❌ Failed to tag manifest on attempt $attempt (exit code: $put_error)"
      
      # Check if it's an ImageAlreadyExists error (which means success)
      if [[ "$put_output" == *"ImageAlreadyExistsException"* ]]; then
        log_warning "⚠️  Tag already exists, checking if it's the correct multi-arch manifest..."
        
        # Verify the existing tag points to the correct digest
        local existing_digest
        existing_digest=$(aws ecr describe-images \
          --repository-name "$ecr_repo" \
          --region "$REGION" \
          --image-ids imageTag="$tag" \
          --query 'imageDetails[0].imageDigest' \
          --output text 2>&1)
        
        if [[ "$existing_digest" == "$digest" ]]; then
          log_success "✅ Tag already points to the correct multi-arch manifest"
          return 0
        else
          log_error "❌ Tag exists but points to different manifest: $existing_digest"
          return 1
        fi
      fi
      
      [[ "$DEBUG" == "true" ]] && log_debug "Put-image output: ${put_output:0:500}"
      
      if [[ $attempt -lt $max_attempts ]]; then
        log_info "   Retrying in 5 seconds..."
        sleep 5
        ((attempt++))
        continue
      else
        return 1
      fi
    fi
  done
  
  return 1
}

# ============================================================================
# END NEW HELPER FUNCTIONS
# ============================================================================

# Function to create ECR repository name from image
get_ecr_repo_name_for_image() {
  local source_image="$1"
  local image_name
  if [[ "$source_image" =~ ^(.+):(.+)$ ]]; then
    image_name="${BASH_REMATCH[1]}"
  else
    image_name="$source_image"
  fi
  
  # Check if this is already a DESTINATION ECR image (contains our prefix)
  # Only treat as "already in ECR" if it matches our destination prefix pattern
  if [[ "$image_name" =~ ^${ACCOUNT_ID}\.dkr\.ecr\.${REGION}\.amazonaws\.com/(.+)$ ]]; then
    local repo_path="${BASH_REMATCH[1]}"
    # Only return as-is if it's already using our destination prefix
    if [[ "$repo_path" == "${ECR_PREFIX}/"* || "$repo_path" == "${IMAGE_PREFIX}/"* ]]; then
      echo "$repo_path"
      return
    fi
    # Otherwise it's a source ECR image - extract just the image name
  fi
  
  # Extract just the image name (last part after final slash)
  local simple_name
  simple_name=$(basename "$image_name")
  
  echo "${IMAGE_PREFIX}/${simple_name}"
}

# Extract images from amazon-cloudwatch-observability chart using repositoryDomainMap pattern
extract_cloudwatch_observability_images() {
  local values_file="$1"
  local region="$2"
  
  # Parse repositoryDomainMap pattern directly with inline AWK
  awk -v region="$region" '
    BEGIN { 
      in_image_section = 0
      in_repo_domain_map = 0
      in_auto_instr = 0
      in_lang_section = 0
      repository = ""
      tag = ""
      region_domain = ""
      public_domain = ""
      repository_domain = ""
    }
    
    # Track when we are in an image subsection
    /^[[:space:]]*image:[[:space:]]*$/ { 
      in_image_section = 1
      next 
    }
    
    # End of image section
    /^[[:space:]]*[a-zA-Z][^:]*:[[:space:]]*$/ && in_image_section && !/^[[:space:]]*repository:/ && !/^[[:space:]]*tag:/ && !/^[[:space:]]*repositoryDomainMap:/ { 
      # Process accumulated data before moving to next section
      if (repository && tag && (region_domain || public_domain)) {
        domain = (region_domain ? region_domain : public_domain)
        print domain "/" repository ":" tag
      }
      in_image_section = 0
      in_repo_domain_map = 0
      repository = ""
      tag = ""
      region_domain = ""
      public_domain = ""
    }
    
    # Extract repository
    in_image_section && /^[[:space:]]*repository:[[:space:]]*/ {
      gsub(/^[[:space:]]*repository:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      repository = $0
    }
    
    # Extract tag
    in_image_section && /^[[:space:]]*tag:[[:space:]]*/ {
      gsub(/^[[:space:]]*tag:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      tag = $0
    }
    
    # Track repositoryDomainMap section
    in_image_section && /^[[:space:]]*repositoryDomainMap:[[:space:]]*$/ { 
      in_repo_domain_map = 1
      next 
    }
    
    # Extract region-specific domain
    in_repo_domain_map && $0 ~ ("^[[:space:]]*" region ":[[:space:]]*") {
      gsub(/^[[:space:]]*[^:]*:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      region_domain = $0
    }
    
    # Extract public domain as fallback
    in_repo_domain_map && /^[[:space:]]*public:[[:space:]]*/ {
      gsub(/^[[:space:]]*public:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      public_domain = $0
    }
    
    # Track autoInstrumentationImage section
    /^[[:space:]]*autoInstrumentationImage:[[:space:]]*$/ { 
      in_auto_instr = 1
      next 
    }
    
    # Track language sections in autoInstrumentationImage
    in_auto_instr && /^[[:space:]]*(java|python|dotnet|nodejs):[[:space:]]*$/ { 
      # Emit previous language image before starting new one
      if (in_lang_section && repository_domain && repository && tag) {
        print repository_domain "/" repository ":" tag
      }
      # Reset for new language section
      in_lang_section = 1
      repository_domain = ""
      repository = ""
      tag = ""
      next 
    }
    
    # End of autoInstrumentationImage section (when we hit applicationSignals or other top-level key)
    in_auto_instr && /^[[:space:]]*[a-zA-Z][^:]*:[[:space:]]*$/ && !/^[[:space:]]*(java|python|dotnet|nodejs):/ && !/^[[:space:]]*repositoryDomain:/ && !/^[[:space:]]*repository:/ && !/^[[:space:]]*tag:/ { 
      # Emit final language image before exiting autoInstrumentationImage section
      if (in_lang_section && repository_domain && repository && tag) {
        print repository_domain "/" repository ":" tag
      }
      in_auto_instr = 0
      in_lang_section = 0
      repository_domain = ""
      repository = ""
      tag = ""
    }
    
    # Extract repositoryDomain for auto-instrumentation
    in_lang_section && /^[[:space:]]*repositoryDomain:[[:space:]]*/ {
      gsub(/^[[:space:]]*repositoryDomain:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      repository_domain = $0
    }
    
    # Extract repository for auto-instrumentation
    in_lang_section && /^[[:space:]]*repository:[[:space:]]*/ {
      gsub(/^[[:space:]]*repository:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      repository = $0
    }
    
    # Extract tag for auto-instrumentation
    in_lang_section && /^[[:space:]]*tag:[[:space:]]*/ {
      gsub(/^[[:space:]]*tag:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/[[:space:]]*$/, "")
      tag = $0
    }
    
    END {
      # Process final accumulated data
      if (repository && tag && (region_domain || public_domain)) {
        domain = (region_domain ? region_domain : public_domain)
        print domain "/" repository ":" tag
      }
      # Process final auto-instrumentation image
      if (repository_domain && repository && tag) {
        print repository_domain "/" repository ":" tag
      }
    }
  ' "$values_file" | sort -u
}

# Comprehensive registry replacement function
replace_registry_references() {
  local values_file="$1"
  local temp_file="${values_file}.tmp"
  
  # Common registry patterns - easily extensible for new registries
  local -a REGISTRY_PATTERNS=(
    "docker.io"
    "quay.io" 
    "gcr.io"
    "gcr.io/istio-release"
    "gke.gcr.io"
    "ghcr.io"
    "registry.k8s.io"
    "reg.kyverno.io"
    "ecr-public.aws.com"
    "wiziopublic.azurecr.io"
    "public.ecr.aws"
    "oci.external-secrets.io"
  )
  
  # Build sed command dynamically
  local sed_cmd="sed"
  
  # Add defaultRegistry replacements
  for registry in "${REGISTRY_PATTERNS[@]}"; do
    local escaped_registry=$(echo "$registry" | sed 's/\./\\./g')
    sed_cmd+=" -e \"s|defaultRegistry: ${escaped_registry}|defaultRegistry: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com|g\""
    sed_cmd+=" -e \"s|registry: ${escaped_registry}|registry: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com|g\""
  done
  
  # Add repository field patterns
  for registry in "${REGISTRY_PATTERNS[@]}"; do
    local escaped_registry=$(echo "$registry" | sed 's/\./\\./g')
    local ecr_path=$(echo "$registry" | sed 's/\./-/g')
    
    # Standard repository patterns
    sed_cmd+=" -e \"s|repository: ${escaped_registry}/\\([^[:space:]]*\\)|repository: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1|g\""
    sed_cmd+=" -e \"s|repository: \\\"${escaped_registry}/\\([^\\\"]*\\)\\\"|repository: \\\"${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1\\\"|g\""
    
    # Image field patterns
    sed_cmd+=" -e \"s|image: ${escaped_registry}/\\([^[:space:]]*\\)|image: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1|g\""
    sed_cmd+=" -e \"s|image: \\\"${escaped_registry}/\\([^\\\"]*\\)\\\"|image: \\\"${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1\\\"|g\""
    
    # Hub field patterns (for istio)
    sed_cmd+=" -e \"s|hub: ${escaped_registry}/\\([^[:space:]]*\\)|hub: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1|g\""
    
    # Special field patterns
    sed_cmd+=" -e \"s|fullImageName: ${escaped_registry}/\\([^[:space:]]*\\)|fullImageName: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1|g\""
    sed_cmd+=" -e \"s|imageNameAndVersion: ${escaped_registry}/\\([^[:space:]]*\\)|imageNameAndVersion: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}/${ecr_path}-\\1|g\""
    
    # AWS CloudWatch Observability patterns
    sed_cmd+=" -e \"s|repositoryDomain: ${escaped_registry}/\\([^[:space:]]*\\)|repositoryDomain: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}|g\""
    sed_cmd+=" -e \"s|repositoryDomain: ${escaped_registry}|repositoryDomain: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}|g\""
    
    # repositoryDomainMap patterns - will be post-processed to use correct repo names
    sed_cmd+=" -e \"s|public: ${escaped_registry}/\\([^[:space:]]*\\)|public: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}|g\""
    sed_cmd+=" -e \"s|public: ${escaped_registry}|public: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}|g\""
    sed_cmd+=" -e \"s|${REGION}: ${escaped_registry}/\\([^[:space:]]*\\)|${REGION}: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}|g\""
    sed_cmd+=" -e \"s|${REGION}: ${escaped_registry}|${REGION}: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_PREFIX}|g\""
  done
  
  # Execute the sed command
  eval "$sed_cmd \"$values_file\" > \"$temp_file\""
  mv "$temp_file" "$values_file"
  
  # Post-process to append repository names to repositoryDomainMap entries
  # Validate values_file path before passing to Python
  if [[ ! -f "$values_file" ]]; then
    log_warning "Values file not found for post-processing: $values_file"
    return 0
  fi
  local resolved_values_file
  resolved_values_file=$(cd "$(dirname "$values_file")" && pwd)/$(basename "$values_file")
  python3 -c "
import re
import sys
import os

values_path = sys.argv[1]
# Validate file exists and is a regular file
if not os.path.isfile(values_path):
    sys.exit(0)

with open(values_path, 'r') as f:
    content = f.read()

# Find image sections and fix repositoryDomainMap
pattern = r'(image:\s*\n(?:[^\n]*\n)*?\s*repository:\s*([^\n]+)\n(?:[^\n]*\n)*?\s*repositoryDomainMap:\s*\n(?:[^\n]*\n)*?\s*public:\s*)([^\n]+)'

def fix_domain_map(match):
    full_match = match.group(0)
    repo_name = match.group(2).strip()
    domain_prefix = match.group(3)
    
    # If domain ends with eks-addons, append the repository name
    if domain_prefix.endswith('eks-addons'):
        new_domain = domain_prefix + '/' + repo_name
        return full_match.replace(domain_prefix, new_domain)
    return full_match

content = re.sub(pattern, fix_domain_map, content, flags=re.MULTILINE | re.DOTALL)

with open(values_path, 'w') as f:
    f.write(content)
" "$resolved_values_file" 2>/dev/null || true
}
replace_image_references() {
  local chart_dir="$1"
  local values_file="$chart_dir/values.yaml"
  
  if [[ ! -f "$values_file" ]]; then
    return 0
  fi
  
  log_info "Replacing image references in values.yaml with ECR references"
  
  # Create backup
  cp "$values_file" "${values_file}.backup"
  
  # Use comprehensive registry replacement
  replace_registry_references "$values_file"
  
  # Log changes
  if ! diff -q "${values_file}.backup" "$values_file" >/dev/null 2>&1; then
    log_info "  Updated image references to use ECR registry"
    log_info "  Replaced registry, defaultRegistry, and repository fields"
  fi
}

# Replace dependency references in Chart.yaml with ECR references  
replace_dependency_references() {
  local chart_dir="$1"
  local chart_file="$chart_dir/Chart.yaml"
  
  if [[ ! -f "$chart_file" ]]; then
    return 0
  fi
  
  log_info "Replacing dependency references in Chart.yaml with ECR references"
  
  # Create backup
  cp "$chart_file" "${chart_file}.backup"
  
  # Use comprehensive sed replacement for all dependency repository patterns
  local temp_file=$(mktemp)
  
  # Replace all repository URLs with ECR OCI references
  # This handles: https://..., http://..., oci://..., and registry-only patterns
  sed \
    -e "s|repository:[[:space:]]*https://[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*http://[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*oci://[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*registry\.k8s\.io[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*docker\.io[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*quay\.io[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*gcr\.io[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    -e "s|repository:[[:space:]]*ghcr\.io[^[:space:]]*|repository: oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}|g" \
    "$chart_file" > "$temp_file"
  
  mv "$temp_file" "$chart_file"
  
  # Log changes
  if ! diff -q "${chart_file}.backup" "$chart_file" >/dev/null 2>&1; then
    log_info "  Updated dependency repositories to use ECR OCI registry"
    log_info "  Replaced HTTP/HTTPS and OCI repository URLs"
  fi
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -c|--config)
        CONFIG_FILE="$2"
        shift 2
        ;;
      --terraform-dir)
        # Load configuration from specified Terraform directory
        if read_terraform_config "$2"; then
          TF_CONFIG_LOADED=true
          # Re-initialize variables with new defaults
          RESOURCE_PREFIX="${DEFAULT_RESOURCE_PREFIX}"
          HELM_SUFFIX="${DEFAULT_HELM_SUFFIX}"
          IMAGE_SUFFIX="${DEFAULT_IMAGE_SUFFIX}"
          ECR_PREFIX="${RESOURCE_PREFIX}${HELM_SUFFIX}"
          IMAGE_PREFIX="${RESOURCE_PREFIX}${IMAGE_SUFFIX}"
          log_info "Loaded naming configuration from Terraform directory: $2"
        else
          log_warning "Could not load Terraform configuration from: $2"
        fi
        shift 2
        ;;
      # New naming convention options
      --resource-prefix)
        RESOURCE_PREFIX="$2"
        # Recalculate prefixes
        ECR_PREFIX="${RESOURCE_PREFIX}${HELM_SUFFIX}"
        IMAGE_PREFIX="${RESOURCE_PREFIX}${IMAGE_SUFFIX}"
        shift 2
        ;;
      --helm-suffix)
        HELM_SUFFIX="$2"
        # Recalculate ECR prefix
        ECR_PREFIX="${RESOURCE_PREFIX}${HELM_SUFFIX}"
        shift 2
        ;;
      --image-suffix)
        IMAGE_SUFFIX="$2"
        # Recalculate image prefix
        IMAGE_PREFIX="${RESOURCE_PREFIX}${IMAGE_SUFFIX}"
        shift 2
        ;;
      # Legacy options (deprecated but supported for backward compatibility)
      -p|--prefix)
        log_warning "Option --prefix is deprecated. Use --resource-prefix and --helm-suffix instead."
        ECR_PREFIX="$2"
        shift 2
        ;;
      --image-prefix)
        log_warning "Option --image-prefix is deprecated. Use --resource-prefix and --image-suffix instead."
        IMAGE_PREFIX="$2"
        shift 2
        ;;
      -r|--region)
        REGION="$2"
        shift 2
        ;;
      -a|--account)
        ACCOUNT_ID="$2"
        shift 2
        ;;
      --profile)
        export AWS_PROFILE="$2"
        shift 2
        ;;
      -n|--no-create-repos)
        CREATE_REPOS=false
        shift
        ;;
      --no-images)
        PROCESS_IMAGES=false
        shift
        ;;
      --use-templates)
        USE_CREATION_TEMPLATES=true
        shift
        ;;
      --no-templates)
        USE_CREATION_TEMPLATES=false
        shift
        ;;
      --cleanup)
        CLEANUP_FILES=true
        shift
        ;;
      --force)
        FORCE_UPDATE=true
        shift
        ;;
      --plan)
        PLAN_MODE=true
        shift
        ;;
      # Helm chart mode parameters
      --name)
        CLI_NAME="$2"
        CLI_MODE=true
        shift 2
        ;;
      --repository)
        CLI_REPOSITORY="$2"
        CLI_MODE=true
        shift 2
        ;;
      --chart)
        CLI_CHART="$2"
        CLI_MODE=true
        shift 2
        ;;
      --version)
        CLI_VERSION="$2"
        CLI_MODE=true
        shift 2
        ;;
      # Standalone image mode parameters
      --image)
        STANDALONE_IMAGE="$2"
        STANDALONE_IMAGE_MODE=true
        shift 2
        ;;
      --image-file)
        STANDALONE_IMAGE_FILE="$2"
        STANDALONE_IMAGE_MODE=true
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  # Validate mode conflicts
  # Note: Using $((var + 1)) instead of ((var++)) because ((0++)) returns exit code 1
  # which causes silent script termination under set -e
  local mode_count=0
  [[ "$CLI_MODE" == true ]] && mode_count=$((mode_count + 1))
  [[ "$STANDALONE_IMAGE_MODE" == true ]] && mode_count=$((mode_count + 1))
  [[ -f "$CONFIG_FILE" && "$CLI_MODE" == false && "$STANDALONE_IMAGE_MODE" == false ]] && mode_count=$((mode_count + 1))
  
  if [[ $mode_count -gt 1 ]]; then
    log_error "Cannot use multiple modes simultaneously. Choose one: config file, command line (Helm), or standalone image mode."
    usage
    exit 1
  fi

  # Validate command line mode parameters
  if [[ "$CLI_MODE" == true ]]; then
    if [[ -z "$CLI_NAME" || -z "$CLI_REPOSITORY" || -z "$CLI_CHART" || -z "$CLI_VERSION" ]]; then
      log_error "Command line mode requires --name, --repository, --chart, and --version parameters"
      usage
      exit 1
    fi
  fi
  
  # Validate standalone image mode parameters
  if [[ "$STANDALONE_IMAGE_MODE" == true ]]; then
    if [[ -z "$STANDALONE_IMAGE" && -z "$STANDALONE_IMAGE_FILE" ]]; then
      log_error "Standalone image mode requires either --image or --image-file parameter"
      usage
      exit 1
    fi
    if [[ -n "$STANDALONE_IMAGE" && -n "$STANDALONE_IMAGE_FILE" ]]; then
      log_error "Cannot use both --image and --image-file simultaneously"
      usage
      exit 1
    fi
  fi
}

# Get AWS account ID
get_account_id() {
  if [[ -z "$ACCOUNT_ID" ]]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || {
      log_error "Failed to get AWS account ID. Please check your AWS credentials."
      log_error "Current AWS_PROFILE: ${AWS_PROFILE:-not set}"
      exit 1
    })
  fi
  log_info "Using AWS Account: $ACCOUNT_ID, Region: $REGION"
  log_info "AWS Profile: ${AWS_PROFILE:-default}"
  
  # Login to ECR once at the beginning
  if ! aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null; then
    log_error "Failed to login to ECR. Please check your AWS credentials and permissions."
    exit 1
  fi
}

# Check if the region supports Repository Creation Templates
validate_region_support() {
  local region="$1"
  
  log_debug "Validating Repository Creation Templates support for region: ${region}"
  
  # Try to call describe-repository-creation-templates to check if the feature is supported
  local validation_output
  if validation_output=$(aws ecr describe-repository-creation-templates \
    --region "${region}" 2>&1); then
    log_debug "Region ${region} supports Repository Creation Templates"
    return 0
  else
    # Check for specific error messages indicating unsupported feature
    if echo "$validation_output" | grep -qi "InvalidAction\|UnsupportedOperation\|UnknownOperation"; then
      log_warning "Repository Creation Templates are not supported in region ${region}"
      log_warning "Falling back to manual repository configuration"
      return 1
    elif echo "$validation_output" | grep -qi "AccessDenied\|UnauthorizedException"; then
      log_warning "Access denied when checking template support in region ${region}"
      log_warning "This may indicate missing IAM permissions or unsupported region"
      return 1
    else
      # Other errors - assume feature might be supported but there's a different issue
      log_debug "Unable to definitively determine template support: $validation_output"
      # Return success to allow attempting template creation (will fail gracefully if not supported)
      return 0
    fi
  fi
}

# Check if Repository Creation Templates are available in the region
check_template_availability() {
  local repo_name="$1"
  local expected_prefix=""
  
  # Determine which template prefix should apply based on repository name
  if [[ "${repo_name}" == "${ECR_PREFIX}/"* ]]; then
    expected_prefix="${ECR_PREFIX}"
  elif [[ "${repo_name}" == "${IMAGE_PREFIX}/"* ]]; then
    expected_prefix="${IMAGE_PREFIX}"
  else
    log_debug "Repository ${repo_name} does not match any template prefix"
    return 1
  fi
  
  log_debug "Checking for template with prefix: ${expected_prefix}"
  
  # Try to list repository creation templates
  local templates_output
  if templates_output=$(aws ecr describe-repository-creation-templates \
    --region "${REGION}" 2>&1); then
    
    # Check if the expected prefix exists in the templates
    if echo "$templates_output" | grep -q "\"prefix\": \"${expected_prefix}\""; then
      log_debug "Template found for prefix: ${expected_prefix}"
      return 0
    else
      log_debug "No template found for prefix: ${expected_prefix}"
      return 1
    fi
  else
    # Command failed - could be unsupported region or permission issue
    log_debug "Failed to describe repository creation templates: $templates_output"
    return 1
  fi
}

# Create repository using Repository Creation Templates (simplified)
create_repository_with_template() {
  local repo_name="$1"
  local repo_type="$2"  # "chart" or "image"
  
  # First, validate that the region supports Repository Creation Templates
  if ! validate_region_support "${REGION}"; then
    log_warning "Region ${REGION} does not support Repository Creation Templates. Falling back to manual configuration..."
    create_repository_manual "${repo_name}" "${repo_type}"
    return $?
  fi
  
  # Check if templates are available
  if ! check_template_availability "${repo_name}"; then
    log_warning "Repository Creation Templates not found for ${repo_name}. Falling back to manual configuration..."
    create_repository_manual "${repo_name}" "${repo_type}"
    return $?
  fi
  
  # With Repository Creation Templates, CREATE_ON_PUSH works for BOTH Helm charts and Docker images
  # The repository will be created automatically on first push with all template settings applied
  log_info "Using Repository Creation Templates - ${repo_type} repository will be created automatically on push"
  log_success "Repository ${repo_name} will be created automatically on push with template settings (KMS encryption, IMMUTABLE tags, lifecycle policy)."
  return 0
}

# Create repository with manual configuration (fallback when templates unavailable)
# Security controls applied:
#   - Image scanning enabled (scanOnPush=true)
#   - Immutable image tags (prevents tag overwrites)
#   - Lifecycle policy (expires old images to reduce storage)
# Note: For AWS KMS encryption, deploy Repository Creation Templates via Terraform.
#       Manual creation uses default Amazon ECR encryption (AES-256).
#       Customers should deploy templates first for full security controls.
create_repository_manual() {
  local repo_name="$1"
  local repo_type="$2"  # "chart" or "image"
  
  log_info "Creating $repo_type repository ${repo_name} with manual configuration..."
  
  # Create repository with scanning and encryption
  # Note: When Repository Creation Templates are not available, this fallback
  # uses AES256 encryption. For KMS encryption, deploy templates via Terraform first.
  if aws ecr create-repository \
    --repository-name "${repo_name}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability IMMUTABLE > /dev/null 2>&1; then
    
    # Add lifecycle policy to keep only last 10 versions
    log_info "Adding lifecycle policy to ${repo_name}..."
    aws ecr put-lifecycle-policy \
      --region "${REGION}" \
      --repository-name "${repo_name}" \
      --lifecycle-policy-text '{"rules":[{"rulePriority":1,"description":"Keep last 10 versions","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}' > /dev/null 2>&1
    
    log_success "Repository ${repo_name} created successfully with manual configuration."
    return 0
  else
    log_error "Failed to create repository ${repo_name}"
    return 1
  fi
}

# Create ECR repository if it doesn't exist (using original working logic)
create_repository() {
  local repo_name="$1"
  local repo_type="$2"  # "chart" or "image"
  
  # Skip repository names with special characters that would fail validation
  if [[ "${repo_name}" == *"#"* ]] || [[ "${repo_name}" == *":"* ]] || [[ "${repo_name}" == *"@"* ]]; then
    log_info "Skipping invalid repository name: ${repo_name}"
    return 0
  fi
  
  log_info "Checking if $repo_type repository ${repo_name} exists..."
  
  if ! aws ecr describe-repositories --repository-names "${repo_name}" --region "${REGION}" &>/dev/null; then
    if [[ "${CREATE_REPOS}" == "true" ]]; then
      log_info "Repository ${repo_name} does not exist. Creating..."
      
      # Use template-based or manual creation based on flag
      if [[ "${USE_CREATION_TEMPLATES}" == "true" ]]; then
        create_repository_with_template "${repo_name}" "${repo_type}"
      else
        create_repository_manual "${repo_name}" "${repo_type}"
      fi
      
      return $?
    else
      log_error "Repository ${repo_name} does not exist and automatic creation is disabled."
      return 1
    fi
  else
    log_success "$repo_type repository '${repo_name}' already exists."
  fi
}

# Check if chart exists in ECR
chart_exists_in_ecr() {
  local repo_name="$1"
  local version="$2"
  
  aws ecr describe-images \
    --repository-name "$repo_name" \
    --image-ids imageTag="$version" \
    --region "$REGION" >/dev/null 2>&1
}

# Check if image exists in ECR
image_exists_in_ecr() {
  local repo_name="$1"
  local tag="$2"
  
  aws ecr describe-images \
    --repository-name "$repo_name" \
    --image-ids imageTag="$tag" \
    --region "$REGION" >/dev/null 2>&1
}

# Extract images from Helm chart using helm template (production-ready approach)
extract_images_from_chart() {
  local chart_dir="$1"
  local chart_name="$2"
  local images=()
  
  log_info "Extracting container images from chart: $chart_name"
  
  # Use helm template to render the chart and extract actual images that would be used
  local rendered_templates
  local template_images=""
  
  # For amazon-cloudwatch-observability chart, provide region context
  local helm_args=""
  if [[ "$chart_name" == *"cloudwatch"* ]] || [[ "$chart_name" == *"amazon-cloudwatch-observability"* ]]; then
    helm_args="--set region=$REGION --set clusterName=test-cluster"
  fi
  
  if rendered_templates=$(helm template "$chart_name" "$chart_dir" $helm_args 2>/dev/null); then
    # Extract all image references from rendered Kubernetes manifests
    template_images=$(echo "$rendered_templates" | \
      # Look for image: fields in YAML (both key-value and list formats)
      grep -E "^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*[\"']?[^[:space:]]+[\"']?[[:space:]]*$" | \
      # Extract the image value (handle both quoted and unquoted strings)
      sed -E 's/^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*"([^"]+)"[[:space:]]*$/\2/' | \
      sed -E "s/^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*'([^']+)'[[:space:]]*$/\2/" | \
      sed -E 's/^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\2/' | \
      # Remove any remaining quotes or whitespace
      sed "s/^[\"']*//;s/[\"']*$//" | \
      # Remove SHA256 digests (@sha256:...) to get clean image:tag format
      sed 's/@sha256:[a-f0-9]*$//' | \
      # Remove standalone SHA256 references
      grep -v '^sha256:[a-f0-9]*$' | \
      # Filter out invalid/local images
      grep -v -E '^(localhost|127\.0\.0\.1|0\.0\.0\.0|kubernetes\.default\.svc|.*\.svc\.cluster\.local):' | \
      grep -v -E ':[0-9]+$' | \
      # Only include valid container image formats (allow dots in tags)
      grep -E '^[a-zA-Z0-9._-]+(\.[a-zA-Z0-9._-]+)*(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$' | \
      # Remove duplicates
      sort -u)
  else
    log_warning "Failed to render chart templates, using values.yaml parsing only"
    # When template rendering fails, be more aggressive with values.yaml parsing
    template_images=""
  fi
  
  # Always supplement with values.yaml parsing to catch images not in templates (like Istio proxyv2)
  local values_images=""
  local values_file="$chart_dir/values.yaml"
  if [[ -f "$values_file" ]]; then
    # Extract Istio-style hub + image + tag combinations (for charts like istiod)
    local hub_images=""
    local global_hub global_tag
    # Try standard global path first, then Istio's special structure
    global_hub=$(yq eval '.global.hub // ._internal_defaults_do_not_set.global.hub // ""' "$values_file" 2>/dev/null || echo "")
    global_tag=$(yq eval '.global.tag // ._internal_defaults_do_not_set.global.tag // ""' "$values_file" 2>/dev/null || echo "")
    
    # For Istio charts, provide default hub and tag if not specified
    if [[ -z "$global_hub" && ("$chart_name" == *"istio"* || "$chart_name" == *"pilot"* || "$chart_name" == "istiod" || "$chart_name" == "base") ]]; then
      global_hub="gcr.io/istio-release"
      log_info "Using default Istio hub for chart: $chart_name"
    fi
    if [[ -z "$global_tag" && ("$chart_name" == *"istio"* || "$chart_name" == *"pilot"* || "$chart_name" == "istiod" || "$chart_name" == "base") ]]; then
      # Extract appVersion from Chart.yaml or use the chart version
      global_tag=$(yq eval '.appVersion // .version' "$chart_dir/Chart.yaml" 2>/dev/null || echo "$version")
      log_info "Using default Istio tag for chart: $chart_name -> $global_tag"
    fi
    
    if [[ -n "$global_hub" && -n "$global_tag" ]]; then
      log_info "Found Istio image extraction: hub=$global_hub, tag=$global_tag"
      # Look for image names that can be combined with global hub and tag
      local image_names
      image_names=$(yq eval '.. | select(type == "!!str" and test("^[a-zA-Z0-9._-]+$") and . != "latest" and . != "stable" and . != "debug" and . != "distroless") | .' "$values_file" 2>/dev/null | grep -E '^(pilot|proxyv2|proxy|istiod)' || true)
      
      # For Istio charts, add known standard images if not found in values
      if [[ "$chart_name" == *"istio"* || "$chart_name" == "base" || "$chart_name" == "istiod" ]]; then
        if [[ "$chart_name" == "istiod" ]]; then
          # istiod chart should have pilot and proxyv2
          image_names+=$'\n'"pilot"$'\n'"proxyv2"
        elif [[ "$chart_name" == "base" ]]; then
          # base chart typically doesn't have images, but might reference proxyv2
          image_names+=$'\n'"proxyv2"
        fi
      fi
      
      log_info "Found Istio image names: $(echo "$image_names" | tr '\n' ' ')"
      
      while IFS= read -r image_name; do
        if [[ -n "$image_name" ]]; then
          # Use gcr.io/istio-release for istiod image specifically, but map istiod to pilot
          if [[ "$image_name" == "istiod" ]]; then
            hub_images+="gcr.io/istio-release/pilot:${global_tag}"$'\n'
          else
            hub_images+="${global_hub}/${image_name}:${global_tag}"$'\n'
          fi
        fi
      done <<< "$image_names"
    fi
    
    # Generic image construction from values.yaml patterns
    local constructed_images=""
    
    # Pattern 1: registry + repository + tag (common pattern)
    # Find all objects that have both registry and repository fields
    local image_objects
    image_objects=$(yq eval '.. | select(has("registry") and has("repository"))' "$values_file" 2>/dev/null || true)
    
    # Pattern 2: repositoryDomain + repository + tag (AWS CloudWatch pattern)
    local aws_image_objects
    aws_image_objects=$(yq eval '.. | select(has("repositoryDomain") and has("repository") and has("tag"))' "$values_file" 2>/dev/null || true)
    
    # Pattern 3: repositoryDomainMap + repository + tag (AWS CloudWatch Observability pattern)
    local cloudwatch_images=""
    if [[ "$chart_name" == *"cloudwatch"* ]] || [[ "$chart_name" == *"amazon-cloudwatch-observability"* ]]; then
      # Extract images using repositoryDomainMap pattern with region context
      cloudwatch_images=$(extract_cloudwatch_observability_images "$values_file" "$REGION")
    fi
    
    if [[ -n "$image_objects" && "$image_objects" != "null" ]]; then
      # Process each image object
      local temp_file=$(mktemp)
      echo "$image_objects" > "$temp_file"
      
      local registry repository tag
      registry=$(yq eval '.registry' "$temp_file" 2>/dev/null || echo "")
      repository=$(yq eval '.repository' "$temp_file" 2>/dev/null || echo "")
      tag=$(yq eval '.tag' "$temp_file" 2>/dev/null || echo "")
      
      if [[ -n "$registry" && -n "$repository" && "$registry" != "null" && "$repository" != "null" ]]; then
        # Use tag if available and not empty, otherwise try appVersion from Chart.yaml
        if [[ -z "$tag" || "$tag" == "null" || "$tag" == '""' || "$tag" == "" ]]; then
          tag=$(yq eval '.appVersion' "$chart_dir/Chart.yaml" 2>/dev/null || echo "latest")
        fi
        [[ "$tag" == "null" ]] && tag="latest"
        
        constructed_images+="${registry}/${repository}:${tag}"$'\n'
      fi
      
      rm -f "$temp_file"
    fi
    
    # Process AWS CloudWatch repositoryDomain pattern
    if [[ -n "$aws_image_objects" && "$aws_image_objects" != "null" ]]; then
      local temp_file=$(mktemp)
      echo "$aws_image_objects" > "$temp_file"
      
      local repositoryDomain repository tag
      while IFS= read -r line; do
        if [[ "$line" =~ ^repositoryDomain: ]]; then
          repositoryDomain=$(echo "$line" | cut -d' ' -f2-)
        elif [[ "$line" =~ ^repository: ]]; then
          repository=$(echo "$line" | cut -d' ' -f2-)
        elif [[ "$line" =~ ^tag: ]]; then
          tag=$(echo "$line" | cut -d' ' -f2-)
          
          # When we have all three components, construct the image
          if [[ -n "$repositoryDomain" && -n "$repository" && -n "$tag" ]]; then
            constructed_images+="${repositoryDomain}/${repository}:${tag}"$'\n'
            repositoryDomain=""
            repository=""
            tag=""
          fi
        fi
      done < "$temp_file"
      
      rm -f "$temp_file"
    fi
    
    # Pattern 2: Direct image references in values.yaml
    local direct_images
    direct_images=$(yq eval '.. | select(type == "!!str" and test("^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$")) | .' "$values_file" 2>/dev/null | \
      grep -v '^sha256:[a-f0-9]*$' | \
      grep -v -E '^(system|default|misc|debug|info|error|warn|trace):[a-zA-Z0-9._-]+$' | \
      grep '/' || true)
    
    values_images=$(printf "%s\n%s\n%s\n%s\n" "$hub_images" "$constructed_images" "$direct_images" "$cloudwatch_images" | grep -v '^[[:space:]]*$')
  fi
  
  # Combine template images and values images
  local extracted_images
  extracted_images=$(printf "%s\n%s\n" "$template_images" "$values_images" | \
    grep -E '^[a-zA-Z0-9._-]+(\.[a-zA-Z0-9._-]+)*(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$' | \
    grep -v '^[[:space:]]*$' | \
    sort -u)
  
  # Deduplicate images with same name but different versions (keep latest version)
  local deduplicated_images
  deduplicated_images=$(echo "$extracted_images" | \
    awk -F: '{
      image_name = $1
      version = $2
      if (image_name in images) {
        # Simple version comparison - prefer longer version strings (more specific)
        # and handle semantic versioning patterns
        current_version = images[image_name]
        
        # If one version is a prefix of another, keep the longer one
        if (index(version, current_version) == 1 && length(version) > length(current_version)) {
          images[image_name] = version
        } else if (index(current_version, version) == 1 && length(current_version) > length(version)) {
          # Keep current version (longer)
        } else {
          # For different versions, do lexicographic comparison
          if (version > current_version) {
            images[image_name] = version
          }
        }
      } else {
        images[image_name] = version
      }
    }
    END {
      for (img in images) {
        print img ":" images[img]
      }
    }' | sort)
  
  # Also extract from containers and initContainers sections
  local container_images
  container_images=$(echo "$rendered_templates" | \
    # Use awk to properly parse containers sections
    awk '
      /^[[:space:]]*containers:[[:space:]]*$/ { in_containers = 1; next }
      /^[[:space:]]*initContainers:[[:space:]]*$/ { in_containers = 1; next }
      /^[[:space:]]*[a-zA-Z]/ && in_containers && !/^[[:space:]]*-/ && !/^[[:space:]]*image:/ && !/^[[:space:]]*name:/ { in_containers = 0 }
      in_containers && /^[[:space:]]*-[[:space:]]*image:[[:space:]]*/ {
        gsub(/^[[:space:]]*-[[:space:]]*image:[[:space:]]*/, "")
        gsub(/["\047]/, "")
        gsub(/[[:space:]]*$/, "")
        if ($0 !~ /^[[:space:]]*$/ && $0 !~ /localhost|127\.0\.0\.1|kubernetes\.default\.svc/) {
          print $0
        }
      }
      in_containers && /^[[:space:]]*image:[[:space:]]*/ {
        gsub(/^[[:space:]]*image:[[:space:]]*/, "")
        gsub(/["\047]/, "")
        gsub(/[[:space:]]*$/, "")
        if ($0 !~ /^[[:space:]]*$/ && $0 !~ /localhost|127\.0\.0\.1|kubernetes\.default\.svc/) {
          print $0
        }
      }
    ' | \
    # Filter valid images
    grep -E '^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$' | \
    sort -u)
  
  # Combine all extracted images
  local all_images
  all_images=$(printf "%s\n%s\n" "$deduplicated_images" "$container_images" | \
    grep -v '^[[:space:]]*$' | \
    sort -u)
  
  # Convert to array and validate
  for img in $all_images; do
    if [[ -n "$img" && "$img" != *"{{" && "$img" != *"}}" ]]; then
      # Additional validation for production readiness
      if [[ "$img" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$ ]] && \
         [[ "$img" != *"localhost"* ]] && \
         [[ "$img" != *"127.0.0.1"* ]] && \
         [[ "$img" != *"0.0.0.0"* ]] && \
         [[ "$img" != *".svc.cluster.local"* ]] && \
         [[ "$img" != *"kubernetes.default.svc"* ]] && \
         [[ ! "$img" =~ :[0-9]+$ ]] && \
         [[ ! "$img" =~ ^[^:]*:[0-9]+\.$ ]] && \
         [[ ! "$img" =~ ^sha256: ]] && \
         [[ ! "$img" =~ ^[a-f0-9]{64}$ ]] && \
         [[ ! "$img" =~ ^(system|default|misc|debug|info|error|warn|trace):[a-zA-Z0-9._-]+$ ]] && \
         [[ "$img" =~ / ]]; then
        images+=("$img")
      fi
    fi
  done
  
  # Remove duplicates and return unique images
  if [[ ${#images[@]} -gt 0 ]]; then
    printf '%s\n' "${images[@]:-}" | sort -u
  fi
}

# Fallback function for basic values.yaml parsing when helm template fails
extract_images_from_values_fallback() {
  local chart_dir="$1"
  local chart_name="$2"
  local images=()
  
  log_info "Using fallback values.yaml parsing for: $chart_name"
  
  # Find all values.yaml files (including subchart values)
  local values_files
  values_files=$(find "$chart_dir" -name "values.yaml" -type f)
  
  for values_file in $values_files; do
    log_info "Processing values file: $values_file"
    
    # Use yq if available for better YAML parsing, otherwise use awk
    local extracted_images
    if command -v yq >/dev/null 2>&1; then
      # Use yq for proper YAML parsing (most reliable)
      # Extract direct image references (string values only)
      extracted_images=$(yq eval '.. | select(type == "!!str" and test("^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$"))' "$values_file" 2>/dev/null || true)
      
      # Extract repository + tag combinations where both exist and are non-empty
      local repo_tag_images
      repo_tag_images=$(yq eval '.. | select(has("repository") and has("tag") and .repository != "" and .tag != "" and .tag != null) | .repository + ":" + .tag' "$values_file" 2>/dev/null || true)
      
      # Extract registry + repository combinations and add appVersion
      local registry_images
      local app_version
      app_version=$(yq eval '.appVersion' "$chart_dir/Chart.yaml" 2>/dev/null || echo "latest")
      registry_images=$(yq eval ".. | select(has(\"registry\") and has(\"repository\") and .registry != \"\" and .repository != \"\") | .registry + \"/\" + .repository + \":$app_version\"" "$values_file" 2>/dev/null || true)
      
      # Extract Istio-style hub + image + tag combinations (for charts like istiod)
      local hub_images=""
      local global_hub global_tag
      # Try standard global path first, then Istio's special structure
      global_hub=$(yq eval '.global.hub // ._internal_defaults_do_not_set.global.hub // ""' "$values_file" 2>/dev/null || echo "")
      global_tag=$(yq eval '.global.tag // ._internal_defaults_do_not_set.global.tag // ""' "$values_file" 2>/dev/null || echo "")
      
      # For Istio charts, provide default hub and tag if not specified
      if [[ -z "$global_hub" && ("$chart_name" == *"istio"* || "$chart_name" == *"pilot"* || "$chart_name" == "istiod" || "$chart_name" == "base") ]]; then
        global_hub="gcr.io/istio-release"
        log_info "Using default Istio hub for chart (fallback): $chart_name"
      fi
      if [[ -z "$global_tag" && ("$chart_name" == *"istio"* || "$chart_name" == *"pilot"* || "$chart_name" == "istiod" || "$chart_name" == "base") ]]; then
        # Extract appVersion from Chart.yaml or use the chart version
        global_tag=$(yq eval '.appVersion // .version' "$chart_dir/Chart.yaml" 2>/dev/null || echo "$app_version")
        log_info "Using default Istio tag for chart (fallback): $chart_name -> $global_tag"
      fi
      
      if [[ -n "$global_hub" && -n "$global_tag" ]]; then
        # Look for image names that can be combined with global hub and tag
        local image_names
        image_names=$(yq eval '.. | select(type == "!!str" and test("^[a-zA-Z0-9._-]+$") and . != "latest" and . != "stable" and . != "debug" and . != "distroless") | .' "$values_file" 2>/dev/null | grep -E '^(pilot|proxyv2|proxy|istiod)' || true)
        
        # For Istio charts, add known standard images if not found in values
        if [[ "$chart_name" == *"istio"* || "$chart_name" == "base" || "$chart_name" == "istiod" ]]; then
          if [[ "$chart_name" == "istiod" ]]; then
            # istiod chart should have pilot and proxyv2
            image_names+=$'\n'"pilot"$'\n'"proxyv2"
          elif [[ "$chart_name" == "base" ]]; then
            # base chart typically doesn't have images, but might reference proxyv2
            image_names+=$'\n'"proxyv2"
          fi
        fi
        
        log_info "Found Istio image names (fallback): $(echo "$image_names" | tr '\n' ' ')"
        
        while IFS= read -r image_name; do
          if [[ -n "$image_name" ]]; then
            # Use gcr.io/istio-release for istiod image specifically, but map istiod to pilot
            if [[ "$image_name" == "istiod" ]]; then
              hub_images+="gcr.io/istio-release/pilot:${global_tag}"$'\n'
            else
              hub_images+="${global_hub}/${image_name}:${global_tag}"$'\n'
            fi
          fi
        done <<< "$image_names"
      fi
      
      # Combine all extracted images and filter valid ones
      extracted_images=$(printf "%s\n%s\n%s\n%s\n" "$extracted_images" "$repo_tag_images" "$registry_images" "$hub_images" | \
        grep -E '^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$' | \
        grep -v '^[[:space:]]*$' || true)
    else
      # Fallback to awk-based parsing (less reliable but no dependencies)
      extracted_images=$(
        # Pattern 1: Direct image references
        grep -v "^[[:space:]]*#" "$values_file" | \
          grep -E "^[[:space:]]*image:[[:space:]]*[\"']?[^[:space:]]+:[^[:space:]]+[\"']?[[:space:]]*$" | \
          sed -E 's/^[[:space:]]*image:[[:space:]]*["\047]?([^"\047[:space:]]+)["\047]?[[:space:]]*$/\1/' | \
          sed 's/#.*$//' || true
        
        # Pattern 2: Repository + tag combinations
        awk '
          BEGIN { repo = ""; tag = ""; in_block = 0 }
          /^[[:space:]]*#/ { next }
          /^[[:space:]]*repository:[[:space:]]*/ {
            gsub(/^[[:space:]]*repository:[[:space:]]*/, "")
            gsub(/["\047]/, "")
            gsub(/#.*$/, "")
            gsub(/^[[:space:]]*/, "")
            gsub(/[[:space:]]*$/, "")
            if ($0 !~ /^[[:space:]]*$/) repo = $0
          }
          /^[[:space:]]*tag:[[:space:]]*/ {
            gsub(/^[[:space:]]*tag:[[:space:]]*/, "")
            gsub(/["\047]/, "")
            gsub(/#.*$/, "")
            gsub(/^[[:space:]]*/, "")
            gsub(/[[:space:]]*$/, "")
            if ($0 !~ /^[[:space:]]*$/) {
              tag = $0
              if (repo && tag) {
                print repo ":" tag
                repo = ""
                tag = ""
              }
            }
          }
        ' "$values_file" || true
      )
    fi
    
    # Add extracted images to the main array
    for img in $extracted_images; do
      if [[ -n "$img" && "$img" != *"{{" && "$img" != *"}}" ]]; then
        # Production-ready validation
        if [[ "$img" =~ ^[a-zA-Z0-9._-]+(/[a-zA-Z0-9._-]+)*:[a-zA-Z0-9._-]+$ ]] && \
           [[ "$img" != *"localhost"* ]] && \
           [[ "$img" != *"127.0.0.1"* ]] && \
           [[ "$img" != *"0.0.0.0"* ]] && \
           [[ "$img" != *".svc.cluster.local"* ]] && \
           [[ "$img" != *"kubernetes.default.svc"* ]] && \
           [[ ! "$img" =~ :[0-9]+$ ]] && \
           [[ ! "$img" =~ ^[^:]*:[0-9]+\.$ ]]; then
          images+=("$img")
        fi
      fi
    done
  done
  
  # Remove duplicates and return unique images
  if [[ ${#images[@]} -gt 0 ]]; then
    printf '%s\n' "${images[@]:-}" | sort -u
  fi
}



# Function to try pulling from public registry as fallback
try_public_image_fallback() {
  local source_image="$1"
  
  log_processing_step "public_fallback_start" "$source_image" "Starting public registry fallback search"
  
  # Extract image name and tag
  local image_name_tag=$(echo "${source_image}" | sed 's|^[^/]*/||' | sed 's|^[^/]*/||')
  local image_name=$(echo "${image_name_tag}" | cut -d: -f1)
  local tag=$(echo "${image_name_tag}" | cut -d: -f2)
  
  log_processing_step "image_parsing" "$source_image" "Parsed image: name=$image_name, tag=$tag"
  
  # Common public registry mappings
  local public_alternatives=()
  
  case "${source_image}" in
    registry.k8s.io/*)
      public_alternatives+=("k8s.gcr.io/${image_name_tag}")
      public_alternatives+=("docker.io/library/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Kubernetes registry alternatives identified"
      ;;
    ghcr.io/dexidp/*)
      public_alternatives+=("docker.io/dexidp/${image_name}:${tag}")
      public_alternatives+=("quay.io/dexidp/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "DexIDP alternatives identified"
      ;;
    ghcr.io/*)
      public_alternatives+=("docker.io/${image_name}:${tag}")
      public_alternatives+=("quay.io/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "GitHub Container Registry alternatives identified"
      ;;
    *azurecr.io/*)
      public_alternatives+=("docker.io/${image_name}:${tag}")
      public_alternatives+=("ghcr.io/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Azure Container Registry alternatives identified"
      ;;
    istio/*|docker.io/istio/*|gcr.io/istio-release/*)
      public_alternatives+=("gcr.io/istio-release/${image_name}:${tag}")
      public_alternatives+=("docker.io/istio/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Istio registry alternatives identified"
      ;;
    bitnami/*)
      public_alternatives+=("docker.io/bitnami/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Bitnami alternatives identified"
      ;;
    public.ecr.aws/*)
      # Try Docker Hub as alternative for AWS public ECR
      public_alternatives+=("docker.io/${image_name}:${tag}")
      public_alternatives+=("docker.io/amazon/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "AWS Public ECR alternatives identified"
      ;;
    *)
      public_alternatives+=("docker.io/${image_name_tag}")
      public_alternatives+=("docker.io/library/${image_name}:${tag}")
      log_processing_step "fallback_mapping" "$source_image" "Generic Docker Hub alternatives identified"
      ;;
  esac
  
  log_processing_step "fallback_alternatives" "$source_image" "Found ${#public_alternatives[@]} alternative registries to try"
  
  # Try each public alternative
  local fallback_start_time=$(date +%s)
  for alt_image in "${public_alternatives[@]:-}"; do
    log_processing_step "fallback_attempt" "$source_image" "Trying alternative: ${alt_image}"
    
    local attempt_start_time=$(date +%s)
    if docker pull "${alt_image}" 2>/dev/null; then
      local attempt_end_time=$(date +%s)
      log_performance_metrics "fallback_pull_success" "$attempt_start_time" "$attempt_end_time" "Alternative: ${alt_image}"
      log_authentication_attempt "$source_image" "public_registry_${alt_image}" "success"
      
      # Tag the alternative image with the original name
      if docker tag "${alt_image}" "${source_image}"; then
        log_processing_step "fallback_success" "$source_image" "Successfully tagged alternative as original image"
        local fallback_end_time=$(date +%s)
        log_performance_metrics "total_fallback_operation" "$fallback_start_time" "$fallback_end_time" "Successful fallback to ${alt_image}"
        return 0
      else
        log_processing_step "fallback_tag_failed" "$source_image" "Failed to tag alternative image"
      fi
    else
      local attempt_end_time=$(date +%s)
      log_performance_metrics "fallback_pull_failed" "$attempt_start_time" "$attempt_end_time" "Alternative: ${alt_image}"
      log_authentication_attempt "$source_image" "public_registry_${alt_image}" "failed"
    fi
  done
  
  local fallback_end_time=$(date +%s)
  log_performance_metrics "total_fallback_operation_failed" "$fallback_start_time" "$fallback_end_time" "All alternatives failed"
  log_processing_step "fallback_exhausted" "$source_image" "All public registry alternatives failed"
  
  return 1
}

# Get fallback image reference for multi-arch operations
get_fallback_image_reference() {
  local source_image="$1"
  local result_var="$2"
  
  log_processing_step "fallback_reference_lookup" "$source_image" "Finding appropriate fallback image reference"
  
  # Extract image name and tag
  local image_name_tag=$(echo "${source_image}" | sed 's|^[^/]*/||' | sed 's|^[^/]*/||')
  local image_name=$(echo "${image_name_tag}" | cut -d: -f1)
  local tag=$(echo "${image_name_tag}" | cut -d: -f2)
  
  # Common public registry mappings for buildx imagetools (must be accessible registries)
  local fallback_alternatives=()
  
  case "${source_image}" in
    registry.k8s.io/*)
      fallback_alternatives+=("k8s.gcr.io/${image_name_tag}")
      fallback_alternatives+=("docker.io/library/${image_name}:${tag}")
      ;;
    ghcr.io/dexidp/*)
      fallback_alternatives+=("docker.io/dexidp/${image_name}:${tag}")
      fallback_alternatives+=("quay.io/dexidp/${image_name}:${tag}")
      ;;
    ghcr.io/*)
      fallback_alternatives+=("docker.io/${image_name}:${tag}")
      fallback_alternatives+=("quay.io/${image_name}:${tag}")
      ;;
    *azurecr.io/*)
      fallback_alternatives+=("docker.io/${image_name}:${tag}")
      fallback_alternatives+=("ghcr.io/${image_name}:${tag}")
      ;;
    istio/*|docker.io/istio/*|gcr.io/istio-release/*)
      fallback_alternatives+=("gcr.io/istio-release/${image_name}:${tag}")
      fallback_alternatives+=("docker.io/istio/${image_name}:${tag}")
      ;;
    bitnami/*)
      fallback_alternatives+=("docker.io/bitnami/${image_name}:${tag}")
      ;;
    public.ecr.aws/*)
      # For AWS public ECR, try Docker Hub alternatives
      fallback_alternatives+=("docker.io/library/${image_name}:${tag}")
      fallback_alternatives+=("docker.io/${image_name}:${tag}")
      ;;
    *)
      fallback_alternatives+=("docker.io/${image_name_tag}")
      fallback_alternatives+=("docker.io/library/${image_name}:${tag}")
      ;;
  esac
  
  log_processing_step "fallback_reference_alternatives" "$source_image" "Found ${#fallback_alternatives[@]} potential fallback references"
  
  # Test each alternative to see if it's accessible for buildx imagetools
  for alt_image in "${fallback_alternatives[@]:-}"; do
    log_processing_step "fallback_reference_test" "$source_image" "Testing accessibility: ${alt_image}"
    
    # Test if the alternative image is accessible for buildx imagetools
    if docker buildx imagetools inspect "$alt_image" &>/dev/null; then
      log_processing_step "fallback_reference_success" "$source_image" "Found accessible fallback: ${alt_image}"
      eval "$result_var='$alt_image'"
      return 0
    else
      log_processing_step "fallback_reference_failed" "$source_image" "Alternative not accessible: ${alt_image}"
    fi
  done
  
  log_processing_step "fallback_reference_exhausted" "$source_image" "No accessible fallback references found"
  return 1
}

# Enhanced error analysis and classification system for better handling and decision making
analyze_copy_error() {
  local error_output="$1"
  local source_image="$2"
  
  log_processing_step "error_analysis" "$source_image" "Analyzing error output for classification"
  
  # Convert to lowercase for easier matching
  local error_lower=$(echo "$error_output" | tr '[:upper:]' '[:lower:]')
  
  # Initialize structured error information
  local error_type=""
  local error_category=""
  local recoverable="false"
  local retry_recommended="false"
  local fallback_recommended="false"
  local suggested_action=""
  local retry_delay="0"
  local max_retries="0"
  
  # Authentication errors - Enhanced detection and classification
  if [[ "$error_lower" =~ (unauthorized|authentication.*required|authentication.*failed|denied|forbidden|401|403|login.*required|credential.*not.*found|credential.*invalid|no.*basic.*auth|pull.*access.*denied.*repository.*does.*not.*exist) ]]; then
    error_type="AUTH_ERROR"
    error_category="AUTHENTICATION"
    recoverable="true"
    retry_recommended="false"  # Don't retry auth errors without fixing credentials
    fallback_recommended="true"
    suggested_action="Try credential refresh or public registry fallback"
    max_retries="2"  # Limited retries for auth issues
    
    # Specific authentication sub-types
    if [[ "$error_lower" =~ (credential.*not.*found|login.*required) ]]; then
      suggested_action="Configure Docker credentials or use public registry alternative"
    elif [[ "$error_lower" =~ (pull.*access.*denied.*repository.*does.*not.*exist) ]]; then
      suggested_action="Check repository exists or try public registry alternative"
    elif [[ "$error_lower" =~ (unauthorized.*incorrect.*username.*password) ]]; then
      suggested_action="Verify Docker registry credentials and refresh login"
    fi
    
    log_debug "Error classified as AUTH_ERROR for $source_image: $suggested_action"
    
  # Network errors - Enhanced detection with retry logic
  elif [[ "$error_lower" =~ (timeout|connection.*refused|connection.*reset|connection.*timed.*out|network.*unreachable|dns.*resolution.*failed|temporary.*failure.*in.*name.*resolution|dial.*tcp.*timeout|i/o.*timeout|net/http.*timeout) ]]; then
    error_type="NETWORK_ERROR"
    error_category="NETWORK"
    recoverable="true"
    retry_recommended="true"
    fallback_recommended="false"
    retry_delay="2"  # Start with 2 second delay
    max_retries="3"
    
    # Specific network sub-types
    if [[ "$error_lower" =~ (dns.*resolution.*failed|temporary.*failure.*in.*name.*resolution) ]]; then
      suggested_action="Check DNS configuration and network connectivity"
      retry_delay="5"  # Longer delay for DNS issues
    elif [[ "$error_lower" =~ (connection.*refused|connection.*reset) ]]; then
      suggested_action="Check registry availability and firewall settings"
    elif [[ "$error_lower" =~ (timeout|dial.*tcp.*timeout|i/o.*timeout) ]]; then
      suggested_action="Retry with exponential backoff due to network timeout"
    else
      suggested_action="Retry operation with network backoff"
    fi
    
    log_debug "Error classified as NETWORK_ERROR for $source_image: $suggested_action"
    
  # Image not found errors - Enhanced detection
  elif [[ "$error_lower" =~ (not.*found|does.*not.*exist|no.*such.*image|404.*not.*found|manifest.*not.*found|tag.*does.*not.*exist|repository.*does.*not.*exist.*or.*may.*require.*docker.*login) ]]; then
    error_type="IMAGE_NOT_FOUND"
    error_category="RESOURCE"
    recoverable="true"
    retry_recommended="false"
    fallback_recommended="true"
    suggested_action="Try public registry alternatives or verify image name/tag"
    
    # Specific image not found sub-types
    if [[ "$error_lower" =~ (tag.*does.*not.*exist|manifest.*not.*found) ]]; then
      suggested_action="Verify image tag exists or try latest tag"
    elif [[ "$error_lower" =~ (repository.*does.*not.*exist.*or.*may.*require.*docker.*login) ]]; then
      suggested_action="Check repository name or try authentication"
      recoverable="true"
      fallback_recommended="true"
    fi
    
    log_debug "Error classified as IMAGE_NOT_FOUND for $source_image: $suggested_action"
    
  # Docker daemon errors - Enhanced detection
  elif [[ "$error_lower" =~ (daemon|docker.*not.*running|cannot.*connect.*to.*the.*docker.*daemon|docker.*socket|docker.*engine.*is.*not.*running|is.*the.*docker.*daemon.*running) ]]; then
    error_type="DAEMON_ERROR"
    error_category="SYSTEM"
    recoverable="false"  # Requires manual intervention
    retry_recommended="false"
    fallback_recommended="false"
    suggested_action="Start Docker daemon and verify Docker installation"
    
    log_debug "Error classified as DAEMON_ERROR for $source_image: $suggested_action"
    
  # Buildx specific errors - Enhanced detection and handling
  elif [[ "$error_lower" =~ (buildx|builder.*not.*found|buildkit|docker.*buildx.*not.*found|buildx.*command.*not.*found|no.*builder.*instance|builder.*instance.*not.*found) ]]; then
    error_type="BUILDX_ERROR"
    error_category="BUILDX"
    recoverable="false"  # Should not fallback silently, requires proper setup
    retry_recommended="false"
    fallback_recommended="false"  # Don't fallback for buildx issues - exit with error
    suggested_action="Install Docker buildx or use alternative multi-arch method"
    
    # Specific buildx sub-types
    if [[ "$error_lower" =~ (buildx.*command.*not.*found|docker.*buildx.*not.*found) ]]; then
      suggested_action="Install Docker buildx plugin: docker buildx install"
    elif [[ "$error_lower" =~ (no.*builder.*instance|builder.*instance.*not.*found) ]]; then
      suggested_action="Create buildx builder: docker buildx create --use"
    elif [[ "$error_lower" =~ (buildkit) ]]; then
      suggested_action="Check BuildKit daemon status and configuration"
    fi
    
    log_debug "Error classified as BUILDX_ERROR for $source_image: $suggested_action"
    
  # Registry/repository errors - Enhanced detection
  elif [[ "$error_lower" =~ (registry.*error|repository.*not.*found|invalid.*reference|invalid.*repository.*name|registry.*does.*not.*support.*docker.*schema.*version) ]]; then
    error_type="REGISTRY_ERROR"
    error_category="REGISTRY"
    recoverable="true"
    retry_recommended="true"
    fallback_recommended="true"
    suggested_action="Verify registry URL and try alternative registries"
    max_retries="2"
    
    log_debug "Error classified as REGISTRY_ERROR for $source_image: $suggested_action"
    
  # Manifest errors - Enhanced detection
  elif [[ "$error_lower" =~ (manifest.*unknown|unsupported.*manifest|invalid.*manifest|manifest.*invalid|unsupported.*media.*type|unknown.*manifest) ]]; then
    error_type="MANIFEST_ERROR"
    error_category="MANIFEST"
    recoverable="true"
    retry_recommended="false"
    fallback_recommended="true"
    suggested_action="Try alternative registry or single-arch fallback"
    
    log_debug "Error classified as MANIFEST_ERROR for $source_image: $suggested_action"
    
  # Rate limiting - Enhanced detection and handling
  elif [[ "$error_lower" =~ (rate.*limit|too.*many.*requests|429|quota.*exceeded|api.*rate.*limit.*exceeded) ]]; then
    error_type="RATE_LIMIT_ERROR"
    error_category="RATE_LIMIT"
    recoverable="true"
    retry_recommended="true"
    fallback_recommended="false"
    suggested_action="Wait and retry with exponential backoff"
    
    # Enhanced retry for critical AWS images
    if [[ "$source_image" =~ (public\.ecr\.aws.*cloudwatch-agent|public\.ecr\.aws.*aws-for-fluent-bit) ]]; then
      retry_delay="30"  # Enhanced delay for critical AWS images
      max_retries="3"   # Enhanced retries for critical AWS images
      suggested_action="Wait and retry with enhanced backoff for critical AWS image"
    else
      retry_delay="20"  # Standard delay for rate limits
      max_retries="2"   # Standard retries for non-critical images
    fi
    
    log_debug "Error classified as RATE_LIMIT_ERROR for $source_image: $suggested_action"
    
  # Disk space errors - New detection
  elif [[ "$error_lower" =~ (no.*space.*left|disk.*full|insufficient.*storage|write.*error.*no.*space) ]]; then
    error_type="DISK_SPACE_ERROR"
    error_category="SYSTEM"
    recoverable="false"
    retry_recommended="false"
    fallback_recommended="false"
    suggested_action="Free up disk space and retry operation"
    
    log_debug "Error classified as DISK_SPACE_ERROR for $source_image: $suggested_action"
    
  # Permission errors - New detection
  elif [[ "$error_lower" =~ (permission.*denied|access.*denied|operation.*not.*permitted) ]]; then
    error_type="PERMISSION_ERROR"
    error_category="SYSTEM"
    recoverable="false"
    retry_recommended="false"
    fallback_recommended="false"
    suggested_action="Check file/directory permissions and user privileges"
    
    log_debug "Error classified as PERMISSION_ERROR for $source_image: $suggested_action"
    
  # Unknown error - Enhanced with more context
  else
    error_type="UNKNOWN_ERROR"
    error_category="UNKNOWN"
    recoverable="true"  # Assume recoverable for unknown errors
    retry_recommended="true"
    fallback_recommended="true"
    suggested_action="Review error details and try alternative approaches"
    max_retries="1"
    
    log_debug "Error classified as UNKNOWN_ERROR for $source_image: $suggested_action"
  fi
  
  # Return structured error information as a formatted string
  # Format: ERROR_TYPE|CATEGORY|RECOVERABLE|RETRY_RECOMMENDED|FALLBACK_RECOMMENDED|SUGGESTED_ACTION|RETRY_DELAY|MAX_RETRIES
  echo "${error_type}|${error_category}|${recoverable}|${retry_recommended}|${fallback_recommended}|${suggested_action}|${retry_delay}|${max_retries}"
  return 0
}

# Helper function to parse structured error analysis results
parse_error_analysis() {
  local error_analysis="$1"
  local -n result_array=$2
  
  # Parse structured error information
  # Format: ERROR_TYPE|CATEGORY|RECOVERABLE|RETRY_RECOMMENDED|FALLBACK_RECOMMENDED|SUGGESTED_ACTION|RETRY_DELAY|MAX_RETRIES
  IFS='|' read -r result_array[error_type] result_array[error_category] result_array[recoverable] result_array[retry_recommended] result_array[fallback_recommended] result_array[suggested_action] result_array[retry_delay] result_array[max_retries] <<< "$error_analysis"
}

# Enhanced error handling function that uses structured error analysis for decision making
handle_copy_error() {
  local source_image="$1"
  local error_output="$2"
  local current_attempt="$3"
  local max_attempts="$4"
  
  # Analyze the error using enhanced classification
  local error_analysis=$(analyze_copy_error "$error_output" "$source_image")
  
  # Parse structured error information
  declare -A error_info
  parse_error_analysis "$error_analysis" error_info
  
  log_error_analysis "$source_image" "${error_info[error_type]}" "$error_output" "${error_info[suggested_action]}"
  log_processing_step "error_handling" "$source_image" "Category: ${error_info[error_category]}, Recoverable: ${error_info[recoverable]}, Retry: ${error_info[retry_recommended]}, Fallback: ${error_info[fallback_recommended]}"
  
  # Return decision based on error analysis
  # Return codes: 0=retry, 1=fallback, 2=abort
  
  # Non-recoverable errors should abort immediately
  if [[ "${error_info[recoverable]}" == "false" ]]; then
    log_error "Non-recoverable error: ${error_info[suggested_action]}"
    return 2  # Abort
  fi
  
  # Buildx errors should not fallback silently
  if [[ "${error_info[error_type]}" == "BUILDX_ERROR" ]]; then
    log_error "Buildx error: ${error_info[suggested_action]}"
    return 2  # Abort
  fi
  
  # Check if we should retry based on error analysis and attempt count
  if [[ "${error_info[retry_recommended]}" == "true" && $current_attempt -lt $max_attempts ]]; then
    local retry_delay="${error_info[retry_delay]:-5}"
    log_network_retry "operation" "$current_attempt" "$max_attempts" "$retry_delay"
    sleep "$retry_delay"
    return 0  # Retry
  fi
  
  # If retries exhausted or not recommended, check if fallback is recommended
  if [[ "${error_info[fallback_recommended]}" == "true" ]]; then
    log_processing_step "fallback_decision" "$source_image" "Fallback recommended: ${error_info[suggested_action]}"
    return 1  # Fallback
  fi
  
  # No retry or fallback recommended
  log_error "No recovery options available: ${error_info[suggested_action]}"
  return 2  # Abort
}

# Get fallback image reference for multi-arch operations
get_fallback_image_reference() {
  local source_image="$1"
  local result_var="$2"
  
  log_processing_step "fallback_reference_lookup" "$source_image" "Finding appropriate fallback image reference"
  
  # Extract image name and tag
  local image_name_tag=$(echo "${source_image}" | sed 's|^[^/]*/||' | sed 's|^[^/]*/||')
  local image_name=$(echo "${image_name_tag}" | cut -d: -f1)
  local tag=$(echo "${image_name_tag}" | cut -d: -f2)
  
  # Common public registry mappings for buildx imagetools (must be accessible registries)
  local fallback_alternatives=()
  
  case "${source_image}" in
    registry.k8s.io/*)
      fallback_alternatives+=("k8s.gcr.io/${image_name_tag}")
      fallback_alternatives+=("docker.io/library/${image_name}:${tag}")
      ;;
    ghcr.io/dexidp/*)
      fallback_alternatives+=("docker.io/dexidp/${image_name}:${tag}")
      fallback_alternatives+=("quay.io/dexidp/${image_name}:${tag}")
      ;;
    ghcr.io/*)
      fallback_alternatives+=("docker.io/${image_name}:${tag}")
      fallback_alternatives+=("quay.io/${image_name}:${tag}")
      ;;
    *azurecr.io/*)
      fallback_alternatives+=("docker.io/${image_name}:${tag}")
      fallback_alternatives+=("ghcr.io/${image_name}:${tag}")
      ;;
    istio/*|docker.io/istio/*|gcr.io/istio-release/*)
      fallback_alternatives+=("gcr.io/istio-release/${image_name}:${tag}")
      fallback_alternatives+=("docker.io/istio/${image_name}:${tag}")
      ;;
    bitnami/*)
      fallback_alternatives+=("docker.io/bitnami/${image_name}:${tag}")
      ;;
    public.ecr.aws/*)
      # For AWS public ECR, try Docker Hub alternatives
      fallback_alternatives+=("docker.io/library/${image_name}:${tag}")
      fallback_alternatives+=("docker.io/${image_name}:${tag}")
      ;;
    *)
      fallback_alternatives+=("docker.io/${image_name_tag}")
      fallback_alternatives+=("docker.io/library/${image_name}:${tag}")
      ;;
  esac
  
  log_processing_step "fallback_reference_alternatives" "$source_image" "Found ${#fallback_alternatives[@]} potential fallback references"
  
  # Test each alternative to see if it's accessible for buildx imagetools
  for alt_image in "${fallback_alternatives[@]:-}"; do
    log_processing_step "fallback_reference_test" "$source_image" "Testing accessibility: ${alt_image}"
    
    # Test if the alternative image is accessible for buildx imagetools
    if docker buildx imagetools inspect "$alt_image" &>/dev/null; then
      log_processing_step "fallback_reference_success" "$source_image" "Found accessible fallback: ${alt_image}"
      eval "$result_var='$alt_image'"
      return 0
    else
      log_processing_step "fallback_reference_failed" "$source_image" "Alternative not accessible: ${alt_image}"
    fi
  done
  
  log_processing_step "fallback_reference_exhausted" "$source_image" "No accessible fallback references found"
  return 1
}

# Enhanced image inspection with multiple fallback methods
# Process and push multi-architecture container image using buildx imagetools
process_multiarch_image() {
  local source_image="$1"
  local max_retries=2  # Reduced from 3 to 2 for faster processing
  local retry_delay=10
  
  # Enhanced retry logic for critical AWS images
  if [[ "$source_image" =~ (cloudwatch-agent|aws-for-fluent-bit) ]]; then
    max_retries=3  # Enhanced retries for critical AWS images
    retry_delay=20  # Longer delays to avoid rate limits
    log_processing_step "critical_aws_image" "$source_image" "Using enhanced retry logic for critical AWS image"
  fi
  
  log_multiarch_start "$source_image" "multiarch_processing"
  
  # Parse image components
  local image_name tag repo_name
  if [[ "$source_image" =~ ^(.+):(.+)$ ]]; then
    image_name="${BASH_REMATCH[1]}"
    tag="${BASH_REMATCH[2]}"
  else
    image_name="$source_image"
    tag="latest"
  fi
  
  repo_name=$(get_ecr_repo_name_for_image "$source_image")
  local ecr_image="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repo_name}:${tag}"
  
  log_processing_step "image_parsing" "$source_image" "Parsed to ECR target: $ecr_image"
  
  # Check if image already exists and skip if not forcing update
  if [[ "$FORCE_UPDATE" == false ]] && image_exists_in_ecr "$repo_name" "$tag"; then
    log_multiarch_decision "$source_image" "SKIP_EXISTING" "Image already exists in ECR and force update is disabled"
    PROCESSED_IMAGES+=("$source_image -> $ecr_image (already exists)")
    end_operation_timer "multiarch_processing"
    return 0
  fi
  
  # If force update is enabled and repo exists, clean up any untagged images that might cause conflicts
  if [[ "$FORCE_UPDATE" == true ]]; then
    local untagged_images
    untagged_images=$(aws ecr list-images --region "$REGION" --repository-name "$repo_name" --filter tagStatus=UNTAGGED --query 'imageIds[*]' --output json 2>/dev/null || echo "[]")
    if [[ "$untagged_images" != "[]" ]] && [[ "$untagged_images" != "" ]]; then
      log_info "Cleaning up untagged images in $repo_name to avoid conflicts..."
      aws ecr batch-delete-image --region "$REGION" --repository-name "$repo_name" --image-ids "$untagged_images" >/dev/null 2>&1 || true
    fi
  fi
  
  # Create ECR repository
  log_processing_step "repository_creation" "$source_image" "Creating ECR repository: $repo_name"
  if ! create_repository "$repo_name" "image"; then
    log_error_analysis "$source_image" "REPOSITORY_CREATION_FAILED" "Failed to create ECR repository" "Check AWS permissions and repository naming"
    FAILED_IMAGES+=("$source_image (repository creation failed)")
    end_operation_timer "multiarch_processing"
    return 1
  fi
  
  # Add a small delay when using templates to ensure repository is fully initialized
  if [[ "$USE_CREATION_TEMPLATES" == true ]]; then
    log_processing_step "repository_initialization" "$source_image" "Waiting for repository initialization (templates)"
    sleep 5
  fi
  
  log_processing_step "multiarch_processing_start" "$source_image" "Starting multi-arch processing pipeline"
  
  # Authenticate to source registry if needed (private ECR, Harbor, etc.)
  if ! authenticate_source_registry "$source_image"; then
    log_warning "⚠️  Source registry authentication failed for: $source_image"
    SKIPPED_AUTH_IMAGES+=("$source_image")
    SKIPPED_IMAGES+=("$source_image (source registry auth failed)")
    end_operation_timer "multiarch_processing"
    return 0
  fi
  
  # Check if Docker buildx is available for multi-arch support
  if ! command -v docker &> /dev/null || ! docker buildx version &> /dev/null; then
    log_multiarch_fallback "$source_image" "buildx_multiarch" "single_arch_docker" "Docker buildx not available"
    process_image "$source_image" "true"  # Pass true to indicate fallback
    end_operation_timer "multiarch_processing"
    return $?
  fi
  
  # Use enhanced inspection to check architectures
  log_processing_step "architecture_inspection" "$source_image" "Inspecting image architecture"
  local inspection_result
  if ! inspection_result=$(enhanced_inspect_image "$source_image"); then
    log_error_analysis "$source_image" "INSPECTION_FAILED" "Failed to inspect source image architecture" "Check image availability and Docker daemon"
    FAILED_IMAGES+=("$source_image (inspection failed)")
    end_operation_timer "multiarch_processing"
    return 1
  fi
  
  # Parse inspection results
  local inspection_lines=($inspection_result)
  local arch_count="${inspection_lines[0]}"
  # Strip any newlines from arch_count to avoid syntax errors in comparisons
  arch_count=$(echo "$arch_count" | tr -d '\n' | tr -d '\r')
  local platforms=("${inspection_lines[@]:1}")
  
  # Check if the image has multiple architectures
  if [[ $arch_count -le 1 ]]; then
    log_multiarch_decision "$source_image" "FALLBACK_TO_SINGLE_ARCH" "Source image has only $arch_count architecture"
    track_multiarch_fallback "$source_image" "single_architecture_detected"
    process_image "$source_image" "false"  # Not a failure fallback, just single-arch
    end_operation_timer "multiarch_processing"
    return $?
  fi
  
  log_multiarch_decision "$source_image" "PROCEED_WITH_MULTIARCH" "Confirmed multi-arch image with $arch_count architectures: ${platforms[*]:-}"
  
  # For templates, use two-step approach: push individual archs first, then create manifest
  if [[ "$USE_CREATION_TEMPLATES" == true ]]; then
    log_processing_step "template_workaround" "$source_image" "Using two-step push for template compatibility"
    
    local -a arch_images=()
    local two_step_success=true
    
    # Step 1: Push each architecture individually
    for platform in "${platforms[@]}"; do
      # Skip manifest types
      if [[ "$platform" =~ ^application/ ]]; then
        continue
      fi
      
      # Skip unknown/unknown platforms that can't be pulled
      if [[ "$platform" == "unknown/unknown" ]]; then
        log_warning "  ⊘ Skipping unknown/unknown platform (not pullable)"
        continue
      fi
      
      local arch_tag="${tag}-${platform//\//-}"
      local ecr_arch_image="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repo_name}:${arch_tag}"
      
      log_processing_step "arch_push" "$source_image" "Pushing $platform"
      
      # Pull and push this architecture
      if docker pull --platform "$platform" "$source_image" >/dev/null 2>&1; then
        docker tag "$source_image" "$ecr_arch_image" >/dev/null 2>&1
        if docker push "$ecr_arch_image" >/dev/null 2>&1; then
          arch_images+=("$ecr_arch_image")
          log_success "  ✓ Pushed $platform"
          
          # If this is the first architecture pushed with templates, wait for repo to be fully ready
          if [[ "$USE_CREATION_TEMPLATES" == true ]] && [[ ${#arch_images[@]} -eq 1 ]]; then
            log_info "Waiting 3s for ECR repository to be fully initialized..."
            sleep 3
          fi
        else
          log_warning "  ✗ Failed to push $platform"
          # Don't break - continue with other architectures
        fi
      else
        log_warning "  ✗ Failed to pull $platform"
        # Don't break - continue with other architectures
      fi
    done
    
    # Step 2: If ANY archs pushed successfully, create manifest from them
    if [[ ${#arch_images[@]} -gt 0 ]]; then
      log_processing_step "manifest_create" "$source_image" "Creating manifest from ${#arch_images[@]} successfully pushed architectures"
      
      # If force update is enabled, delete existing manifest tag only
      # Don't delete arch-specific tags yet - they'll be cleaned up after success or by next run's cleanup
      if [[ "$FORCE_UPDATE" == true ]]; then
        # Delete main tag
        if aws ecr batch-delete-image --region "$REGION" --repository-name "$repo_name" --image-ids imageTag="$tag" >/dev/null 2>&1; then
          log_info "Deleted existing image tag: $tag (force update enabled)"
        fi
      fi
      
      if docker buildx imagetools create --tag "$ecr_image" "${arch_images[@]}" >/dev/null 2>&1; then
        log_success "Successfully created multi-arch manifest using two-step approach"
        PROCESSED_IMAGES+=("$source_image -> $ecr_image (multi-arch, two-step)")
        MULTIARCH_IMAGES+=("$source_image -> $ecr_image (two-step)")
        track_multiarch_success "$source_image" "${platforms[*]:-}"
        
        # Note: Architecture-specific tags cannot be deleted as they're referenced by the manifest list
        # This is expected ECR behavior for multi-arch images
        
        # Clean up local docker images
        for arch_img in "${arch_images[@]}"; do
          docker rmi "$arch_img" >/dev/null 2>&1 || true
        done
        
        end_operation_timer "multiarch_processing"
        return 0
      else
        log_warning "Two-step manifest creation failed, falling back to direct copy"
        # Clean up
        for arch_img in "${arch_images[@]}"; do
          docker rmi "$arch_img" >/dev/null 2>&1 || true
        done
      fi
    else
      log_warning "Two-step architecture push failed, falling back to direct copy"
    fi
  fi
  
  # Use buildx imagetools to copy the multi-arch image preserving all architectures
  local copy_success=false
  local copy_start_time=$(date +%s)
  local effective_source_image="$source_image"  # Track which image to use for copying
  local fallback_used=false
  
  # If force update is enabled, delete existing manifest tag before direct copy
  if [[ "$FORCE_UPDATE" == true ]]; then
    if aws ecr batch-delete-image --region "$REGION" --repository-name "$repo_name" --image-ids imageTag="$tag" >/dev/null 2>&1; then
      log_info "Deleted existing image tag: $tag for direct copy (force update enabled)"
    fi
  fi
  
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    log_processing_step "multiarch_copy_attempt" "$source_image" "Attempt $attempt/$max_retries using buildx imagetools"
    
    local attempt_start_time=$(date +%s)
    if docker buildx imagetools create --tag "$ecr_image" "$effective_source_image" 2>/dev/null; then
      local attempt_end_time=$(date +%s)
      log_performance_metrics "multiarch_copy_success" "$attempt_start_time" "$attempt_end_time" "Attempt $attempt - Success"
      if [[ "$fallback_used" == "true" ]]; then
        log_success "Successfully copied multi-arch image from fallback: $ecr_image"
        PROCESSED_IMAGES+=("$source_image -> $ecr_image (multi-arch from fallback)")
        MULTIARCH_IMAGES+=("$source_image -> $ecr_image (from fallback)")
      else
        log_success "Successfully copied multi-arch image: $ecr_image"
        PROCESSED_IMAGES+=("$source_image -> $ecr_image (multi-arch)")
        MULTIARCH_IMAGES+=("$source_image -> $ecr_image")
      fi
      track_multiarch_success "$source_image" "${platforms[*]:-}"
      copy_success=true
      
      # Note: Architecture-specific tags from two-step approach cannot be deleted
      # as they're referenced by the manifest list. This is expected ECR behavior.
      
      break
    else
      local attempt_end_time=$(date +%s)
      local error_output=$(docker buildx imagetools create --tag "$ecr_image" "$effective_source_image" 2>&1 || true)
      
      log_performance_metrics "multiarch_copy_failed" "$attempt_start_time" "$attempt_end_time" "Attempt $attempt - Failed"
      
      # Analyze the error using enhanced error classification
      local error_analysis=$(analyze_copy_error "$error_output" "$source_image")
      
      # Parse structured error information
      # Format: ERROR_TYPE|CATEGORY|RECOVERABLE|RETRY_RECOMMENDED|FALLBACK_RECOMMENDED|SUGGESTED_ACTION|RETRY_DELAY|MAX_RETRIES
      IFS='|' read -r error_type error_category recoverable retry_recommended fallback_recommended suggested_action error_retry_delay error_max_retries <<< "$error_analysis"
      
      log_error_analysis "$source_image" "$error_type" "$error_output" "$suggested_action"
      log_processing_step "error_classification" "$source_image" "Category: $error_category, Recoverable: $recoverable, Retry: $retry_recommended, Fallback: $fallback_recommended"
      
      # Handle errors based on structured analysis
      if [[ "$error_type" == "AUTH_ERROR" || "$error_type" == "RATE_LIMIT_ERROR" ]] && [[ "$fallback_recommended" == "true" || "$fallback_used" == "false" ]]; then
        log_authentication_attempt "$source_image" "public_registry_fallback" "attempting"
        
        # Get the fallback image reference that we should use for copying
        local fallback_image_ref=""
        if get_fallback_image_reference "$source_image" "fallback_image_ref"; then
          log_authentication_attempt "$source_image" "public_registry_fallback" "success"
          log_processing_step "fallback_integration" "$source_image" "Using fallback image for multi-arch copy: $fallback_image_ref"
          
          # Update the effective source image to use the fallback
          effective_source_image="$fallback_image_ref"
          fallback_used=true
          
          # Continue with the retry loop using the fallback image
          continue
        else
          log_authentication_attempt "$source_image" "public_registry_fallback" "failed"
        fi
      elif [[ "$error_type" == "BUILDX_ERROR" ]]; then
        # For buildx errors, don't retry or fallback - exit with clear error
        log_error "Buildx error detected: $suggested_action"
        log_multiarch_fallback "$source_image" "buildx_multiarch" "exit_with_error" "Buildx not available or misconfigured"
        FAILED_IMAGES+=("$source_image (buildx error: $suggested_action)")
        end_operation_timer "multiarch_processing"
        return 1
      elif [[ "$error_type" == "NETWORK_ERROR" && "$retry_recommended" == "true" ]]; then
        # Use error-specific retry delay if provided
        local current_retry_delay="${error_retry_delay:-$retry_delay}"
        log_network_retry "multiarch_copy" "$attempt" "$max_retries" "$current_retry_delay"
        # Continue to retry logic below
      elif [[ "$recoverable" == "false" ]]; then
        # Non-recoverable errors should not be retried
        log_error "Non-recoverable error detected: $suggested_action"
        FAILED_IMAGES+=("$source_image ($error_type: $suggested_action)")
        end_operation_timer "multiarch_processing"
        return 1
      fi
      
      if [[ $attempt -lt $max_retries ]]; then
        log_network_retry "multiarch_copy" "$attempt" "$max_retries" "$retry_delay"
        sleep $retry_delay
      fi
    fi
  done
  
  # After all retry attempts, check if copy was successful
  if [[ "$copy_success" != "true" ]]; then
    # Before falling back to single-arch, check if manifests were pushed but just not tagged
    log_info "🔍 Checking for partial success (untagged manifests in ECR)..."
    
    local partial_digest
    if partial_digest=$(detect_partial_copy_success "$repo_name" "$tag"); then
      log_info "✅ Found untagged multi-arch manifest in ECR: $partial_digest"
      
      # Attempt to tag the existing manifest
      if recover_untagged_manifest "$repo_name" "$partial_digest" "$tag"; then
        log_success "🎉 Successfully recovered from partial failure by tagging existing manifest"
        MULTIARCH_IMAGES+=("$source_image -> $ecr_image (multi-arch, recovered)")
        PROCESSED_IMAGES+=("$source_image -> $ecr_image (multi-arch, recovered)")
        track_multiarch_success "$source_image" "${platforms[*]:-}"
        
        # Verify the tagged image
        local verification_start_time=$(date +%s)
        if docker buildx imagetools inspect "$ecr_image" >/dev/null 2>&1; then
          local verification_end_time=$(date +%s)
          log_performance_metrics "multiarch_verification" "$verification_start_time" "$verification_end_time" "Verification completed"
          log_success "✅ Multi-arch preservation verified after recovery"
        fi
        
        end_operation_timer "multiarch_processing"
        return 0
      else
        log_warning "⚠️  Recovery failed, manifest exists but couldn't be tagged"
        log_info "💡 Manual tagging commands:"
        log_info "   manifest=\$(aws ecr batch-get-image --repository-name $repo_name --region $REGION \\"
        log_info "     --image-ids imageDigest=$partial_digest --query 'images[0].imageManifest' --output text)"
        log_info "   aws ecr put-image --repository-name $repo_name --region $REGION \\"
        log_info "     --image-tag $tag --image-manifest \"\$manifest\""
        PARTIAL_SUCCESS_IMAGES+=("$source_image -> $repo_name@$partial_digest (needs manual tagging)")
      fi
    fi
    
    # If no partial success or recovery failed, fall back to single-arch
    log_multiarch_fallback "$source_image" "buildx_multiarch" "single_arch_docker" "All multi-arch copy attempts failed after $max_retries retries"
    process_image "$source_image" "true"  # Pass true to indicate fallback from failure
    end_operation_timer "multiarch_processing"
    return $?
  fi
  
  local copy_end_time=$(date +%s)
  log_performance_metrics "total_multiarch_copy" "$copy_start_time" "$copy_end_time" "Complete multi-arch copy operation"
  
  # Verify the copied image
  log_processing_step "multiarch_verification" "$source_image" "Verifying multi-arch preservation in ECR"
  local verification_start_time=$(date +%s)
  
  if docker buildx imagetools inspect "$ecr_image" &>/dev/null; then
    local copied_arch_count=$(docker buildx imagetools inspect "$ecr_image" 2>/dev/null | grep -c "Platform:" || echo "0")
    local copied_platforms=$(docker buildx imagetools inspect "$ecr_image" 2>/dev/null | grep "Platform:" | awk '{print $2}' | tr '\n' ' ')
    
    local verification_end_time=$(date +%s)
    log_performance_metrics "multiarch_verification" "$verification_start_time" "$verification_end_time" "Verification completed"
    
    if [[ $copied_arch_count -eq $arch_count ]]; then
      log_multiarch_verification "$ecr_image" "${platforms[*]:-}" "$copied_platforms" "success"
    else
      log_multiarch_verification "$ecr_image" "${platforms[*]:-}" "$copied_platforms" "partial_success"
      log_warning "Architecture count mismatch: expected $arch_count, got $copied_arch_count"
    fi
  else
    local verification_end_time=$(date +%s)
    log_performance_metrics "multiarch_verification_failed" "$verification_start_time" "$verification_end_time" "Verification failed"
    log_multiarch_verification "$ecr_image" "${platforms[*]:-}" "unknown" "failed"
  fi
  
  end_operation_timer "multiarch_processing"
  return 0
}

# Process and push container image (single-arch fallback)
process_image() {
  local source_image="$1"
  local is_fallback="${2:-false}"  # New parameter to indicate if this is a fallback from multi-arch failure
  local max_retries=3
  local retry_delay=10
  
  # Parse image components
  local image_name tag repo_name
  if [[ "$source_image" =~ ^(.+):(.+)$ ]]; then
    image_name="${BASH_REMATCH[1]}"
    tag="${BASH_REMATCH[2]}"
  else
    log_error "Invalid image format: $source_image"
    return 1
  fi
  
  # Use the simplified ECR repository name function
  repo_name=$(get_ecr_repo_name_for_image "$source_image")
  local ecr_image="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${repo_name}:${tag}"
  
  # Check if image already exists and skip if not forcing update
  # BUT: Don't skip if this is a fallback from failed multi-arch processing
  if [[ "$FORCE_UPDATE" == false ]] && [[ "$is_fallback" == "false" ]] && image_exists_in_ecr "$repo_name" "$tag"; then
    log_info "Image already exists in ECR: $repo_name:$tag (skipping)"
    PROCESSED_IMAGES+=("$source_image -> $ecr_image (already exists)")
    return 0
  fi
  
  # Create ECR repository
  if ! create_repository "$repo_name" "image"; then
    FAILED_IMAGES+=("$source_image (repository creation failed)")
    return 1
  fi
  
  log_info "Processing image: $source_image -> $ecr_image"
  
  # Authenticate to source registry if needed (private ECR, Harbor, etc.)
  if ! authenticate_source_registry "$source_image"; then
    log_warning "⚠️  Source registry authentication failed for: $source_image"
    PROCESSED_IMAGES+=("$source_image -> SKIPPED (source registry auth failed)")
    SKIPPED_AUTH_IMAGES+=("$source_image")
    SKIPPED_IMAGES+=("$source_image (source registry auth failed)")
    return 0
  fi
  
  # Try to pull the original image first with authentication fallback
  local pull_success=false
  
  for ((attempt=1; attempt<=max_retries; attempt++)); do
    if docker pull "$source_image" 2>/dev/null; then
      log_success "Pulled image: $source_image (attempt $attempt)"
      pull_success=true
      break
    else
      local error_output=$(docker pull "$source_image" 2>&1 || true)
      
      # Check if the error is authentication related
      if [[ "${error_output}" =~ (unauthorized|authentication|denied|forbidden|401|403) ]]; then
        log_warning "Authentication issue detected for ${source_image}"
        log_info "Attempting to find public registry alternative..."
        
        if try_public_image_fallback "${source_image}"; then
          pull_success=true
          break
        else
          log_warning "No public registry alternative found"
        fi
      fi
      
      if [[ $attempt -lt $max_retries ]]; then
        log_warning "Pull attempt $attempt failed for $source_image, retrying in ${retry_delay}s..."
        sleep $retry_delay
      fi
    fi
  done
  
  if [[ "$pull_success" != "true" ]]; then
    log_warning "⚠️  Skipping image (authentication required): $source_image"
    PROCESSED_IMAGES+=("$source_image -> SKIPPED (authentication required)")
    SKIPPED_AUTH_IMAGES+=("$source_image")
    SKIPPED_IMAGES+=("$source_image (authentication required)")
    return 0
  fi
  
  # Tag and push image with retry logic
  local push_success=false
  for ((push_attempt=1; push_attempt<=2; push_attempt++)); do
    if docker tag "$source_image" "$ecr_image" && \
       docker push "$ecr_image" 2>/dev/null; then
      log_success "Pushed image: $ecr_image"
      PROCESSED_IMAGES+=("$source_image -> $ecr_image")
      SINGLEARCH_IMAGES+=("$source_image -> $ecr_image")
      push_success=true
      break
    else
      if [[ $push_attempt -eq 1 ]]; then
        log_warning "Push attempt $push_attempt failed for $ecr_image, retrying..."
        sleep 5
      fi
    fi
  done
  
  if [[ "$push_success" == false ]]; then
    log_error "Failed to tag/push image after 2 attempts: $source_image"
    FAILED_IMAGES+=("$source_image (push failed)")
    return 1
  fi
  
  # Cleanup local image if requested
  if [[ "$CLEANUP_FILES" == true ]]; then
    docker rmi "$source_image" "$ecr_image" 2>/dev/null || true
  fi
  
  return 0
}

# Process Helm chart dependencies automatically
process_chart_dependencies() {
  local chart_dir="$1"
  local chart_name="$2"
  
  if [[ ! -f "$chart_dir/Chart.yaml" ]]; then
    return 0
  fi
  
  log_info "🔍 Checking for chart dependencies in: $chart_name"
  
  # Extract dependencies with repository URLs (external dependencies only)
  # Uses yq for reliable YAML parsing across platforms (including Windows/Git Bash)
  local chart_deps
  if command -v yq &>/dev/null; then
    chart_deps=$(yq e '.dependencies[] | .name + "|" + .repository + "|" + .version' "$chart_dir/Chart.yaml" 2>/dev/null || true)
  else
    log_warning "   yq not found - falling back to awk for dependency parsing"
    chart_deps=$(awk '
      BEGIN { in_deps = 0; name = ""; repo = ""; version = "" }
      /^dependencies:/ { in_deps = 1; next }
      /^[a-zA-Z]/ && in_deps { in_deps = 0 }
      in_deps && /^[[:space:]]*-[[:space:]]/ {
        if (name != "" && repo != "" && version != "") {
          print name "|" repo "|" version
        }
        name = ""; repo = ""; version = ""
        line = $0
        if (line ~ /name:/) { gsub(/^.*name:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); gsub(/\r/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); name = line }
        if (line ~ /repository:/) { gsub(/^.*repository:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); gsub(/\r/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); repo = line }
        if (line ~ /version:/) { gsub(/^.*version:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); gsub(/\r/, "", line); gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); version = line }
        next
      }
      in_deps && /^[[:space:]]*name:/ { gsub(/^[[:space:]]*name:[[:space:]]*/, ""); gsub(/["\047]/, ""); gsub(/\r/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); name = $0 }
      in_deps && /^[[:space:]]*repository:/ { gsub(/^[[:space:]]*repository:[[:space:]]*/, ""); gsub(/["\047]/, ""); gsub(/\r/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); repo = $0 }
      in_deps && /^[[:space:]]*version:/ { gsub(/^[[:space:]]*version:[[:space:]]*/, ""); gsub(/["\047]/, ""); gsub(/\r/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); version = $0 }
      END { if (name != "" && repo != "" && version != "") { print name "|" repo "|" version } }
    ' "$chart_dir/Chart.yaml" 2>/dev/null || true)
  fi
  
  if [[ -z "$chart_deps" ]]; then
    log_info "   No external dependencies found"
    return 0
  fi
  
  local dep_count=0
  while IFS='|' read -r dep_name dep_repo dep_version; do
    if [[ -n "$dep_name" && -n "$dep_repo" && -n "$dep_version" ]]; then
      dep_count=$((dep_count + 1))
    fi
  done <<< "$chart_deps"
  
  if [[ $dep_count -eq 0 ]]; then
    log_info "   No external dependencies found"
    return 0
  fi
  
  log_info "   Found $dep_count external dependencies"
  
  # Process each dependency
  while IFS='|' read -r dep_name dep_repo dep_version; do
    if [[ -n "$dep_name" && -n "$dep_repo" && -n "$dep_version" ]]; then
      # Check if dependency already processed (avoid duplicates)
      local dep_key="${dep_name}:${dep_version}"
      local already_processed=false
      for processed_dep in "${PROCESSED_DEPENDENCIES[@]+"${PROCESSED_DEPENDENCIES[@]}"}"; do
        if [[ "$processed_dep" == "$dep_key" ]]; then
          already_processed=true
          break
        fi
      done
      
      if [[ "$already_processed" == "true" ]]; then
        log_info "   ⏭️  Dependency already processed: $dep_name:$dep_version (skipping)"
        continue
      fi
      
      # Check if dependency already exists in ECR (respect --force flag)
      local dep_repo_name="${ECR_PREFIX}/${dep_name}"
      if [[ "$FORCE_UPDATE" == false ]] && chart_exists_in_ecr "$dep_repo_name" "$dep_version"; then
        log_info "   ✅ Dependency already in ECR: $dep_name:$dep_version (skipping)"
        PROCESSED_DEPENDENCIES+=("$dep_key")
        continue
      fi
      
      log_info "   📦 Processing dependency: $dep_name:$dep_version from $dep_repo"
      
      # Process the dependency chart
      if process_chart "$dep_name" "$dep_repo" "$dep_name" "$dep_version"; then
        PROCESSED_DEPENDENCIES+=("$dep_key")
        log_success "   ✅ Successfully processed dependency: $dep_name:$dep_version"
      else
        log_error "   ❌ Failed to process dependency: $dep_name:$dep_version"
        FAILED_DEPENDENCIES+=("$dep_name:$dep_version")
      fi
    fi
  done <<< "$chart_deps"
  
  return 0
}

# Process single Helm chart
process_chart() {
  local name="$1"
  local repository="$2"
  local chart="$3"
  local version="$4"
  
  # Extract the actual chart name from the chart path (e.g., bitnami/nginx -> nginx)
  local actual_chart_name
  actual_chart_name=$(basename "$chart")
  local repo_name="${ECR_PREFIX}/${actual_chart_name}"
  local chart_dir="./charts/${actual_chart_name}"
  local chart_package="${actual_chart_name}-${version}.tgz"
  
  # Initialize details for this chart
  set_chart_details "$name" "" ""
  
  log_info "Processing chart: $name -> $actual_chart_name (version: $version)"
  
  # Check if chart already exists and skip if not forcing update
  if [[ "$FORCE_UPDATE" == false ]] && chart_exists_in_ecr "$repo_name" "$version"; then
    log_info "Chart already exists in ECR: $repo_name:$version (skipping)"
    PROCESSED_CHARTS+=("$name ($actual_chart_name):$version (already exists)")
    
    # Always analyze charts for summary details
    mkdir -p "./charts"
    
    # Authenticate to source registry for chart analysis pull
    if [[ "$repository" =~ ^oci:// ]]; then
      authenticate_source_registry "$repository/$chart" || true
    else
      authenticate_source_registry "$repository" || true
    fi
    
    # Handle OCI repositories differently from traditional repositories
    local pull_success=false
    if [[ "$repository" =~ ^oci:// ]]; then
      # For OCI repositories, pull directly from the OCI URL
      local oci_chart_ref="$repository/$chart:$version"
      if helm pull "$oci_chart_ref" --destination "./charts" 2>/dev/null; then
        pull_success=true
      fi
    else
      # Traditional repository handling
      local repo_alias="repo-$(echo "$repository" | md5sum | cut -d' ' -f1)"
      
      # Add repository (ignore if already exists)
      if helm repo add "$repo_alias" "$repository" 2>/dev/null; then
        log_info "Added Helm repository: $repository"
      else
        # Check if repo already exists with same URL
        if helm repo list 2>/dev/null | grep -q "$repo_alias.*$repository"; then
          log_info "Helm repository already exists: $repository"
        else
          log_warning "Could not add Helm repository: $repository (continuing anyway)"
        fi
      fi
      helm repo update "$repo_alias" 2>/dev/null || true
      
      if helm pull "$chart" --version "$version" --destination "./charts" 2>/dev/null; then
        pull_success=true
      fi
    fi
    
    if [[ "$pull_success" == true ]]; then
      tar -xzf "./charts/$chart_package" -C "./charts"
      
      # Extract images BEFORE modifying the chart (critical fix)
      local images
      images=$(extract_images_from_chart "$chart_dir" "$actual_chart_name")
      
      # Replace public registry references with ECR references (even for existing charts)
      replace_image_references "$chart_dir"
      replace_dependency_references "$chart_dir"
      
      # Repackage the modified chart
      log_info "Repackaging existing chart with ECR references"
      cd "./charts"
      rm -f "$chart_package"
      # Clean up macOS metadata and extended attributes
      find . -name '._*' -delete 2>/dev/null || true
      find . -name '.DS_Store' -delete 2>/dev/null || true
      xattr -rc "$actual_chart_name" 2>/dev/null || true
      COPYFILE_DISABLE=1 tar -czf "$chart_package" "$actual_chart_name"
      cd ".."
      
      # Count dependencies and get their names with proper classification
      local dep_details=""
      local external_deps=""
      
      # Check Chart.yaml for dependency information
      if [[ -f "$chart_dir/Chart.yaml" ]]; then
        # Extract dependencies from Chart.yaml and check if they have repository URLs
        local chart_deps
        chart_deps=$(yq eval '.dependencies[]? | select(. != null) | .name + "|" + (.repository // "")' "$chart_dir/Chart.yaml" 2>/dev/null || true)
        
        if [[ -n "$chart_deps" ]]; then
          local dep_count=1
          while IFS='|' read -r dep_name dep_repo; do
            if [[ -n "$dep_name" ]]; then
              # Only include external dependencies (those with repository URLs)
              if [[ -n "$dep_repo" && "$dep_repo" != '""' && "$dep_repo" != "null" && ! "$dep_repo" =~ ^[[:space:]]*$ ]]; then
                # External dependency with repository URL
                local dep_ecr_repo="oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}/${dep_name}"
                if [[ -n "$external_deps" ]]; then
                  external_deps="${external_deps}|${dep_count}. ${dep_name} (${dep_ecr_repo})"
                else
                  external_deps="${dep_count}. ${dep_name} (${dep_ecr_repo})"
                fi
                dep_count=$((dep_count + 1))
              fi
              # Skip local subcharts (empty repository) - don't include in output
            fi
          done <<< "$chart_deps"
        fi
      fi
      
      # Set dep_details to external dependencies only (local subcharts are excluded)
      dep_details="$external_deps"
      
      local image_details=""
      if [[ -n "$images" ]]; then
        local image_count=1
        while IFS= read -r image; do
          if [[ -n "$image" ]]; then
            local image_ecr_repo
            image_ecr_repo=$(get_ecr_repo_name_for_image "$image")
            if [[ -n "$image_details" ]]; then
              image_details="${image_details}|${image_count}. ${image} (${image_ecr_repo})"
            else
              image_details="${image_count}. ${image} (${image_ecr_repo})"
            fi
            image_count=$((image_count + 1))
            
            # Only process images if image processing is enabled
            if [[ "$PROCESS_IMAGES" == true ]]; then
              process_multiarch_image "$image"
            fi
          fi
        done <<< "$images"
      fi
      
      # Update chart details
      set_chart_details "$name" "$image_details" "$dep_details"
      
      # Cleanup
      [[ "$CLEANUP_FILES" == true ]] && rm -rf "$chart_dir" "./charts/$chart_package"
    fi
    return 0
  fi
  
  # Create ECR repository
  if ! create_repository "$repo_name" "chart"; then
    FAILED_CHARTS+=("$name:$version (repository creation failed)")
    return 1
  fi
  
  # Create charts directory
  mkdir -p "./charts"
  
  # Authenticate to source registry if needed (private ECR, Harbor, etc.)
  if [[ "$repository" =~ ^oci:// ]]; then
    # For OCI repos, authenticate using the full OCI URL
    if ! authenticate_source_registry "$repository/$chart"; then
      log_warning "⚠️  Source registry authentication failed for chart: $repository/$chart"
      FAILED_CHARTS+=("$name:$version (source registry auth failed)")
      return 1
    fi
  else
    # For traditional repos, authenticate using the repository URL host
    authenticate_source_registry "$repository" || true  # Non-fatal for traditional repos
  fi
  
  # Handle OCI repositories differently from traditional repositories
  if [[ "$repository" =~ ^oci:// ]]; then
    # For OCI repositories, pull directly from the OCI URL
    local oci_chart_ref="$repository/$chart:$version"
    if ! helm pull "$oci_chart_ref" --destination "./charts" 2>/dev/null; then
      log_error "Failed to pull OCI chart: $oci_chart_ref"
      FAILED_CHARTS+=("$name:$version (OCI chart pull failed)")
      return 1
    fi
  else
    # Traditional repository handling
    local repo_alias="repo-$(echo "$repository" | md5sum | cut -d' ' -f1)"
    
    # Add repository (ignore if already exists)
    if helm repo add "$repo_alias" "$repository" 2>/dev/null; then
      log_info "Added Helm repository: $repository"
    else
      # Check if repo already exists with same URL
      if helm repo list 2>/dev/null | grep -q "$repo_alias.*$repository"; then
        log_info "Helm repository already exists: $repository"
      else
        log_error "Failed to add Helm repository: $repository"
        FAILED_CHARTS+=("$name:$version (repository add failed)")
        return 1
      fi
    fi
    
    # Update repo to ensure we have latest chart info
    helm repo update "$repo_alias" 2>/dev/null || true
    
    # Convert chart name to use repo alias (e.g., "aws-observability/chart" -> "repo-alias/chart")
    local chart_with_alias
    if [[ "$chart" == */* ]]; then
      # Extract chart name after the slash
      local chart_name="${chart#*/}"
      chart_with_alias="${repo_alias}/${chart_name}"
    else
      # Chart name without prefix, use as-is with repo alias
      chart_with_alias="${repo_alias}/${chart}"
    fi
    
    if ! helm pull "$chart_with_alias" --version "$version" --destination "./charts" 2>/dev/null; then
      log_error "Failed to pull chart: $chart:$version"
      FAILED_CHARTS+=("$name:$version (chart pull failed)")
      return 1
    fi
  fi
  
  # Always extract chart for analysis and dependency counting
  tar -xzf "./charts/$chart_package" -C "./charts"
  
  # Process dependencies FIRST (before processing parent chart)
  process_chart_dependencies "$chart_dir" "$actual_chart_name"
  
  # Extract and analyze images BEFORE modifying the chart
  local images
  images=$(extract_images_from_chart "$chart_dir" "$actual_chart_name")
  
  # Replace public registry references with ECR references AFTER extracting original images
  replace_image_references "$chart_dir"
  replace_dependency_references "$chart_dir"
  
  # Repackage the modified chart
  log_info "Repackaging chart with ECR references"
  cd "./charts"
  rm -f "$chart_package"
  # Clean up macOS metadata and extended attributes
  find . -name '._*' -delete 2>/dev/null || true
  find . -name '.DS_Store' -delete 2>/dev/null || true
  xattr -rc "$actual_chart_name" 2>/dev/null || true
  COPYFILE_DISABLE=1 tar -czf "$chart_package" "$actual_chart_name"
  cd ".."
  
  # Verify the repackaged chart
  if ! tar -tzf "./charts/$chart_package" >/dev/null 2>&1; then
    log_error "Failed to repackage chart properly"
    return 1
  fi
  
  # Count dependencies and get their names with proper classification
  local dep_details=""
  local external_deps=""
  
  # Check Chart.yaml for dependency information
  if [[ -f "$chart_dir/Chart.yaml" ]]; then
    # Extract dependencies from Chart.yaml and check if they have repository URLs
    local chart_deps
    chart_deps=$(yq eval '.dependencies[]? | select(. != null) | .name + "|" + (.repository // "")' "$chart_dir/Chart.yaml" 2>/dev/null || true)
    
    if [[ -n "$chart_deps" ]]; then
      local dep_count=1
      while IFS='|' read -r dep_name dep_repo; do
        if [[ -n "$dep_name" ]]; then
          # Only include external dependencies (those with repository URLs)
          if [[ -n "$dep_repo" && "$dep_repo" != '""' && "$dep_repo" != "null" && ! "$dep_repo" =~ ^[[:space:]]*$ ]]; then
            # External dependency with repository URL
            local dep_ecr_repo="oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}/${dep_name}"
            if [[ -n "$external_deps" ]]; then
              external_deps="${external_deps}|${dep_count}. ${dep_name} (${dep_ecr_repo})"
            else
              external_deps="${dep_count}. ${dep_name} (${dep_ecr_repo})"
            fi
            dep_count=$((dep_count + 1))
          fi
          # Skip local subcharts (empty repository) - don't include in output
        fi
      done <<< "$chart_deps"
    fi
  fi
  
  # Set dep_details to external dependencies only (local subcharts are excluded)
  dep_details="$external_deps"
  
  # Process the extracted images
  local image_details=""
  if [[ -n "$images" ]]; then
    local image_count=1
    log_info "Found $(echo "$images" | wc -l) container images in chart: $name"
    
    while IFS= read -r image; do
      if [[ -n "$image" ]]; then
        local image_ecr_repo
        image_ecr_repo=$(get_ecr_repo_name_for_image "$image")
        if [[ -n "$image_details" ]]; then
          image_details="${image_details}|${image_count}. ${image} (${image_ecr_repo})"
        else
          image_details="${image_count}. ${image} (${image_ecr_repo})"
        fi
        image_count=$((image_count + 1))
        
        # Only process images if image processing is enabled
        if [[ "$PROCESS_IMAGES" == true ]]; then
          process_multiarch_image "$image" || log_warning "Failed to process image: $image (continuing with next image)"
        fi
      fi
    done <<< "$images"
  else
    log_info "No container images found in chart: $name"
  fi
  
  # Update chart details
  set_chart_details "$name" "$image_details" "$dep_details"
  
  # Login to ECR
  aws ecr get-login-password --region "$REGION" | \
    helm registry login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
  
  # If force update is enabled, delete existing chart tag
  if [[ "$FORCE_UPDATE" == true ]]; then
    local chart_repo_name="${ECR_PREFIX}/${name}"
    if aws ecr batch-delete-image --region "$REGION" --repository-name "$chart_repo_name" --image-ids imageTag="$version" >/dev/null 2>&1; then
      log_info "Deleted existing chart tag: $version (force update enabled)"
    fi
  fi
  
  # Push chart to ECR (use the ECR prefix as the base, not the full repo name)
  local ecr_chart_url="oci://${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_PREFIX}"
  local helm_error
  if helm_error=$(helm push "./charts/$chart_package" "$ecr_chart_url" 2>&1); then
    log_success "Pushed chart: $name:$version to $ecr_chart_url"
    PROCESSED_CHARTS+=("$name ($actual_chart_name):$version -> $ecr_chart_url")
  else
    log_error "Failed to push chart: $name:$version"
    log_error "Helm push error: $helm_error"
    FAILED_CHARTS+=("$name ($actual_chart_name):$version (push failed)")
    return 1
  fi
  
  # Cleanup
  if [[ "$CLEANUP_FILES" == true ]]; then
    rm -rf "$chart_dir" "./charts/$chart_package"
  fi
  
  return 0
}

# Cleanup temporary files and directories
cleanup_temp_files() {
  # Only cleanup if --cleanup flag was provided
  if [[ "$CLEANUP_FILES" != true ]]; then
    log_info "🧹 Cleanup skipped (use --cleanup flag to enable automatic cleanup)"
    return 0
  fi
  
  log_info "🧹 Cleaning up temporary files..."
  
  # Remove chart directories
  if [[ -d "./charts" ]]; then
    rm -rf "./charts"
    log_info "Removed charts directory"
  fi
  
  # Remove .tgz files
  local tgz_files
  tgz_files=$(find . -maxdepth 1 -name "*.tgz" 2>/dev/null || true)
  if [[ -n "$tgz_files" ]]; then
    rm -f *.tgz
    log_info "Removed .tgz files"
  fi
  
  # Remove test directories
  if [[ -d "./test-charts" ]]; then
    rm -rf "./test-charts"
    log_info "Removed test-charts directory"
  fi
  
  log_success "✅ Cleanup completed successfully"
}

# Parse YAML configuration file
parse_config_file() {
  local config_file="$1"
  
  if [[ ! -f "$config_file" ]]; then
    log_error "Configuration file not found: $config_file"
    exit 1
  fi

  # Validate config file is a regular file and readable
  if [[ ! -r "$config_file" ]]; then
    log_error "Configuration file is not readable: $config_file"
    exit 1
  fi

  # Basic YAML structure validation
  if ! head -50 "$config_file" | grep -qE '^(charts:|standalone_images:|source_auth:)'; then
    log_warning "Configuration file may not contain expected sections (charts, standalone_images, or source_auth)"
  fi
  
  log_info "Parsing configuration file: $config_file"
  
  # Parse YAML using awk (avoiding external dependencies)
  # Output format: name|repository|chart|version
  # NOTE: suffix field is NOT supported for Helm charts (would break Terraform deployments)
  awk '
    BEGIN { name = ""; repository = ""; chart = ""; version = ""; in_charts = 0; warned_suffix = 0 }
    
    # Detect charts section
    /^charts:[[:space:]]*$/ {
      in_charts = 1
      next
    }
    
    # Exit charts section when we hit another top-level key
    /^[a-zA-Z]/ && in_charts {
      in_charts = 0
    }
    
    in_charts && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      # Output previous chart if complete
      if (name != "" && repository != "" && chart != "" && version != "") {
        print name "|" repository "|" chart "|" version
      }
      # Start new chart
      gsub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      name = $0
      repository = ""
      chart = ""
      version = ""
    }
    in_charts && /^[[:space:]]*repository:[[:space:]]*/ {
      gsub(/^[[:space:]]*repository:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      repository = $0
    }
    in_charts && /^[[:space:]]*chart:[[:space:]]*/ {
      gsub(/^[[:space:]]*chart:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      chart = $0
    }
    in_charts && /^[[:space:]]*version:[[:space:]]*/ {
      gsub(/^[[:space:]]*version:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      version = $0
    }
    # Warn if suffix is used in charts section (not supported)
    in_charts && /^[[:space:]]*suffix:[[:space:]]*/ && !warned_suffix {
      print "⚠️  WARNING: suffix field in charts section is not supported and will be ignored" > "/dev/stderr"
      print "   Helm charts must use default suffixes (helmchart/helmimage) for Terraform compatibility" > "/dev/stderr"
      warned_suffix = 1
    }
    # Output at end of file if we have pending data
    END {
      if (name != "" && repository != "" && chart != "" && version != "") {
        print name "|" repository "|" chart "|" version
      }
    }
  ' "$config_file"
}

# Parse standalone images from config file
parse_standalone_images_from_config() {
  local config_file="$1"
  
  if [[ ! -f "$config_file" ]]; then
    return 0
  fi
  
  # Parse standalone_images section using awk
  # Supports two formats:
  # 1. Simple: - docker.io/library/nginx:1.25.0
  # 2. Object: - image: docker.io/library/nginx:1.25.0
  #              suffix: appimage
  # Output format: image|suffix (suffix is optional, empty if not specified)
  awk '
    BEGIN { in_standalone = 0; image = ""; suffix = "" }
    
    # Detect standalone_images section
    /^standalone_images:[[:space:]]*$/ {
      in_standalone = 1
      next
    }
    
    # Exit standalone section when we hit another top-level key
    /^[a-zA-Z]/ && in_standalone {
      in_standalone = 0
    }
    
    # Parse image entries in standalone section
    in_standalone && /^[[:space:]]*-[[:space:]]*/ {
      # Output previous image if exists
      if (image != "") {
        print image "|" suffix
        image = ""
        suffix = ""
      }
      
      # Check if this is simple format (just image on same line)
      line = $0
      gsub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/["\047]/, "", line)
      gsub(/\r/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      
      # If line starts with "image:", its object format
      if (line ~ /^image:[[:space:]]*/) {
        gsub(/^image:[[:space:]]*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        image = line
      } else if (line != "" && substr(line, 1, 1) != "#") {
        # Simple format - output immediately (not a comment)
        print line "|"
      }
    }
    
    # Parse suffix in object format
    in_standalone && /^[[:space:]]*suffix:[[:space:]]*/ && image != "" {
      gsub(/^[[:space:]]*suffix:[[:space:]]*/, "")
      gsub(/["\047]/, "")
      gsub(/\r/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      gsub(/#.*$/, "")  # Remove comments
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      suffix = $0
    }
    
    # Output at end of file if we have pending image
    END {
      if (image != "") {
        print image "|" suffix
      }
    }
  ' "$config_file"
}

# Print summary
print_summary() {
  echo
  log_info "=== PROCESSING SUMMARY ==="
  
  # Charts summary — PROCESSED_CHARTS already includes dependency charts
  # (process_chart_dependencies calls process_chart which appends to PROCESSED_CHARTS)
  # PROCESSED_DEPENDENCIES is used for dedup tracking only, not for counting
  echo
  log_info "📦 HELM CHARTS PROCESSED: ${#PROCESSED_CHARTS[@]}"
  
  # Separate main charts from dependency charts for display
  local main_chart_count=0
  local dep_chart_count=${#PROCESSED_DEPENDENCIES[@]}
  
  if [[ ${#PROCESSED_CHARTS[@]} -gt 0 ]]; then
    # Count main charts (total minus dependencies)
    main_chart_count=$((${#PROCESSED_CHARTS[@]} - dep_chart_count))
    if [[ $main_chart_count -gt 0 ]]; then
      log_info "   📦 Main charts: $main_chart_count"
      for chart in "${PROCESSED_CHARTS[@]:-}"; do
        # Skip dependency charts in main list
        local is_dep=false
        for dep in "${PROCESSED_DEPENDENCIES[@]+"${PROCESSED_DEPENDENCIES[@]}"}"; do
          local dep_name="${dep%%:*}"
          if [[ "$chart" == "$dep_name"* ]]; then
            is_dep=true
            break
          fi
        done
        if [[ "$is_dep" == "false" ]]; then
          echo "     ✅ $chart"
        fi
      done
    fi
  fi
  
  # Show dependency charts
  if [[ ${#PROCESSED_DEPENDENCIES[@]} -gt 0 ]]; then
    log_info "   🔗 Dependency charts: ${#PROCESSED_DEPENDENCIES[@]}"
    for dep in "${PROCESSED_DEPENDENCIES[@]:-}"; do
      echo "     ✅ $dep"
    done
  fi
  
  if [[ ${#FAILED_CHARTS[@]} -gt 0 ]]; then
    echo
    log_error "❌ FAILED CHARTS: ${#FAILED_CHARTS[@]}"
    for chart in "${FAILED_CHARTS[@]:-}"; do
      echo "  ❌ $chart"
    done
  fi
  
  if [[ ${#FAILED_DEPENDENCIES[@]} -gt 0 ]]; then
    echo
    log_error "❌ FAILED DEPENDENCIES: ${#FAILED_DEPENDENCIES[@]}"
    for dep in "${FAILED_DEPENDENCIES[@]:-}"; do
      echo "  ❌ $dep"
    done
  fi
  
  # Images summary (only if image processing is enabled)
  if [[ "$PROCESS_IMAGES" == true ]]; then
    echo
    
    # Show standalone images separately
    if [[ ${#PROCESSED_STANDALONE_IMAGES[@]} -gt 0 ]]; then
      log_info "🖼️  STANDALONE IMAGES PROCESSED: ${#PROCESSED_STANDALONE_IMAGES[@]}"
      for image in "${PROCESSED_STANDALONE_IMAGES[@]}"; do
        echo "  ✅ $image"
      done
      echo
    fi
    
    # Show chart-extracted images
    local chart_images_count=$((${#PROCESSED_IMAGES[@]} - ${#PROCESSED_STANDALONE_IMAGES[@]}))
    if [[ $chart_images_count -gt 0 ]]; then
      log_info "🐳 CHART-EXTRACTED IMAGES PROCESSED: $chart_images_count"
      for image in "${PROCESSED_IMAGES[@]}"; do
        # Only show images that are not in standalone list
        local is_standalone=false
        for standalone in "${PROCESSED_STANDALONE_IMAGES[@]}"; do
          if [[ "$image" == "$standalone"* ]]; then
            is_standalone=true
            break
          fi
        done
        if [[ "$is_standalone" == false ]]; then
          echo "  ✅ $image"
        fi
      done
      echo
    fi
    
    if [[ ${#FAILED_IMAGES[@]} -gt 0 ]]; then
      log_error "❌ FAILED IMAGES: ${#FAILED_IMAGES[@]}"
      for image in "${FAILED_IMAGES[@]:-}"; do
        echo "  ❌ $image"
      done
      echo
    fi
    
    if [[ ${#SKIPPED_AUTH_IMAGES[@]} -gt 0 ]]; then
      log_info "🔐 AUTHENTICATION REQUIRED (SKIPPED): ${#SKIPPED_AUTH_IMAGES[@]}"
      log_info "    These images require registry credentials to pull:"
      for image in "${SKIPPED_AUTH_IMAGES[@]:-}"; do
        log_info "  🔒 $image"
      done
      log_info "    💡 Tip: Provide registry credentials or authentication to pull these images"
      echo
    fi
  else
    echo
    log_info "🐳 CONTAINER IMAGES: Skipped (--no-images flag used)"
  fi
  
  # Generate ECR Repository Names section
  if [[ ${#PROCESSED_CHARTS[@]} -gt 0 ]]; then
    echo
    log_info "=== OUTPUT ==="
    echo
    echo "ecr_registry: ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
    echo
    
    # Collect helm chart repository names
    local helm_repos=()
    local image_repos=()
    
    for chart_entry in "${PROCESSED_CHARTS[@]:-}"; do
      if echo "$chart_entry" | grep -q "("; then
        local display_name actual_name version
        display_name=$(echo "$chart_entry" | sed 's/[[:space:]]*(.*//')
        actual_name=$(echo "$chart_entry" | sed 's/[^(]*(\([^)]*\)).*/\1/')
        version=$(echo "$chart_entry" | sed 's/[^:]*:\([^[:space:]()]*\).*/\1/')
        
        helm_repos+=("  - ${ECR_PREFIX}/${actual_name}:${version}")
        
        # Get image details for this chart
        local image_details
        image_details=$(get_chart_image_details "$display_name")
        
        if [[ -n "$image_details" ]]; then
          IFS='|' read -ra temp_image_lines <<< "$image_details"
          local image_count=0
          for image_line in "${temp_image_lines[@]}"; do
            # Extract original image name from the line (before the ECR repo part)
            local original_image
            original_image=$(echo "$image_line" | sed 's/^[0-9]*\. \([^(]*\) (.*/\1/')
            if [[ -n "$original_image" ]]; then
              # Always include discovered images in summary (regardless of processing)
              image_count=$((image_count + 1))
              # Add to image repos list for ECR output
              local image_name tag
              if [[ "$original_image" =~ ^(.+):(.+)$ ]]; then
                image_name="${BASH_REMATCH[1]}"
                tag="${BASH_REMATCH[2]}"
                local ecr_image_repo
                ecr_image_repo=$(get_ecr_repo_name_for_image "$original_image")
                image_repos+=("  - ${ecr_image_repo}:${tag}")
              fi
            fi
          done
        fi
        
        # Get dependency details for this chart
        local dep_details
        dep_details=$(get_chart_dep_details "$display_name")
        
        if [[ -n "$dep_details" ]]; then
          IFS='|' read -ra dep_lines <<< "$dep_details"
          for dep_line in "${dep_lines[@]}"; do
            # Extract dependency name from the line
            local dep_name
            dep_name=$(echo "$dep_line" | sed 's/^[0-9]*\. \([^(]*\) (.*/\1/')
            if [[ -n "$dep_name" ]]; then
              helm_repos+=("  - ${ECR_PREFIX}/${dep_name}")
            fi
          done
        fi
      fi
    done
    
    # Remove duplicates and sort
    if [[ ${#helm_repos[@]} -gt 0 ]]; then
      echo "Helm chart repository names:"
      printf '%s\n' "${helm_repos[@]}" | sort -u
      echo
    fi
    
    if [[ ${#image_repos[@]} -gt 0 ]]; then
      echo "Image repository names:"
      printf '%s\n' "${image_repos[@]}" | sort -u
      echo
    fi
  fi
  
  # Generate simplified table output for processed charts
  if [[ ${#PROCESSED_CHARTS[@]} -gt 0 ]]; then
    echo
    log_info "📋 PROCESSED CHARTS DETAILS:"
    
    # Table header with borders
    echo "+---------------------------+------------------------------------------------------------------------------+------------------+"
    printf "| %-25s | %-76s | %-16s |\n" "CHART DETAILS" "CONTAINER IMAGES" "DEPENDENCIES"
    echo "+---------------------------+------------------------------------------------------------------------------+------------------+"
    
    for chart_entry in "${PROCESSED_CHARTS[@]:-}"; do
      if echo "$chart_entry" | grep -q "("; then
        local display_name
        display_name=$(echo "$chart_entry" | sed 's/[[:space:]]*(.*//')
        
        local image_details
        local dep_details
        image_details=$(get_chart_image_details "$display_name")
        dep_details=$(get_chart_dep_details "$display_name")
        
        # Process image details to show only successfully processed images
        local image_lines=()
        local image_count=0
        if [[ -n "$image_details" ]]; then
          IFS='|' read -ra temp_image_lines <<< "$image_details"
          for image_line in "${temp_image_lines[@]}"; do
            # Extract just the ECR repository name (after the registry URL)
            local clean_image
            clean_image=$(echo "$image_line" | sed 's/ (.*//')
            
            # Extract the ECR repository name for display (remove registry prefix)
            local display_image
            if [[ "$clean_image" =~ ^[0-9]+\.[[:space:]]*${ACCOUNT_ID}\.dkr\.ecr\.[^/]+\.amazonaws\.com/(.+)$ ]]; then
              display_image=$(echo "$clean_image" | sed "s|^[0-9]*\. *${ACCOUNT_ID}\.dkr\.ecr\.[^/]*\.amazonaws\.com/||")
            else
              display_image=$(echo "$clean_image" | sed 's/^[0-9]*\. *//')
            fi
            
            # Always include discovered images in summary
            image_count=$((image_count + 1))
            # Renumber the image starting from 1 with cleaned name
            image_lines+=("${image_count}. ${display_image}")
          done
        fi
        
        # If no images were successfully processed, show "None"
        if [[ ${#image_lines[@]} -eq 0 ]]; then
          image_lines=("None")
        fi
        
        # Process dependency details to show only dependency names
        local dep_lines=()
        local dep_count=0
        if [[ -n "$dep_details" ]]; then
          IFS='|' read -ra temp_dep_lines <<< "$dep_details"
          for dep_line in "${temp_dep_lines[@]}"; do
            # Extract just the dependency name (before the ECR repo part)
            local clean_dep
            clean_dep=$(echo "$dep_line" | sed 's/ (.*//')
            dep_lines+=("$clean_dep")
            dep_count=$((dep_count + 1))
          done
        else
          dep_lines=("None")
        fi
        
        # Create the first column content with chart name and totals
        local first_column_lines=()
        first_column_lines+=("$display_name")
        first_column_lines+=("Total images: $image_count")
        first_column_lines+=("Total Dependencies: $dep_count")
        
        # Find the maximum number of lines needed
        local max_lines=${#image_lines[@]}
        if [[ ${#dep_lines[@]} -gt $max_lines ]]; then
          max_lines=${#dep_lines[@]}
        fi
        if [[ ${#first_column_lines[@]} -gt $max_lines ]]; then
          max_lines=${#first_column_lines[@]}
        fi
        
        # Print all rows
        for ((i=0; i<max_lines; i++)); do
          local first_col="${first_column_lines[$i]:-}"
          local img_line="${image_lines[$i]:-}"
          local dep_line="${dep_lines[$i]:-}"
          printf "| %-25s | %-76s | %-16s |\n" "${first_col:0:25}" "${img_line:0:76}" "${dep_line:0:16}"
        done
        
        # Add separator line between charts
        echo "+---------------------------+------------------------------------------------------------------------------+------------------+"
      fi
    done
  fi
  
  # Add note about authentication-required images if any exist
  if [[ ${#SKIPPED_AUTH_IMAGES[@]} -gt 0 ]]; then
    echo
    echo "📝 Note: ${#SKIPPED_AUTH_IMAGES[@]} image(s) require authentication and were skipped:"
    for image in "${SKIPPED_AUTH_IMAGES[@]:-}"; do
      echo "   🔒 $image (authentication required)"
    done
  fi
  
  echo
  # Calculate totals safely, handling when arrays might be empty
  local charts_count=${#PROCESSED_CHARTS[@]}
  local images_count=0
  local deps_count=${#PROCESSED_DEPENDENCIES[@]}
  local failed_charts_count=${#FAILED_CHARTS[@]}
  local failed_images_count=0
  local failed_deps_count=${#FAILED_DEPENDENCIES[@]}
  
  # Only count images if image processing is enabled
  if [[ "$PROCESS_IMAGES" == true ]]; then
    images_count=${#PROCESSED_IMAGES[@]}
    failed_images_count=${#FAILED_IMAGES[@]}
  fi
  
  local total_success=$((charts_count + images_count + deps_count))
  local total_failed=$((failed_charts_count + failed_images_count + failed_deps_count))
  
  # Count actual pushes (not just processed/skipped)
  local charts_pushed=0
  local images_pushed=0
  local standalone_images_pushed=0
  
  # Count charts pushed (PROCESSED_CHARTS already includes dependency charts
  # since process_chart_dependencies calls process_chart which appends to PROCESSED_CHARTS)
  # Do NOT also count PROCESSED_DEPENDENCIES to avoid double-counting
  for chart in "${PROCESSED_CHARTS[@]:-}"; do
    if [[ "$chart" != *"(already exists)"* ]]; then
      charts_pushed=$((charts_pushed + 1))
    fi
  done
  
  # Count chart-extracted images (exclude standalone images which are also in PROCESSED_IMAGES
  # because process_standalone_image calls process_multiarch_image which adds to PROCESSED_IMAGES)
  if [[ "$PROCESS_IMAGES" == true && ${#PROCESSED_IMAGES[@]} -gt 0 ]]; then
    for image in "${PROCESSED_IMAGES[@]}"; do
      if [[ "$image" != *"(already exists)"* && "$image" != *"SKIPPED"* ]]; then
        # Check if this image is from a standalone image (skip if so)
        local is_standalone=false
        for standalone in "${PROCESSED_STANDALONE_IMAGES[@]+"${PROCESSED_STANDALONE_IMAGES[@]}"}"; do
          if [[ "$image" == *"$standalone"* || "$image" == "$standalone"* ]]; then
            is_standalone=true
            break
          fi
        done
        if [[ "$is_standalone" == "false" ]]; then
          images_pushed=$((images_pushed + 1))
        fi
      fi
    done
  fi
  
  # Count standalone images separately
  for image in "${PROCESSED_STANDALONE_IMAGES[@]:-}"; do
    if [[ "$image" != *"(already exists)"* && "$image" != *"SKIPPED"* ]]; then
      standalone_images_pushed=$((standalone_images_pushed + 1))
    fi
  done
  
  echo
  log_info "📊 FINAL PUSH SUMMARY:"
  log_info "   📦 Charts pushed to ECR: $charts_pushed"
  log_info "   🐳 Chart-extracted images pushed to ECR: $images_pushed"
  log_info "   🖼️  Standalone images pushed to ECR: $standalone_images_pushed"
  log_info "   📋 Total items pushed: $((charts_pushed + images_pushed + standalone_images_pushed))"
  
  # Enhanced processing statistics
  echo
  log_info "📈 PROCESSING STATISTICS:"
  log_info "   ⏱️  Total script runtime: $(get_script_runtime)"
  log_info "   📊 Processing mode: $([ "$CLI_MODE" == "true" ] && echo "Command Line" || echo "Configuration File")"
  log_info "   🔍 Log level used: $LOG_LEVEL"
  log_info "   ⚙️  Timing logs enabled: $ENABLE_TIMING_LOGS"
  
  # Multi-arch processing statistics - use tracking arrays
  local multiarch_processed=${#MULTIARCH_IMAGES[@]}
  local singlearch_processed=${#SINGLEARCH_IMAGES[@]}
  local skipped_count=${#SKIPPED_AUTH_IMAGES[@]}
  local partial_success_count=${#PARTIAL_SUCCESS_IMAGES[@]}
  local fallback_count=0
  
  # Count fallbacks from multi-arch array
  for image in "${MULTIARCH_IMAGES[@]:-}"; do
    if [[ "$image" == *"(from fallback)"* || "$image" == *"(recovered)"* ]]; then
      fallback_count=$((fallback_count + 1))
    fi
  done
  
  # Count skipped images from PROCESSED_IMAGES if SKIPPED_AUTH_IMAGES is empty
  if [[ $skipped_count -eq 0 ]]; then
    for image in "${PROCESSED_IMAGES[@]:-}"; do
      if [[ "$image" == *"SKIPPED"* ]]; then
        skipped_count=$((skipped_count + 1))
      fi
    done
  fi
  
  if [[ "$PROCESS_IMAGES" == "true" && ${#PROCESSED_IMAGES[@]} -gt 0 ]]; then
    echo
    log_info "🏗️  MULTI-ARCH PROCESSING STATISTICS:"
    log_info "   🏛️  Multi-arch images successfully pushed: $multiarch_processed"
    log_info "   🏢 Single-arch images successfully pushed: $singlearch_processed"
    log_info "   🔄 Fallback/recovery operations used: $fallback_count"
    log_info "   🔐 Images skipped (authentication/inspection failures): $skipped_count"
    
    if [[ $partial_success_count -gt 0 ]]; then
      log_warning "   ⚠️  Partial successes (needs manual tagging): $partial_success_count"
    fi
    
    if [[ $multiarch_processed -gt 0 && $singlearch_processed -gt 0 ]]; then
      local total_pushed=$((multiarch_processed + singlearch_processed))
      local multiarch_percentage=$((multiarch_processed * 100 / total_pushed))
      log_info "   📊 Multi-arch success rate: ${multiarch_percentage}%"
    fi
  fi
  
  if [[ $total_failed -eq 0 ]]; then
    log_success "🎉 All operations completed successfully! Total processed: $total_success"
  else
    log_warning "⚠️  Completed with some failures. Success: $total_success, Failed: $total_failed"
    # Cleanup before exit to ensure charts directory is removed even on failures
    log_processing_step "cleanup_on_failure" "main" "Cleaning up temporary files before exit"
    cleanup_temp_files
    exit 1
  fi
}

# ============================================================================
# STANDALONE IMAGE PROCESSING FUNCTIONS
# ============================================================================

# Process a single standalone image
process_standalone_image() {
  local source_image="$1"
  
  log_info "📦 Processing standalone image: $source_image"
  
  # Validate image format
  if [[ ! "$source_image" =~ : ]]; then
    log_error "Invalid image format: $source_image (must include tag, e.g., nginx:1.25.0)"
    return 1
  fi
  
  # Check if image already exists in ECR (unless force update)
  local ecr_repo=$(get_ecr_repo_name_for_image "$source_image")
  local tag=$(echo "$source_image" | cut -d: -f2)
  
  if [[ "$FORCE_UPDATE" != true ]] && image_exists_in_ecr "$ecr_repo" "$tag"; then
    log_info "Image already exists in ECR: ${ecr_repo}:${tag} (use --force to update)"
    PROCESSED_STANDALONE_IMAGES+=("$source_image")
    return 0
  fi
  
  # Create ECR repository if needed
  if ! create_repository "$ecr_repo" "image"; then
    log_error "Failed to create repository for image: $source_image"
    FAILED_IMAGES+=("$source_image")
    return 1
  fi
  
  # Process the image (will handle multi-arch automatically)
  if process_multiarch_image "$source_image"; then
    log_success "✅ Successfully processed standalone image: $source_image"
    PROCESSED_STANDALONE_IMAGES+=("$source_image")
    return 0
  else
    log_error "❌ Failed to process standalone image: $source_image"
    FAILED_IMAGES+=("$source_image")
    return 1
  fi
}

# Process standalone images from file
process_standalone_images_from_file() {
  local image_file="$1"
  
  if [[ ! -f "$image_file" ]]; then
    log_error "Image file not found: $image_file"
    return 1
  fi
  
  log_info "📋 Processing images from file: $image_file"
  
  local total_images=0
  local processed_count=0
  local failed_count=0
  
  # Count total images
  total_images=$(grep -v '^[[:space:]]*$' "$image_file" | grep -v '^[[:space:]]*#' | wc -l | tr -d ' ')
  log_info "📊 Total images to process: $total_images"
  
  # Process each image
  local line_number=0
  while IFS= read -r image || [[ -n "$image" ]]; do
    line_number=$((line_number + 1))
    
    # Skip empty lines and comments
    [[ -z "$image" || "$image" =~ ^[[:space:]]*# ]] && continue
    
    # Trim whitespace
    image=$(echo "$image" | xargs)
    
    log_info "🔄 Processing image $((processed_count + failed_count + 1))/$total_images: $image"
    
    if process_standalone_image "$image"; then
      processed_count=$((processed_count + 1))
    else
      failed_count=$((failed_count + 1))
      log_warning "Failed to process image on line $line_number: $image"
    fi
  done < "$image_file"
  
  log_info "📊 Standalone images processing complete: $processed_count succeeded, $failed_count failed"
  
  if [[ $failed_count -gt 0 ]]; then
    return 1
  fi
  return 0
}

# Plan mode - show what would be processed without executing
run_plan() {
  echo
  log_info "📋 ECR Artifact Manager - PLAN MODE (no changes will be made)"
  log_info "================================================================"
  echo

  # Show configuration
  log_info "⚙️  CONFIGURATION:"
  log_info "   Region:          $REGION"
  log_info "   Resource prefix: $RESOURCE_PREFIX"
  log_info "   Helm suffix:     $HELM_SUFFIX  →  ECR prefix: ${RESOURCE_PREFIX}${HELM_SUFFIX}/"
  log_info "   Image suffix:    $IMAGE_SUFFIX  →  ECR prefix: ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/"
  if [[ "$TF_CONFIG_LOADED" == true ]]; then
    log_info "   Terraform:       loaded (${TF_TEMPLATES_FORMAT} format)"
    log_info "   Templates:       ${AVAILABLE_SUFFIXES[*]}"
  fi
  log_info "   Create repos:    $CREATE_REPOS"
  log_info "   Use templates:   $USE_CREATION_TEMPLATES"
  log_info "   Process images:  $PROCESS_IMAGES"
  log_info "   Force update:    $FORCE_UPDATE"
  echo

  if [[ "$CLI_MODE" == true ]]; then
    # Command line mode
    log_info "📦 MODE: Single Helm Chart (command line)"
    echo
    log_info "   Chart:      $CLI_NAME"
    log_info "   Repository: $CLI_REPOSITORY"
    log_info "   Chart path: $CLI_CHART"
    log_info "   Version:    $CLI_VERSION"
    echo
    log_info "   Would push chart to:  ${RESOURCE_PREFIX}${HELM_SUFFIX}/$CLI_NAME"
    if [[ "$PROCESS_IMAGES" == true ]]; then
      log_info "   Would extract and push container images to: ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/<image-name>"
    fi

  elif [[ "$STANDALONE_IMAGE_MODE" == true ]]; then
    # Standalone image mode
    log_info "🖼️  MODE: Standalone Image"
    echo
    if [[ -n "$STANDALONE_IMAGE" ]]; then
      local img_name="${STANDALONE_IMAGE%%:*}"
      img_name="${img_name##*/}"
      log_info "   Image: $STANDALONE_IMAGE"
      log_info "   Would push to: ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/$img_name"
    elif [[ -n "$STANDALONE_IMAGE_FILE" ]]; then
      if [[ ! -f "$STANDALONE_IMAGE_FILE" ]]; then
        log_error "Image file not found: $STANDALONE_IMAGE_FILE"
        return 1
      fi
      local img_count=0
      log_info "   Image file: $STANDALONE_IMAGE_FILE"
      echo
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line=$(echo "$line" | xargs)
        img_count=$((img_count + 1))
        local img_name="${line%%:*}"
        img_name="${img_name##*/}"
        log_info "   [$img_count] $line  →  ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/$img_name"
      done < "$STANDALONE_IMAGE_FILE"
      echo
      log_info "   Total standalone images: $img_count"
    fi

  else
    # Configuration file mode
    if [[ ! -f "$CONFIG_FILE" ]]; then
      log_error "Configuration file not found: $CONFIG_FILE"
      return 1
    fi

    log_info "📋 MODE: Configuration File ($CONFIG_FILE)"

    # Check source auth config
    local plan_secret_name=""
    plan_secret_name=$(awk '
      BEGIN { in_auth = 0 }
      /^source_auth:/ { in_auth = 1; next }
      /^[a-zA-Z]/ && in_auth { in_auth = 0 }
      in_auth && /secret_name:/ {
        gsub(/^[[:space:]]*secret_name:[[:space:]]*/, "")
        gsub(/["\047]/, ""); gsub(/\r/, "")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print
      }
    ' "$CONFIG_FILE")

    if [[ -n "$plan_secret_name" ]]; then
      echo
      log_info "🔐 SOURCE AUTHENTICATION:"
      log_info "   Secret name: $plan_secret_name"
      local plan_secret_region=""
      plan_secret_region=$(awk '
        BEGIN { in_auth = 0 }
        /^source_auth:/ { in_auth = 1; next }
        /^[a-zA-Z]/ && in_auth { in_auth = 0 }
        in_auth && /secret_region:/ {
          gsub(/^[[:space:]]*secret_region:[[:space:]]*/, "")
          gsub(/["\047]/, ""); gsub(/\r/, "")
          gsub(/^[[:space:]]+|[[:space:]]+$/, "")
          print
        }
      ' "$CONFIG_FILE")
      log_info "   Secret region: ${plan_secret_region:-$REGION}"
    fi

    # Parse and display Helm charts
    local chart_count=0
    local chart_lines=""
    chart_lines=$(parse_config_file "$CONFIG_FILE")

    if [[ -n "$chart_lines" ]]; then
      echo
      log_info "📦 HELM CHARTS:"
      while IFS='|' read -r name repository chart version; do
        if [[ -n "$name" ]]; then
          chart_count=$((chart_count + 1))
          echo
          log_info "   [$chart_count] $name ($version)"
          log_info "       Source:     $repository"
          log_info "       Chart:      $chart"
          log_info "       Chart ECR:  ${RESOURCE_PREFIX}${HELM_SUFFIX}/$name"
          if [[ "$PROCESS_IMAGES" == true ]]; then
            log_info "       Images ECR: ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/<extracted-images>"
          fi
        fi
      done <<< "$chart_lines"
      echo
      log_info "   Total Helm charts: $chart_count"
    else
      echo
      log_info "📦 HELM CHARTS: none"
    fi

    # Parse and display standalone images
    local si_count=0
    local si_lines=""
    si_lines=$(parse_standalone_images_from_config "$CONFIG_FILE")

    if [[ -n "$si_lines" ]]; then
      echo
      log_info "🖼️  STANDALONE IMAGES:"
      while IFS='|' read -r image suffix; do
        if [[ -n "$image" ]]; then
          si_count=$((si_count + 1))
          local img_name="${image%%:*}"
          img_name="${img_name##*/}"
          local target_suffix="${suffix:-$IMAGE_SUFFIX}"
          log_info "   [$si_count] $image  →  ${RESOURCE_PREFIX}${target_suffix}/$img_name"
        fi
      done <<< "$si_lines"
      echo
      log_info "   Total standalone images: $si_count"
    else
      echo
      log_info "🖼️  STANDALONE IMAGES: none"
    fi

    echo
    log_info "📊 PLAN TOTALS:"
    log_info "   Helm charts:       $chart_count"
    log_info "   Standalone images: $si_count"
    if [[ "$PROCESS_IMAGES" == true && $chart_count -gt 0 ]]; then
      log_info "   Chart images:      will be extracted at runtime (count unknown until charts are pulled)"
    fi
  fi

  echo
  log_info "✅ Plan complete. Run without --plan to execute."
  echo
}

# Main function
main() {
  log_info "🚀 ECR Artifact Manager - Comprehensive ECR Repository Management Tool"
  log_info "======================================================================"
  log_info "⏱️  Script started at $(date)"
  log_info "📊 Script runtime tracking enabled: $ENABLE_TIMING_LOGS"
  log_info "🔍 Log level: $LOG_LEVEL"
  if [[ "$TF_CONFIG_LOADED" == true ]]; then
    log_info "🏷️  Naming: ${RESOURCE_PREFIX}${HELM_SUFFIX}/ (charts), ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/ (images) [from Terraform]"
    if [[ ${#AVAILABLE_SUFFIXES[@]} -gt 0 ]]; then
      log_info "📋 Available templates from Terraform (${TF_TEMPLATES_FORMAT} format): ${AVAILABLE_SUFFIXES[*]}"
      if [[ ${#AVAILABLE_SUFFIXES[@]} -gt 2 ]]; then
        log_info "💡 Tip: Use --helm-suffix or --image-suffix to select different templates"
      fi
    fi
  else
    log_info "🏷️  Naming: ${RESOURCE_PREFIX}${HELM_SUFFIX}/ (charts), ${RESOURCE_PREFIX}${IMAGE_SUFFIX}/ (images)"
  fi
  
  # Parse arguments
  log_processing_step "argument_parsing" "main" "Parsing command line arguments"
  parse_arguments "$@"
  
  # Plan mode - show what would happen and exit (no AWS/Docker needed)
  if [[ "$PLAN_MODE" == true ]]; then
    run_plan
    exit 0
  fi
  
  # Get AWS account ID
  log_processing_step "aws_setup" "main" "Setting up AWS credentials and account information"
  get_account_id
  
  # Ensure Docker is running
  log_processing_step "docker_check" "main" "Verifying Docker daemon availability"
  if ! docker info >/dev/null 2>&1; then
    log_error_analysis "main" "DOCKER_UNAVAILABLE" "Docker daemon is not running" "Start Docker daemon and retry"
    exit 1
  fi
  log_processing_step "docker_check_success" "main" "Docker daemon is running and accessible"
  
  # Process charts or images based on mode
  local processing_start_time=$(date +%s)
  
  if [[ "$STANDALONE_IMAGE_MODE" == true ]]; then
    # Standalone image mode
    log_info "🖼️  Running in standalone image mode"
    start_operation_timer "standalone_image_processing"
    
    if [[ -n "$STANDALONE_IMAGE" ]]; then
      # Single image
      log_info "Processing single image: $STANDALONE_IMAGE"
      process_standalone_image "$STANDALONE_IMAGE"
    elif [[ -n "$STANDALONE_IMAGE_FILE" ]]; then
      # Multiple images from file
      log_info "Processing images from file: $STANDALONE_IMAGE_FILE"
      process_standalone_images_from_file "$STANDALONE_IMAGE_FILE"
    fi
    
    end_operation_timer "standalone_image_processing"
    
  elif [[ "$CLI_MODE" == true ]]; then
    # Command line mode - process single chart
    log_info "📦 Running in command line mode (Helm chart)"
    log_processing_step "cli_mode_processing" "$CLI_NAME" "Processing single chart: $CLI_CHART:$CLI_VERSION"
    start_operation_timer "single_chart_processing"
    process_chart "$CLI_NAME" "$CLI_REPOSITORY" "$CLI_CHART" "$CLI_VERSION"
    end_operation_timer "single_chart_processing"
    
  else
    # Configuration file mode - process charts AND standalone images
    log_info "📋 Running in configuration file mode"
    log_processing_step "config_mode_processing" "main" "Processing from configuration file: $CONFIG_FILE"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
      log_error_analysis "main" "CONFIG_FILE_NOT_FOUND" "Configuration file not found: $CONFIG_FILE" "Create configuration file or specify correct path"
      exit 1
    fi
    
    # Parse source registry authentication config
    parse_source_auth_config "$CONFIG_FILE"
    
    # Process Helm charts
    local total_charts=$(parse_config_file "$CONFIG_FILE" | wc -l)
    if [[ $total_charts -gt 0 ]]; then
      log_info "📦 Total Helm charts to process: $total_charts"
      
      start_operation_timer "batch_chart_processing"
      local chart_count=0
      
      # Parse configuration and process charts
      # NOTE: Charts always use default suffixes (helmchart/helmimage) for Terraform compatibility
      while IFS='|' read -r name repository chart version; do
        if [[ -n "$name" && -n "$repository" && -n "$chart" && -n "$version" ]]; then
          chart_count=$((chart_count + 1))
          log_info "📦 Processing chart $chart_count/$total_charts: $name"
          log_info "   Using default suffixes: helmchart=${HELM_SUFFIX}, helmimage=${IMAGE_SUFFIX}"
          
          local chart_start_time=$(date +%s)
          if ! process_chart "$name" "$repository" "$chart" "$version"; then
            log_error "Failed to process chart: $name"
            # Continue processing other charts instead of exiting
          fi
          local chart_end_time=$(date +%s)
          log_performance_metrics "individual_chart_processing" "$chart_start_time" "$chart_end_time" "Chart: $name"
        fi
      done < <(parse_config_file "$CONFIG_FILE")
      
      end_operation_timer "batch_chart_processing"
    else
      log_info "📦 No Helm charts found in configuration file"
    fi
    
    # Process standalone images
    local total_images=$(parse_standalone_images_from_config "$CONFIG_FILE" | wc -l)
    if [[ $total_images -gt 0 ]]; then
      log_info "🖼️  Total standalone images to process: $total_images"
      
      start_operation_timer "batch_standalone_image_processing"
      local image_count=0
      
      # Parse and process standalone images
      while IFS='|' read -r image suffix; do
        if [[ -n "$image" ]]; then
          image_count=$((image_count + 1))
          log_info "🖼️  Processing standalone image $image_count/$total_images: $image"
          
          # Override IMAGE_SUFFIX if specified in config
          original_image_suffix="$IMAGE_SUFFIX"
          original_image_prefix="$IMAGE_PREFIX"
          if [[ -n "$suffix" ]]; then
            IMAGE_SUFFIX="$suffix"
            IMAGE_PREFIX="${RESOURCE_PREFIX}${IMAGE_SUFFIX}"
            log_info "   Using custom suffix from config: $suffix (${IMAGE_PREFIX})"
          fi
          
          local image_start_time=$(date +%s)
          if ! process_standalone_image "$image"; then
            log_error "Failed to process standalone image: $image"
            # Continue processing other images instead of exiting
          fi
          local image_end_time=$(date +%s)
          log_performance_metrics "individual_image_processing" "$image_start_time" "$image_end_time" "Image: $image"
          
          # Restore original suffix
          IMAGE_SUFFIX="$original_image_suffix"
          IMAGE_PREFIX="$original_image_prefix"
        fi
      done < <(parse_standalone_images_from_config "$CONFIG_FILE")
      
      end_operation_timer "batch_standalone_image_processing"
    else
      log_info "🖼️  No standalone images found in configuration file"
    fi
  fi
  
  local processing_end_time=$(date +%s)
  log_performance_metrics "total_processing" "$processing_start_time" "$processing_end_time" "All charts and images"
  
  # Print summary
  log_processing_step "summary_generation" "main" "Generating processing summary and statistics"
  print_summary
  
  # Cleanup temporary files at the very end
  log_processing_step "cleanup" "main" "Cleaning up temporary files and directories"
  cleanup_temp_files
  
  log_info "⏱️  Script completed at $(date)"
  log_info "📊 Total script runtime: $(get_script_runtime)"
}

# Run main function with all arguments
main "$@"
