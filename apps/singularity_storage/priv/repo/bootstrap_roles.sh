#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${SINGULARITY_ROLE_PROVISIONER_DATABASE_URL:-}" ]]; then
  echo "SINGULARITY_ROLE_PROVISIONER_DATABASE_URL is required" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec 9< <(elixir "$script_dir/bootstrap_roles.exs")
unset SINGULARITY_ROLE_PROVISIONER_DATABASE_URL

PGSERVICEFILE=/dev/fd/9 \
  PGSERVICE=singularity_role_provisioner \
  exec psql \
    --no-psqlrc \
    --set=ON_ERROR_STOP=1 \
    --file="$script_dir/bootstrap_roles.sql"
