# Docker build and deployment

This guide describes a single-host Elixir release behind an HTTPS reverse proxy,
with an operator-managed PostgreSQL database and persistent local asset storage.
It uses the existing Dockerfile; Docker Compose is not required.

The active `0.2.0` product remains subject to its phase and release acceptance
gates. A successful container build or startup is not product acceptance. Do not
enable unfinished knowledge workflows or activate production until the approved
release and backup-compatibility gates pass. No version bump, image publication,
release, or deployment is implied by these instructions.

## 1. Build the images

Run from the repository root of the exact source revision you intend to deploy.
Use a clean checkout for a deployable artifact; a dirty checkout must be labeled
as such, not represented as an exact committed revision.

```bash
test -z "$(git status --porcelain)"
SINGULARITY_REVISION=$(git rev-parse HEAD)
SINGULARITY_IMAGE="singularity:$(git rev-parse --short=12 HEAD)"
SINGULARITY_ADMIN_IMAGE="singularity-admin:$(git rev-parse --short=12 HEAD)"

docker build \
  --build-arg VERSION=local \
  --build-arg REVISION="$SINGULARITY_REVISION" \
  --tag "$SINGULARITY_IMAGE" .

# Local, temporary administrative tooling; do not publish this image.
docker build --target build --tag "$SINGULARITY_ADMIN_IMAGE" .
```

`VERSION` and `REVISION` are OCI metadata, not application version overrides.
The release version comes from the repository. Builds use pinned base-image
digests, Debian snapshots, Hex/Rebar versions, and dependency lockfiles. The
builder compiles the native PDF process guardian and web assets; the runtime
contains the release and Poppler, without Mix, Node, or a C compiler. Do not pass
credentials as build arguments or copy environment files into the image.

The default build targets the Docker host architecture. Validate each platform
separately before publishing a multi-platform image; a successful amd64 build
does not prove arm64 support.

Inspect the resulting artifact:

```bash
docker image inspect "$SINGULARITY_IMAGE" \
  --format '{{.Id}} {{.Architecture}} {{.Config.User}} {{json .Config.Entrypoint}}'
docker run --rm --entrypoint /bin/sh "$SINGULARITY_IMAGE" -ec '
  test -x /app/bin/singularity
  test -x /app/lib/singularity_ingest-*/priv/poppler_guardian
  test -s /app/lib/singularity_web-*/priv/static/cache_manifest.json
  test ! -e /app/releases/COOKIE
  pdfinfo -v
  pdftotext -v
'
```

The runtime user is `10001:10001`. Keep the image ID (or registry digest, when
separately authorized to publish) with the source revision and verification
record. Deploy that exact artifact, not a mutable tag rebuilt later.

## 2. Provision PostgreSQL and database roles

Use a dedicated PostgreSQL installation; PostgreSQL 17 matches the development
environment. The examples below assume a private Docker network named
`singularity`, with the database reachable as `postgres:5432`. Create the network
if it does not already exist and attach your operator-managed PostgreSQL
container to it. Do not expose PostgreSQL publicly. For an external database,
replace this hostname with a container-reachable address and configure and verify
PostgreSQL transport security for that environment. `localhost` in a database
URL refers to the application container itself.

```bash
docker network create singularity
```

Role provisioning is an explicit privileged operation, separate from application
startup. On an administrative host with `psql`, configure a protected libpq
service called `singularity_admin` for a PostgreSQL superuser. Then run:

```bash
psql 'service=singularity_admin' --no-psqlrc --set ON_ERROR_STOP=1 \
  --file apps/singularity_storage/priv/repo/bootstrap_roles.sql
psql 'service=singularity_admin' --no-psqlrc --set ON_ERROR_STOP=1
```

In the interactive session, assign strong, distinct passwords using `\password`
(which avoids putting passwords into SQL command arguments or shell history):

```text
\password singularity_migration
\password singularity_web
\password singularity_pre_auth
\password singularity_dispatcher
\password singularity_worker
```

For a new installation, create the database and allow the non-login table owner
to create migration schemas:

