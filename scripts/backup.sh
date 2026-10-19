#!/usr/bin/env bash
# Dump the production Postgres (compose service "db") to a gzipped file, keep the
# newest $KEEP locally, and optionally copy to S3.
#   scripts/backup.sh                       # -> ./backups/budget-YYYYmmdd-HHMMSS.sql.gz
#   BACKUP_DIR=/var/backups/budget S3_URI=s3://my-bucket/budget scripts/backup.sh
# Cron (daily 03:15):  15 3 * * * cd /opt/budget && scripts/backup.sh >> /var/log/budget-backup.log 2>&1
# Restore: gunzip -c FILE | docker compose -f deploy/docker-compose.prod.yml exec -T db psql -U budget -d budget
set -euo pipefail
cd "$(dirname "$0")/.."
COMPOSE_FILE=${COMPOSE_FILE:-deploy/docker-compose.prod.yml}
ENV_FILE=${ENV_FILE:-deploy/.env.prod}
BACKUP_DIR=${BACKUP_DIR:-./backups}
KEEP=${KEEP:-14}
mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/budget-$(date +%Y%m%d-%H%M%S).sql.gz"
env_args=(); [[ -f "$ENV_FILE" ]] && env_args=(--env-file "$ENV_FILE")
docker compose -f "$COMPOSE_FILE" "${env_args[@]}" exec -T db \
  pg_dump -U budget -d budget --clean --if-exists --no-owner | gzip -9 > "$out.tmp"
mv "$out.tmp" "$out"
echo "backup: $out ($(du -h "$out" | cut -f1))"
if [[ -n "${S3_URI:-}" ]]; then
  aws s3 cp "$out" "${S3_URI%/}/$(basename "$out")" --only-show-errors
  echo "backup: uploaded to ${S3_URI%/}/$(basename "$out")"
fi
ls -1t "$BACKUP_DIR"/budget-*.sql.gz | tail -n +$((KEEP + 1)) | xargs -r rm -f
