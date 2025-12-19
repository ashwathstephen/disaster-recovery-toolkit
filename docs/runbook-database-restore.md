# Database Restore Runbook

**Last Updated:** December 19, 2025
**Author:** Ashwath Abraham Stephen
**Review Frequency:** Quarterly

## Overview

This runbook covers the procedure for restoring PostgreSQL databases from backup in case of data loss, corruption, or disaster recovery scenarios.

## Prerequisites

- AWS CLI configured with appropriate permissions
- Access to backup S3 bucket
- Database admin credentials
- GPG key (if backups are encrypted)

## Severity Levels

| Level | Response Time | Description |
|-------|---------------|-------------|
| SEV1 | Immediate | Complete database loss, production down |
| SEV2 | 30 minutes | Partial data loss, degraded service |
| SEV3 | 4 hours | Non-critical data loss, no service impact |

## Procedure

### Step 1: Assess the Situation

1. Identify the scope of data loss
2. Determine the point-in-time for recovery (RPO)
3. Notify stakeholders via Slack channel #incidents

```bash
# Check current database status
psql -h $DB_HOST -U postgres -c "SELECT pg_is_in_recovery();"
```

### Step 2: Identify Available Backups

```bash
# List available backups
aws s3 ls s3://backup-bucket/postgres/myapp/ --human-readable

# Find specific backup
aws s3 ls s3://backup-bucket/postgres/myapp/ | grep "20251219"
```

### Step 3: Download Backup

```bash
# Download latest backup
aws s3 cp s3://backup-bucket/postgres/myapp/myapp_latest.sql.gz /tmp/

# If encrypted
gpg --decrypt /tmp/myapp_latest.sql.gz.gpg > /tmp/myapp_latest.sql.gz
```

### Step 4: Prepare Target Database

```bash
# Stop application connections
kubectl scale deployment myapp --replicas=0 -n production

# Create restore database
psql -h $DB_HOST -U postgres -c "CREATE DATABASE myapp_restore;"
```

### Step 5: Restore Database

```bash
# Decompress and restore
gunzip -c /tmp/myapp_latest.sql.gz | pg_restore \
  -h $DB_HOST \
  -U postgres \
  -d myapp_restore \
  --no-owner \
  --verbose

# Verify row counts
psql -h $DB_HOST -U postgres -d myapp_restore -c "
  SELECT schemaname, relname, n_live_tup 
  FROM pg_stat_user_tables 
  ORDER BY n_live_tup DESC 
  LIMIT 10;"
```

### Step 6: Validate Data

```bash
# Run data validation queries
psql -h $DB_HOST -U postgres -d myapp_restore << EOF
  SELECT COUNT(*) FROM users;
  SELECT COUNT(*) FROM orders WHERE created_at > NOW() - INTERVAL '24 hours';
  SELECT MAX(updated_at) FROM audit_log;
EOF
```

### Step 7: Swap Databases

```bash
# Rename databases (requires no active connections)
psql -h $DB_HOST -U postgres << EOF
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'myapp';
  ALTER DATABASE myapp RENAME TO myapp_old;
  ALTER DATABASE myapp_restore RENAME TO myapp;
EOF
```

### Step 8: Restart Application

```bash
# Scale application back up
kubectl scale deployment myapp --replicas=3 -n production

# Verify connectivity
kubectl logs -l app=myapp -n production --tail=50
```

### Step 9: Post-Restore Validation

- [ ] Application health checks passing
- [ ] User login working
- [ ] Recent transactions visible
- [ ] No error spikes in monitoring
- [ ] Performance baseline restored

## Rollback

If restore fails or data is incorrect:

```bash
# Revert to old database
psql -h $DB_HOST -U postgres << EOF
  ALTER DATABASE myapp RENAME TO myapp_failed;
  ALTER DATABASE myapp_old RENAME TO myapp;
EOF

# Restart application
kubectl rollout restart deployment myapp -n production
```

## Post-Incident

1. Update incident timeline in PagerDuty
2. Schedule post-mortem within 48 hours
3. Update this runbook with lessons learned
4. Verify backup schedule is running

## Contacts

| Role | Name | Contact |
|------|------|---------|
| On-call DBA | See PagerDuty | #dba-oncall |
| Platform Lead | Ashwath Stephen | @ashwath |
| Incident Manager | See rotation | #incidents |