```sql
CREATE DATABASE singularity OWNER singularity_migration;
GRANT CREATE ON DATABASE singularity TO singularity_table_owner;
```

The provisioning script creates nine managed roles and enforces their attributes
and memberships; it does not create a database or assign passwords. It resets
memberships involving the managed role names, so review it before running against
an existing cluster. Never use a superuser URL for an application role, and never
give all five connections the same login. Database ownership and the `CREATE`
grant above are required by the migrations' existing table-owner role switching.

## 3. Configure secrets and persistent storage

Create the host directories before mounting them. The application must be able
to write as UID/GID 10001; use real directories, not symlinks beneath storage
roots.

```bash
sudo install -d -m 0700 -o 10001 -g 10001 \
  /srv/singularity/storage /srv/singularity/backups
```

Using a secure editor, create `/srv/singularity/singularity.env`, owned by the
operator and readable only by that operator (mode `0600`). Docker env files use
literal `KEY=value` lines, without shell `export` or surrounding quotes:

```dotenv
PHX_HOST=knowledge.example.com
PORT=4000
SECRET_KEY_BASE=REPLACE_WITH_GENERATED_SECRET
SINGULARITY_AUDIT_FINGERPRINT_SECRET=REPLACE_WITH_BASE64_SECRET
SINGULARITY_MUTATION_FINGERPRINT_SECRET=REPLACE_WITH_BASE64_SECRET
SINGULARITY_STORAGE_ROOT=/var/lib/singularity/storage
SINGULARITY_BACKUP_ROOT=/var/lib/singularity/backups
SINGULARITY_MIGRATION_DATABASE_URL=ecto://singularity_migration:URL_ENCODED_PASSWORD@postgres:5432/singularity
SINGULARITY_DATABASE_URL=ecto://singularity_web:URL_ENCODED_PASSWORD@postgres:5432/singularity
SINGULARITY_PRE_AUTH_DATABASE_URL=ecto://singularity_pre_auth:URL_ENCODED_PASSWORD@postgres:5432/singularity
SINGULARITY_DISPATCHER_DATABASE_URL=ecto://singularity_dispatcher:URL_ENCODED_PASSWORD@postgres:5432/singularity
SINGULARITY_WORKER_DATABASE_URL=ecto://singularity_worker:URL_ENCODED_PASSWORD@postgres:5432/singularity
SINGULARITY_MAX_CONCURRENT_UPLOADS=2
```

Generate independent secrets on the administrative host, not inside the runtime
image (which intentionally does not include the `openssl` executable):

```bash
openssl rand -base64 48  # SECRET_KEY_BASE
openssl rand -base64 32  # audit fingerprint secret
openssl rand -base64 32  # mutation fingerprint secret
```

The audit secret must decode to at least 32 bytes; the mutation secret must decode
to exactly 32 bytes. Preserve these values across restarts and upgrades. Percent
encode special characters in database URL passwords. All five URLs are currently
required by production configuration, including the task-only MigrationRepo;
protect the env file accordingly. Upload concurrency must be positive and below
the RequestRepo pool size (currently 10); the default is 2.

Persist the entire storage root, including staging, finalized, and object data,
the entire backup root, and PostgreSQL data. Replacing a container must not replace
these directories. Do not bake user data, secrets, or backups into an image.

## 4. Run migrations explicitly

For upgrades, stop the existing application and take a consistent database and
asset-storage backup first. Only one migration process may run at a time. The
runtime does not automatically migrate on startup.

```bash
docker run --rm --network singularity \
  --env-file /srv/singularity/singularity.env \
  --mount type=bind,src=/srv/singularity/storage,dst=/var/lib/singularity/storage \
  --mount type=bind,src=/srv/singularity/backups,dst=/var/lib/singularity/backups \
  "$SINGULARITY_IMAGE" eval '
    Application.load(:singularity_storage)
    {:ok, _, _} = Ecto.Migrator.with_repo(
      Singularity.Storage.MigrationRepo,
      fn repo ->
        Ecto.Migrator.run(
          repo,
          Application.app_dir(:singularity_storage, "priv/repo/migrations"),
          :up,
          all: true
        )
      end
    )
  '
```

