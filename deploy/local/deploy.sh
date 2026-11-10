#!/bin/sh
# Build the current checkout and (re)deploy the local test environment.
set -eu
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  {
    echo "SECRET_KEY_BASE=$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
    echo "PHX_HOST=${PHX_HOST:-localhost}"
    echo "TEST_PORT=${TEST_PORT:-4120}"
  } > .env
fi

docker compose up -d --build

. ./.env
url="http://${PHX_HOST}:${TEST_PORT}/"
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null "$url"; then
    echo "Singularity test environment is up: $url ($(git rev-parse --short HEAD))"
    exit 0
  fi
  sleep 2
done

echo "Test environment did not respond at $url" >&2
docker compose logs --tail 50 app >&2
exit 1
