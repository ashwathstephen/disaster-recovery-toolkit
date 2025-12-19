#!/usr/bin/env bash
#
# PostgreSQL Backup Script with S3 Upload
# Supports full and incremental backups with encryption
#
# Author: Ashwath Abraham Stephen
# Date: December 19, 2025
#

set -euo pipefail

# Default values
BACKUP_DIR="/tmp/postgres_backups"
RETENTION_DAYS=30
# Compression handled by gzip command
ENCRYPT=false
DRY_RUN=false
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Colors for output
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

PostgreSQL backup script with S3 upload support.

Options:
    -h, --host          Database host (required)
    -p, --port          Database port (default: 5432)
    -d, --database      Database name (required)
    -u, --user          Database user (default: postgres)
    -b, --s3-bucket     S3 bucket for backup storage
    -r, --retention     Retention days (default: 30)
    -e, --encrypt       Encrypt backup with GPG
    --dry-run           Show what would be done
    --help              Show this help message

Examples:
    $(basename "$0") -h db.example.com -d myapp -b my-backups
    $(basename "$0") -h localhost -d myapp -e --dry-run

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--host)
                DB_HOST="$2"
                shift 2
                ;;
            -p|--port)
                DB_PORT="$2"
                shift 2
                ;;
            -d|--database)
                DB_NAME="$2"
                shift 2
                ;;
            -u|--user)
                DB_USER="$2"
                shift 2
                ;;
            -b|--s3-bucket)
                S3_BUCKET="$2"
                shift 2
                ;;
            -r|--retention)
                RETENTION_DAYS="$2"
                shift 2
                ;;
            -e|--encrypt)
                ENCRYPT=true
                shift
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
    local missing=()

    command -v pg_dump >/dev/null 2>&1 || missing+=("pg_dump")
    command -v gzip >/dev/null 2>&1 || missing+=("gzip")
    
    if [[ -n "${S3_BUCKET:-}" ]]; then
        command -v aws >/dev/null 2>&1 || missing+=("aws-cli")
    fi

    if [[ "$ENCRYPT" == true ]]; then
        command -v gpg >/dev/null 2>&1 || missing+=("gpg")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    if [[ -z "${DB_HOST:-}" ]] || [[ -z "${DB_NAME:-}" ]]; then
        log_error "Database host and name are required"
        usage
    fi
}

create_backup() {
    local backup_file="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql"
    
    mkdir -p "$BACKUP_DIR"

    log_info "Starting backup of ${DB_NAME} from ${DB_HOST}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create backup: ${backup_file}.gz"
        return 0
    fi

    # Create backup
    PGPASSWORD="${PGPASSWORD:-}" pg_dump \
        -h "${DB_HOST}" \
        -p "${DB_PORT:-5432}" \
        -U "${DB_USER:-postgres}" \
        -d "${DB_NAME}" \
        --format=custom \
        --compress=0 \
        --file="$backup_file"

    # Compress
    log_info "Compressing backup..."
    gzip -9 "$backup_file"
    backup_file="${backup_file}.gz"

    # Encrypt if requested
    if [[ "$ENCRYPT" == true ]]; then
        log_info "Encrypting backup..."
        gpg --symmetric --cipher-algo AES256 "$backup_file"
        rm "$backup_file"
        backup_file="${backup_file}.gpg"
    fi

    local size
    size=$(du -h "$backup_file" | cut -f1)
    log_info "Backup created: $backup_file ($size)"
    
    echo "$backup_file"
}

upload_to_s3() {
    local backup_file="$1"
    local s3_path
    s3_path="s3://${S3_BUCKET}/postgres/${DB_NAME}/$(basename "$backup_file")"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would upload to: $s3_path"
        return 0
    fi

    log_info "Uploading to S3: $s3_path"
    aws s3 cp "$backup_file" "$s3_path" \
        --storage-class STANDARD_IA \
        --metadata "database=${DB_NAME},timestamp=${TIMESTAMP}"

    log_info "Upload complete"
}

cleanup_old_backups() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would clean up backups older than ${RETENTION_DAYS} days"
        return 0
    fi

    log_info "Cleaning up backups older than ${RETENTION_DAYS} days"
    
    # Local cleanup
    find "$BACKUP_DIR" -name "${DB_NAME}_*.sql*" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true

    # S3 cleanup (if lifecycle rules not configured)
    if [[ -n "${S3_BUCKET:-}" ]]; then
        local cutoff_date
        cutoff_date=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-"${RETENTION_DAYS}"d +%Y-%m-%d)
        
        aws s3 ls "s3://${S3_BUCKET}/postgres/${DB_NAME}/" 2>/dev/null | while read -r line; do
            local file_date
            file_date=$(echo "$line" | awk '{print $1}')
            local file_name
            file_name=$(echo "$line" | awk '{print $4}')
            
            if [[ "$file_date" < "$cutoff_date" ]] && [[ -n "$file_name" ]]; then
                log_info "Deleting old backup: $file_name"
                aws s3 rm "s3://${S3_BUCKET}/postgres/${DB_NAME}/${file_name}"
            fi
        done
    fi
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
    local backup_file=""
    local status="success"

    trap 'status="failed"; send_notification "$status" "Backup failed for ${DB_NAME}"' ERR

    backup_file=$(create_backup)

    if [[ -n "${S3_BUCKET:-}" ]] && [[ -n "$backup_file" ]]; then
        upload_to_s3 "$backup_file"
    fi

    cleanup_old_backups

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "Backup completed in ${duration} seconds"
    send_notification "$status" "Backup successful for ${DB_NAME} (${duration}s)"
}

main "$@"