The explicit migration path is essential: the files belong to
`singularity_storage/priv/repo/migrations`, not `priv/migration_repo/migrations`.
Do not proceed when this command fails. No `Singularity.Release.migrate/0` helper
exists; do not substitute an undocumented command.

## 5. Verify roles and bootstrap the first owner

Use the temporary builder image from the same source for the existing Mix admin
tasks. These tasks are not available in the slim production image:

```bash
docker run --rm --network singularity \
  --env-file /srv/singularity/singularity.env \
  "$SINGULARITY_ADMIN_IMAGE" mix run --no-start -e '
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Singularity.Storage.MigrationRepo.start_link()
    Mix.Task.run("singularity.db.verify_roles")
  '

docker run --rm -it --network singularity \
  --env-file /srv/singularity/singularity.env \
  "$SINGULARITY_ADMIN_IMAGE" mix do app.config, singularity.bootstrap_owner
```

Starting MigrationRepo explicitly makes role verification use the configured
network URL; the task's standalone fallback expects a development Unix socket.
`--no-start` avoids starting the web server and background workers for this
administrative check.

Bootstrap prompts for a password without echoing it. Never pass a password in
command arguments or environment variables. The existing configured defaults are
login `owner@singularity.local` and display name `Owner`; the task does not accept
login/email/display-name options. This is a one-time operation, not an automatic
startup hook. Keep the existing bootstrap and unlock behavior unchanged. There
is no public registration flow.

## 6. Start the container behind HTTPS

```bash
docker run --detach --name singularity --restart unless-stopped \
  --network singularity \
  --env-file /srv/singularity/singularity.env \
  --publish 127.0.0.1:4000:4000 \
  --mount type=bind,src=/srv/singularity/storage,dst=/var/lib/singularity/storage \
  --mount type=bind,src=/srv/singularity/backups,dst=/var/lib/singularity/backups \
  "$SINGULARITY_IMAGE"
```

The release listens on HTTP port 4000 inside the container. `PHX_HOST` is the
public hostname; production URLs use HTTPS on port 443. `PHX_SERVER` is not
required. Session cookies are secure, so plain HTTP is only a local liveness
probe, not a usable production login endpoint.

Terminate TLS with your existing reverse proxy and forward WebSocket upgrades.
For example, a Caddy instance on the same host can use:

```caddyfile
knowledge.example.com {
    reverse_proxy 127.0.0.1:4000
}
```

Configure DNS and certificate issuance for that hostname, and expose only the
proxy's HTTPS endpoint to users. If the proxy is containerized, connect it to the
private application network and proxy `singularity:4000` instead of host
loopback. The release defaults to disabled Erlang distribution; do not expose
EPMD or distribution ports. Its release cookie is generated at runtime rather
than embedded in the image.

## 7. Check operation and maintain the installation

```bash
docker inspect singularity --format '{{.State.Status}} {{.State.ExitCode}}'
curl --fail --silent --show-error http://127.0.0.1:4000/login >/dev/null
docker logs --tail 50 singularity
```

There is no dedicated `/health` route. A successful `/login` response proves HTTP
liveness, not database readiness, extraction correctness, or product acceptance.
Require successful migrations and role verification as separate checks. Before
opening the installation to users, verify HTTPS login, the established unlock
step, and access to `/assets` manually under the release's acceptance protocol.
Do not put user content, credentials, or sensitive log output into verification
records.

For upgrades, retain the previous exact image, stop the application, take a
consistent PostgreSQL plus complete filesystem backup, run the new image's
migrations, and start that exact image with the existing mounts and secrets.
Migrations are forward-only; reverting an image is not a database rollback.
Recovery may require restoring the matching database and asset snapshot together.
Application backup/export does not replace this operator backup while canonical
backup V3 support or its required fail-closed guard remains unaccepted.

Do not delete storage volumes during replacement or cleanup. Remove temporary
admin images only after administrative work is complete. Publication, production
activation, automated browser acceptance, and release tagging remain separate
authorized operations.

See the [local container verification record](2026-10-01-docker-verification.md)
for the platform and checks exercised when this guide was added.
