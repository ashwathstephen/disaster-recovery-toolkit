#!/usr/bin/env bash
#
# Kubernetes Cluster Backup with Velero
# Backs up namespaces, resources, and persistent volumes
#
# Author: Ashwath Abraham Stephen
# Date: December 19, 2025
#

set -euo pipefail

# Default values
BACKUP_NAME=""
CLUSTER_NAME=""
NAMESPACES=""
INCLUDE_VOLUMES=false
EXCLUDE_NAMESPACES="kube-system,kube-public,kube-node-lease"
TTL="720h"
DRY_RUN=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Kubernetes cluster backup using Velero.

Options:
    -c, --cluster           Cluster name/context (required)
    -n, --namespaces        Namespaces to backup (comma-separated, default: all)
    -v, --include-volumes   Include persistent volumes
    -e, --exclude           Namespaces to exclude (comma-separated)
    -t, --ttl               Backup TTL (default: 720h)
    --name                  Custom backup name
    --dry-run               Show what would be done
    --help                  Show this help message

Examples:
    $(basename "$0") -c production --include-volumes
    $(basename "$0") -c staging -n app1,app2 --dry-run

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--cluster)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            -n|--namespaces)
                NAMESPACES="$2"
                shift 2
                ;;
            -v|--include-volumes)
                INCLUDE_VOLUMES=true
                shift
                ;;
            -e|--exclude)
                EXCLUDE_NAMESPACES="$2"
                shift 2
                ;;
            -t|--ttl)
                TTL="$2"
                shift 2
                ;;
            --name)
                BACKUP_NAME="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

validate_requirements() {
    command -v velero >/dev/null 2>&1 || {
        log_error "velero CLI is required but not installed"
        exit 1
    }

    command -v kubectl >/dev/null 2>&1 || {
        log_error "kubectl is required but not installed"
        exit 1
    }

    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        log_error "Cluster name is required"
        usage
    fi

    # Set kubectl context
    kubectl config use-context "$CLUSTER_NAME" >/dev/null 2>&1 || {
        log_error "Failed to switch to context: $CLUSTER_NAME"
        exit 1
    }

    # Verify Velero is running
    kubectl get deployment -n velero velero >/dev/null 2>&1 || {
        log_error "Velero is not installed in the cluster"
        exit 1
    }
}

generate_backup_name() {
    if [[ -z "$BACKUP_NAME" ]]; then
        BACKUP_NAME="${CLUSTER_NAME}-${TIMESTAMP}"
    fi
    echo "$BACKUP_NAME"
}

create_backup() {
    local backup_name
    backup_name=$(generate_backup_name)
    
    local velero_args=("create" "backup" "$backup_name" "--ttl" "$TTL")

    # Add namespace filters
    if [[ -n "$NAMESPACES" ]]; then
        velero_args+=("--include-namespaces" "$NAMESPACES")
    else
        velero_args+=("--exclude-namespaces" "$EXCLUDE_NAMESPACES")
    fi

    # Include volumes
    if [[ "$INCLUDE_VOLUMES" == true ]]; then
        velero_args+=("--default-volumes-to-fs-backup")
    fi

    # Add labels
    velero_args+=("--labels" "cluster=${CLUSTER_NAME},created-by=dr-toolkit")

    log_info "Creating backup: $backup_name"
    log_info "Options: ${velero_args[*]}"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would execute: velero ${velero_args[*]}"
        return 0
    fi

    velero "${velero_args[@]}"

    # Wait for backup to complete
    log_info "Waiting for backup to complete..."
    local timeout=1800
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local phase
        phase=$(velero backup get "$backup_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        case "$phase" in
            "Completed")
                log_info "Backup completed successfully"
                break
                ;;
            "Failed"|"PartiallyFailed")
                log_error "Backup failed with phase: $phase"
                velero backup describe "$backup_name"
                exit 1
                ;;
            *)
                sleep 10
                elapsed=$((elapsed + 10))
                ;;
        esac
    done

    if [[ $elapsed -ge $timeout ]]; then
        log_error "Backup timed out after ${timeout} seconds"
        exit 1
    fi

    # Show backup details
    velero backup describe "$backup_name"
}

list_backups() {
    log_info "Existing backups for cluster: $CLUSTER_NAME"
    velero backup get --selector "cluster=${CLUSTER_NAME}"
}

send_notification() {
    local status="$1"
    local message="$2"

    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        local color
        [[ "$status" == "success" ]] && color="good" || color="danger"

        curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"attachments\":[{\"color\":\"${color}\",\"text\":\"${message}\"}]}" \
            >/dev/null
    fi
}

main() {
    parse_args "$@"
    validate_requirements

    local start_time
    start_time=$(date +%s)
    local status="success"

    trap 'status="failed"; send_notification "$status" "K8s backup failed for ${CLUSTER_NAME}"' ERR

    create_backup
    list_backups

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "Backup process completed in ${duration} seconds"
    send_notification "$status" "K8s backup successful for ${CLUSTER_NAME} (${duration}s)"
}

main "$@"

