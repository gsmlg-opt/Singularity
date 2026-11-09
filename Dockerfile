# hexpm 没有发布 Elixir 1.18.x + OTP 29 的镜像；这里用 OTP 与 devenv 一致（29.1.2）的最近可用 tag
ARG ELIXIR_IMAGE=hexpm/elixir:1.20.5-erlang-29.1.2-debian-trixie-20261104-slim
ARG RUNNER_IMAGE=debian:trixie-slim

FROM ${ELIXIR_IMAGE} AS beam-tools

FROM ubuntu:26.04 AS web-assets-builder
ENV MIX_ENV=prod DUSKMOON_NATIVE_MODE=precompiled LANG=C.UTF-8
WORKDIR /app
COPY --from=beam-tools /usr/local /usr/local
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git unzip \
    libncurses6 libodbc2 libsctp1 libssl3t64 libstdc++6 netbase \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock package.json package-lock.json bunfig.toml ./
COPY config ./config
COPY apps/singularity/mix.exs ./apps/singularity/mix.exs
COPY apps/singularity_web/mix.exs apps/singularity_web/package.json ./apps/singularity_web/
RUN mix deps.get --only prod && mix deps.compile
RUN mix npm.install --frozen
COPY . .
RUN mix assets.deploy

FROM ${ELIXIR_IMAGE} AS builder
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates curl git unzip \
  && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/singularity/mix.exs ./apps/singularity/mix.exs
COPY apps/singularity_web/mix.exs ./apps/singularity_web/mix.exs
RUN mix deps.get --only prod && mix deps.compile
COPY . .
COPY --from=web-assets-builder /app/apps/singularity_web/priv/static ./apps/singularity_web/priv/static
RUN mix release singularity

FROM ${RUNNER_IMAGE}
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libstdc++6 locales openssl \
  && rm -rf /var/lib/apt/lists/*
ENV LANG=C.UTF-8 MIX_ENV=prod
WORKDIR /app
RUN useradd --system --home /app singularity && chown singularity /app
COPY --from=builder --chown=singularity /app/_build/prod/rel/singularity ./
USER singularity
EXPOSE 4000
CMD ["/app/bin/server"]
