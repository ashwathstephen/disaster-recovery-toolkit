#!/usr/bin/env bash
#
# Disaster Recovery Test Script
# Validates backup integrity and restore procedures
#
# Author: Ashwath Abraham Stephen
# Date: December 19, 2025
#

set -euo pipefail

# Default values
ENVIRONMENT=""
TEST_TYPE="full"
NOTIFY_CHANNEL="slack"
DRY_RUN=false
REPORT_FILE="/tmp/dr_test_$(date +%Y%m%d_%H%M%S).log"

# Test results
declare -A TEST_RESULTS

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    local msg="[INFO] $1"
    echo -e "${GREEN}${msg}${NC}"
    echo "$msg" >> "$REPORT_FILE"
}

log_warn() {
    local msg="[WARN] $1"
    echo -e "${YELLOW}${msg}${NC}"
    echo "$msg" >> "$REPORT_FILE"
}

log_error() {
    local msg="[ERROR] $1"
    echo -e "${RED}${msg}${NC}" >&2
    echo "$msg" >> "$REPORT_FILE"
}

log_test() {
    local test_name="$1"
    local status="$2"
    local details="${3:-}"
    
    if [[ "$status" == "PASS" ]]; then
        echo -e "${GREEN}[PASS]${NC} $test_name"
    else
        echo -e "${RED}[FAIL]${NC} $test_name: $details"
    fi
    
    TEST_RESULTS["$test_name"]="$status"
    echo "[$status] $test_name: $details" >> "$REPORT_FILE"
}

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Run disaster recovery tests and validations.

Options:
    -e, --environment   Target environment (required: staging/production)
    -t, --type          Test type (full/backup/restore/connectivity)
    -n, --notify        Notification channel (slack/pagerduty/email)
    --dry-run           Show what would be tested
    --help              Show this help message

Examples:
    $(basename "$0") -e staging -t full
    $(basename "$0") -e production -t backup --notify slack

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -e|--environment)
                ENVIRONMENT="$2"
                shift 2
                ;;
            -t|--type)
                TEST_TYPE="$2"
                shift 2
                ;;
            -n|--notify)
                NOTIFY_CHANNEL="$2"
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
    if [[ -z "${ENVIRONMENT:-}" ]]; then
        log_error "Environment is required"
        usage
    fi

    if [[ ! "$ENVIRONMENT" =~ ^(staging|production)$ ]]; then
        log_error "Environment must be 'staging' or 'production'"
        exit 1
    fi
}

test_s3_backup_access() {
    log_info "Testing S3 backup bucket access..."
    
    local bucket="${BACKUP_S3_BUCKET:-backup-bucket-${ENVIRONMENT}}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_test "S3 Access" "SKIP" "Dry run mode"
        return
    fi

    if aws s3 ls "s3://${bucket}" >/dev/null 2>&1; then
        local backup_count
        backup_count=$(aws s3 ls "s3://${bucket}/" --recursive | wc -l)
        log_test "S3 Access" "PASS" "Bucket accessible, $backup_count objects"
    else
        log_test "S3 Access" "FAIL" "Cannot access bucket: $bucket"
    fi
}

test_backup_freshness() {
    log_info "Testing backup freshness..."
    
    local bucket="${BACKUP_S3_BUCKET:-backup-bucket-${ENVIRONMENT}}"
    local max_age_hours=24

    if [[ "$DRY_RUN" == true ]]; then
        log_test "Backup Freshness" "SKIP" "Dry run mode"
        return
    fi

    local latest_backup
    latest_backup=$(aws s3 ls "s3://${bucket}/" --recursive 2>/dev/null | sort | tail -1 | awk '{print $1, $2}')
    
    if [[ -n "$latest_backup" ]]; then
        local backup_date
        backup_date=$(echo "$latest_backup" | awk '{print $1}')
        local now_epoch
        now_epoch=$(date +%s)
        local backup_epoch
        backup_epoch=$(date -d "$backup_date" +%s 2>/dev/null || date -jf "%Y-%m-%d" "$backup_date" +%s 2>/dev/null || echo 0)
        
        if [[ $backup_epoch -gt 0 ]]; then
            local age_hours=$(( (now_epoch - backup_epoch) / 3600 ))
            
            if [[ $age_hours -le $max_age_hours ]]; then
                log_test "Backup Freshness" "PASS" "Latest backup is ${age_hours}h old"
            else
                log_test "Backup Freshness" "FAIL" "Latest backup is ${age_hours}h old (max: ${max_age_hours}h)"
            fi
        else
            log_test "Backup Freshness" "WARN" "Could not parse backup date"
        fi
    else
        log_test "Backup Freshness" "FAIL" "No backups found"
    fi
}

test_database_connectivity() {
    log_info "Testing database connectivity..."

    local db_hosts=(
        "${DB_PRIMARY_HOST:-primary-db.${ENVIRONMENT}.internal}"
        "${DB_REPLICA_HOST:-replica-db.${ENVIRONMENT}.internal}"
    )

    if [[ "$DRY_RUN" == true ]]; then
        log_test "Database Connectivity" "SKIP" "Dry run mode"
        return
    fi

    for host in "${db_hosts[@]}"; do
        if timeout 5 bash -c "echo > /dev/tcp/${host}/5432" 2>/dev/null; then
            log_test "DB Connect: $host" "PASS" "Port 5432 reachable"
        else
            log_test "DB Connect: $host" "FAIL" "Cannot reach port 5432"
        fi
    done
}

