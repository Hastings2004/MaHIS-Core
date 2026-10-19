#!/bin/bash
# Take a hospital off the "internet" between hospitals and central, or bring
# it back. The hospital keeps working; its changes queue until it returns.
#   ./network.sh KCH off     ./network.sh KCH on     ./network.sh status
set -euo pipefail
site="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
action="${2:-status}"
net=mahis-sync_wan

if [ "${1:-}" = status ] || [ "$action" = status ]; then
  for s in kch zch; do
    if docker network inspect "$net" --format '{{range .Containers}}{{.Name}} {{end}}' | grep -q "mahis-sync-$s-agent-1"; then
      echo "${s^^}: online"
    else
      echo "${s^^}: OFFLINE"
    fi
  done
  exit 0
fi

case "$action" in
  off) docker network disconnect "$net" "mahis-sync-$site-agent-1" && echo "${site^^} is offline" ;;
  on)  docker network connect "$net" "mahis-sync-$site-agent-1" && echo "${site^^} is back online" ;;
  *)   echo "usage: $0 KCH|ZCH on|off   or   $0 status" >&2; exit 1 ;;
esac
