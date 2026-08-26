FROM hexpm/elixir:1.18.4-erlang-28.4.3-debian-trixie-20260610-slim@sha256:4098ebb001f526e4891ce6fe900d2057ceed9fe18f7c4351595c3c39efe53251 AS build

ENV LANG=C.UTF-8 \
    MIX_ENV=prod

WORKDIR /app

RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && printf '%s\n' \
      'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260610T000000Z trixie main' \
      'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260610T000000Z trixie-updates main' \
      'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian-security/20260610T000000Z trixie-security main' \
      > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install --yes --no-install-recommends build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mix local.hex 2.5.1 --force \
    && mix local.rebar rebar3 \
      https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 \
      --sha512 0d00494d849fdc521a55142278d1f6ba552954fbd65b80d40df8022f594f05d6c99ed1d731bc263691a04176e11d4c6e126c56ba20dca19c5e42d4ffab2e7e36 \
      --force \
    && /root/.mix/elixir/1-18-otp-28/rebar3 version

COPY mix.exs mix.lock package.json package-lock.json ./
COPY build ./build
COPY config/config.exs config/config.exs
COPY apps/singularity_core/mix.exs apps/singularity_core/
COPY apps/singularity_domains/mix.exs apps/singularity_domains/
COPY apps/singularity_ingest/mix.exs apps/singularity_ingest/
COPY apps/singularity_retrieval/mix.exs apps/singularity_retrieval/
COPY apps/singularity_runtime/mix.exs apps/singularity_runtime/
COPY apps/singularity_storage/mix.exs apps/singularity_storage/
COPY apps/singularity_web/mix.exs apps/singularity_web/

ENV HEX_HTTP_CONCURRENCY=1 \
    HEX_HTTP_TIMEOUT=120

RUN mix deps.get --only prod \
    && mix deps.compile

COPY config ./config
COPY apps ./apps
COPY rel ./rel

RUN NPM_EX_LINK_STRATEGY=copy mix npm.install --frozen \
    && mix npm.verify \
    && mix compile \
    && MIX_ENV=prod mix assets.deploy \
    && MIX_ENV=prod mix release singularity \
    && rm -f _build/prod/rel/singularity/releases/COOKIE

FROM debian:trixie-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132 AS runtime

ARG VERSION=0.0.0-dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="Singularity" \
      org.opencontainers.image.description="Private knowledge core" \
      org.opencontainers.image.source="https://github.com/gsmlg-opt/Singularity" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

ENV LANG=C.UTF-8 \
    HOME=/tmp/singularity \
    PORT=4000 \
    RELEASE_TMP=/tmp/singularity \
    RELEASE_DISTRIBUTION=none \
    ERL_CRASH_DUMP=/tmp/singularity/erl_crash.dump \
    SINGULARITY_STORAGE_ROOT=/var/lib/singularity/storage \
    SINGULARITY_BACKUP_ROOT=/var/lib/singularity/backups

RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && printf '%s\n' \
      'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260610T000000Z trixie main' \
      'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian/20260610T000000Z trixie-updates main' \
      'deb [check-valid-until=no signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://snapshot.debian.org/archive/debian-security/20260610T000000Z trixie-security main' \
      > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates libstdc++6 libncurses6 libssl3t64 \
    && rm -f /usr/bin/openssl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 singularity \
    && useradd --uid 10001 --gid 10001 --home-dir /tmp/singularity --shell /usr/sbin/nologin singularity \
    && mkdir -p /tmp/singularity /var/lib/singularity/storage /var/lib/singularity/backups \
    && chown -R 10001:10001 /tmp/singularity /var/lib/singularity

WORKDIR /app

COPY --from=build /app/_build/prod/rel/singularity ./

USER 10001:10001

EXPOSE 4000

ENTRYPOINT ["/app/bin/singularity"]
CMD ["start"]
