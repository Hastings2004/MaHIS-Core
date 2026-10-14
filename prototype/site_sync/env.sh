#!/bin/bash
# Environment for one prototype node. Usage: source env.sh central|a|b
#
# All three nodes use a private MySQL on 127.0.0.1:3307 (see bin/mysql_start)
# so nothing touches the developer's main database. Sites reach central through
# the link simulator (bin/link), which can cut, slow or drop acknowledgements.

PROTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export APP_DIR="$(cd "$PROTO_DIR/../.." && pwd)"
export PROTO_DIR
export PROTO_MYSQL_PORT=3307
export PROTO_TMP="$APP_DIR/tmp/site_sync_mysql"
export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"
export RAILS_ENV=development
export SITE_SYNC_ADMIN_TOKEN=demo-admin-token
# Demo secrets; real sites get theirs from rake site_sync:register_site.
export SITEA_SECRET=site-a-demo-secret-0000000000000000000000000000000000000000
export SITEB_SECRET=site-b-demo-secret-0000000000000000000000000000000000000000

case "$1" in
  central)
    export DATABASE_URL="mysql2://proto:proto@127.0.0.1:${PROTO_MYSQL_PORT}/mahis_central"
    export MAHIS_SYNC_ROLE=central
    export NODE_PORT=3200
    export SITE_SYNC_CHAOS=1   # allows the demo's simulated power cut
    unset MAHIS_SITE_CODE SITE_SYNC_CENTRAL_URL SITE_SYNC_SECRET
    ;;
  a|A)
    export DATABASE_URL="mysql2://proto:proto@127.0.0.1:${PROTO_MYSQL_PORT}/mahis_site_a"
    export MAHIS_SYNC_ROLE=site MAHIS_SITE_CODE=SITEA NODE_PORT=3201
    export SITE_SYNC_CENTRAL_URL="http://127.0.0.1:3211"   # via link simulator
    # After a restore the site has a new secret, kept in tmp/.
    export SITE_SYNC_SECRET="${SITE_SYNC_SECRET_OVERRIDE:-$(cat "$PROTO_TMP/secret_SITEA" 2>/dev/null || echo "$SITEA_SECRET")}"
    ;;
  b|B)
    export DATABASE_URL="mysql2://proto:proto@127.0.0.1:${PROTO_MYSQL_PORT}/mahis_site_b"
    export MAHIS_SYNC_ROLE=site MAHIS_SITE_CODE=SITEB NODE_PORT=3202
    export SITE_SYNC_CENTRAL_URL="http://127.0.0.1:3212"   # via link simulator
    export SITE_SYNC_SECRET="${SITE_SYNC_SECRET_OVERRIDE:-$(cat "$PROTO_TMP/secret_SITEB" 2>/dev/null || echo "$SITEB_SECRET")}"
    ;;
  *)
    echo "usage: source env.sh central|a|b" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

export SITE_SYNC_LOG_LEVEL="${SITE_SYNC_LOG_LEVEL:-info}"
# Smaller batches keep one site's catch-up from holding central's feed lock
# for long (production default: 1000).
export SITE_SYNC_BATCH_EVENTS="${SITE_SYNC_BATCH_EVENTS:-200}"

# Short demo intervals (production: 30 s / 120 s / 300 s).
export SITE_SYNC_PUSH_EVERY="${SITE_SYNC_PUSH_EVERY:-2}"
export SITE_SYNC_PULL_EVERY="${SITE_SYNC_PULL_EVERY:-3}"
export SITE_SYNC_HEARTBEAT_EVERY="${SITE_SYNC_HEARTBEAT_EVERY:-5}"
export SITE_SYNC_MAX_BACKOFF="${SITE_SYNC_MAX_BACKOFF:-10}"

proto_mysql() {
  mysql --no-defaults -uroot -h127.0.0.1 -P"$PROTO_MYSQL_PORT" "$@"
}
