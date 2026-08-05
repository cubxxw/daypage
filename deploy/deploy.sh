#!/usr/bin/env bash
set -euo pipefail

compose() {
  docker compose -f deploy/compose.prod.yml --project-name daypage "$@"
}

install -m 600 .env web/.env.local
compose up -d --build --remove-orphans

container_id="$(compose ps -q web)"
if [[ -z "$container_id" ]]; then
  echo "DayPage web container was not created." >&2
  compose ps
  exit 1
fi

health_status=""
for _ in {1..45}; do
  health_status="$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "$container_id"
  )"
  if [[ "$health_status" == "healthy" ]]; then
    break
  fi
  if [[ "$health_status" == "unhealthy" || "$health_status" == "exited" ]]; then
    break
  fi
  sleep 2
done

if [[ "$health_status" != "healthy" ]]; then
  echo "DayPage failed its production health check (status: ${health_status:-unknown})." >&2
  compose ps
  compose logs --tail=200 web
  exit 1
fi

docker image prune -f
