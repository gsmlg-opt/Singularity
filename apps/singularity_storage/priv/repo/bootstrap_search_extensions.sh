#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" != 1 || ! "$1" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
  echo "search extension bootstrap requires an application database name" >&2
  exit 1
fi

case "$1" in
  postgres|template0|template1)
    echo "search extension bootstrap requires an application database name" >&2
    exit 1
    ;;
esac

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! search_extension_service="$(elixir "$script_dir/bootstrap_roles.exs" 2>/dev/null)"; then
  echo "search extension bootstrap failed" >&2
  exit 1
fi

exec 9< <(printf '%s\n' "$search_extension_service")
unset search_extension_service SINGULARITY_ROLE_PROVISIONER_DATABASE_URL

PGSERVICEFILE=/dev/fd/9 \
  PGSERVICE=singularity_role_provisioner \
  exec psql \
    --no-psqlrc \
    --set=ON_ERROR_STOP=1 \
    --dbname="$1" \
    --file="$script_dir/bootstrap_search_extensions.sql"
