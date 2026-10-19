#!/bin/bash
# One-time preparation of central's database: sync tables and the two
# registered hospitals. Safe to rerun.
set -euo pipefail
cd /app
export MYSQL_PWD="$DB_ROOT_PASSWORD"
db() { mysql -h"$DB_HOST" -uroot "$@"; }

echo "[central] waiting for the database (the first start loads the MaHIS data, a few minutes)..."
until db -e 'SELECT 1' mahis >/dev/null 2>&1; do sleep 3; done

if db -N -e "SHOW TABLES LIKE 'sync_sites'" mahis | grep -q sync_sites; then
  echo "[central] already prepared"
  exit 0
fi

export DATABASE_URL="mysql2://root:${DB_ROOT_PASSWORD}@${DB_HOST}:3306/mahis"
echo "[central] creating the sync tables and registering the hospitals"
bin/rails runner '
  require Rails.root.join("db/migrate/20261014000000_create_site_sync_tables.rb").to_s
  CreateSiteSyncTables.new.migrate(:up)
  ActiveRecord::Base.lease_connection.execute("INSERT IGNORE INTO schema_migrations (version) VALUES (\"20261014000000\")")
  SiteSync::Central.register_site("KCH", name: "Kamuzu Central Hospital", secret: ENV.fetch("KCH_SECRET"))
  SiteSync::Central.register_site("ZCH", name: "Zomba Central Hospital", secret: ENV.fetch("ZCH_SECRET"))'
echo "[central] ready"
