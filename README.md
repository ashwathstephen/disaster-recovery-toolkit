# Disaster Recovery Toolkit

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash)](https://www.gnu.org/software/bash/)

Comprehensive disaster recovery scripts and runbooks for backup, restore, and failover operations. Designed for multi-cloud and Kubernetes environments.

## Features

- Automated database backup and restore
- Kubernetes cluster backup with Velero
- S3/GCS cross-region replication verification
- RTO/RPO validation scripts
- Runbook templates for common scenarios
- Slack/PagerDuty integration for alerts

## Components

| Component | Description |
|-----------|-------------|
| scripts/ | Bash scripts for backup/restore operations |
| playbooks/ | Ansible playbooks for DR automation |
| terraform/ | Infrastructure for DR environments |
| kubernetes/ | K8s manifests for backup solutions |
| docs/ | Runbooks and procedures |

## Quick Start

### Database Backup

```bash
# PostgreSQL backup to S3
./scripts/backup_postgres.sh --host db.example.com --database myapp --s3-bucket backups

# MySQL backup
./scripts/backup_mysql.sh --host db.example.com --database myapp --s3-bucket backups
```

### Kubernetes Backup

```bash
# Full cluster backup with Velero
./scripts/k8s_backup.sh --cluster production --include-volumes

# Restore namespace
./scripts/k8s_restore.sh --backup backup-20251219 --namespace myapp
```

### DR Test

```bash
# Run full DR test
./scripts/dr_test.sh --environment staging --notify slack
```

## Testing

```bash
# Validate scripts
shellcheck scripts/*.sh

# Dry run backup
./scripts/backup_postgres.sh --dry-run
```

## Author

Ashwath Abraham Stephen
Senior DevOps Engineer | [LinkedIn](https://linkedin.com/in/ashwathstephen) | [GitHub](https://github.com/ashwathstephen)

## License

MIT License - see [LICENSE](LICENSE) for details.

