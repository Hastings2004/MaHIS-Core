#!/bin/bash
# One-time preparation of a hospital site's database, run by the site's
# "init" container before its API and sync agent start. Safe to rerun: a
# database that already has the sync tables is left alone.
#
# Needs: DB_HOST, DB_ROOT_PASSWORD, MAHIS_SITE_LOCATION_ID, and the site's
# sync settings (MAHIS_SYNC_ROLE, MAHIS_SITE_CODE, SITE_SYNC_TRIGGER_DEFINER).
set -euo pipefail
cd /app
export MYSQL_PWD="$DB_ROOT_PASSWORD"
db() { mysql -h"$DB_HOST" -uroot "$@"; }

echo "[$MAHIS_SITE_CODE] waiting for the database (the first start loads the MaHIS data, a few minutes)..."
until db -e 'SELECT 1' mahis >/dev/null 2>&1; do sleep 3; done

if db -N -e "SHOW TABLES LIKE 'sync_state'" mahis | grep -q sync_state; then
  echo "[$MAHIS_SITE_CODE] already prepared"
  exit 0
fi

# As the database administrator.
export DATABASE_URL="mysql2://root:${DB_ROOT_PASSWORD}@${DB_HOST}:3306/mahis"

echo "[$MAHIS_SITE_CODE] creating the sync tables"
bin/rails runner '
  require Rails.root.join("db/migrate/20261014000000_create_site_sync_tables.rb").to_s
  CreateSiteSyncTables.new.migrate(:up)
  ActiveRecord::Base.lease_connection.execute("INSERT IGNORE INTO schema_migrations (version) VALUES (\"20261014000000\")")'

echo "[$MAHIS_SITE_CODE] setting the facility (location $MAHIS_SITE_LOCATION_ID)"
# Every site starts from one copy of the MaHIS data: make this one a real
# facility, with its users working there.
db mahis -e "
  DELETE FROM global_property WHERE property = 'current_health_center_id';
  INSERT INTO global_property (property, property_value, uuid)
  VALUES ('current_health_center_id', '$MAHIS_SITE_LOCATION_ID', UUID());
  UPDATE users SET location_id = $MAHIS_SITE_LOCATION_ID;
  UPDATE users SET authentication_token = 'demo-token', token_expiry_time = NOW() + INTERVAL 1 YEAR
  WHERE username = 'admin';"

echo "[$MAHIS_SITE_CODE] installing capture triggers and queueing existing rows"
bin/rake site_sync:install
bin/rake site_sync:snapshot

echo "[$MAHIS_SITE_CODE] restricting the app and sync database accounts"
bin/rake "site_sync:grants[mahis_app,mahis_sync]" 2>/dev/null | grep -E '^(REVOKE|GRANT)' | db

echo "[$MAHIS_SITE_CODE] ready"