test_kubernetes_backup() {
    log_info "Testing Kubernetes backup status..."

    if [[ "$DRY_RUN" == true ]]; then
        log_test "K8s Backup Status" "SKIP" "Dry run mode"
        return
    fi

    if command -v velero >/dev/null 2>&1; then
        local latest_backup
        latest_backup=$(velero backup get --selector "cluster=${ENVIRONMENT}" -o json 2>/dev/null | \
            jq -r '.items | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')
        
        if [[ -n "$latest_backup" ]]; then
            local phase
            phase=$(velero backup get "$latest_backup" -o jsonpath='{.status.phase}' 2>/dev/null)
            
            if [[ "$phase" == "Completed" ]]; then
                log_test "K8s Backup Status" "PASS" "Latest: $latest_backup ($phase)"
            else
                log_test "K8s Backup Status" "FAIL" "Latest: $latest_backup ($phase)"
            fi
        else
            log_test "K8s Backup Status" "WARN" "No backups found"
        fi
    else
        log_test "K8s Backup Status" "SKIP" "Velero not installed"
    fi
}

test_dns_failover() {
    log_info "Testing DNS failover configuration..."

    local domains=(
        "api.${ENVIRONMENT}.example.com"
        "app.${ENVIRONMENT}.example.com"
    )

    if [[ "$DRY_RUN" == true ]]; then
        log_test "DNS Failover" "SKIP" "Dry run mode"
        return
    fi

    for domain in "${domains[@]}"; do
        if host "$domain" >/dev/null 2>&1; then
            local ips
            ips=$(host "$domain" | grep -c "has address")
            if [[ $ips -ge 2 ]]; then
                log_test "DNS: $domain" "PASS" "$ips A records (failover configured)"
            else
                log_test "DNS: $domain" "WARN" "Only $ips A record (no failover)"
            fi
        else
            log_test "DNS: $domain" "FAIL" "DNS resolution failed"
        fi
    done
}

generate_report() {
    log_info "Generating DR test report..."

    local total=0
    local passed=0
    local failed=0
    local skipped=0

    for test in "${!TEST_RESULTS[@]}"; do
        total=$((total + 1))
        case "${TEST_RESULTS[$test]}" in
            PASS) passed=$((passed + 1)) ;;
            FAIL) failed=$((failed + 1)) ;;
            SKIP|WARN) skipped=$((skipped + 1)) ;;
        esac
    done

    echo ""
    echo "========================================="
    echo "DR Test Report - $(date)"
    echo "Environment: $ENVIRONMENT"
    echo "========================================="
    echo "Total Tests: $total"
    echo "Passed: $passed"
    echo "Failed: $failed"
    echo "Skipped/Warnings: $skipped"
    echo "========================================="
    echo ""
    echo "Detailed results saved to: $REPORT_FILE"
}

send_notification() {
    local status="$1"
    local passed="$2"
    local failed="$3"

    local message="DR Test Results for ${ENVIRONMENT}: ${passed} passed, ${failed} failed"

    case "$NOTIFY_CHANNEL" in
        slack)
            if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
                local color
                [[ $failed -eq 0 ]] && color="good" || color="danger"
                
                curl -s -X POST "$SLACK_WEBHOOK_URL" \
                    -H 'Content-Type: application/json' \
                    -d "{\"attachments\":[{\"color\":\"${color}\",\"text\":\"${message}\"}]}" \
                    >/dev/null
            fi
            ;;
        pagerduty)
            if [[ $failed -gt 0 ]] && [[ -n "${PAGERDUTY_KEY:-}" ]]; then
                curl -s -X POST "https://events.pagerduty.com/v2/enqueue" \
                    -H 'Content-Type: application/json' \
                    -d "{\"routing_key\":\"${PAGERDUTY_KEY}\",\"event_action\":\"trigger\",\"payload\":{\"summary\":\"${message}\",\"severity\":\"error\",\"source\":\"dr-test\"}}" \
                    >/dev/null
            fi
            ;;
    esac
}

run_tests() {
    echo "Starting DR tests for environment: $ENVIRONMENT"
    echo "Test type: $TEST_TYPE"
    echo "Report file: $REPORT_FILE"
    echo ""

    case "$TEST_TYPE" in
        full)
            test_s3_backup_access
            test_backup_freshness
            test_database_connectivity
            test_kubernetes_backup
            test_dns_failover
            ;;
        backup)
            test_s3_backup_access
            test_backup_freshness
            test_kubernetes_backup
            ;;
        connectivity)
            test_database_connectivity
            test_dns_failover
            ;;
        *)
            log_error "Unknown test type: $TEST_TYPE"
            exit 1
            ;;
    esac
}

main() {
    parse_args "$@"
    validate_requirements

    local start_time
    start_time=$(date +%s)

    # Initialize report
    {
        echo "DR Test Report - $(date)"
        echo "Environment: $ENVIRONMENT"
        echo "Test Type: $TEST_TYPE"
        echo "---"
    } > "$REPORT_FILE"

    run_tests
    generate_report

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "DR tests completed in ${duration} seconds"

    # Count results
    local passed=0
    local failed=0
    for result in "${TEST_RESULTS[@]}"; do
        [[ "$result" == "PASS" ]] && passed=$((passed + 1))
        [[ "$result" == "FAIL" ]] && failed=$((failed + 1))
    done

    send_notification "complete" "$passed" "$failed"

    # Exit with error if any tests failed
    [[ $failed -eq 0 ]]
}

main "$@"

