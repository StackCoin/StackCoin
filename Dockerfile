# syntax=docker/dockerfile:1.7

# Find eligible builder and runner images on Docker Hub. We use Debian for both
# stages so the release stays small while still avoiding Alpine-specific DNS
# issues.
#
ARG ELIXIR_VERSION=1.20.1
ARG OTP_VERSION=29.0.2
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Keep downloaded .debs around so cache mounts can reuse them between builds.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
  && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
       > /etc/apt/apt.conf.d/keep-cache

# install build dependencies
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
  mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex/packages,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    --mount=type=cache,target=/app/_build,sharing=locked \
  mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN --mount=type=cache,target=/root/.hex/packages,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,sharing=locked \
    --mount=type=cache,target=/app/_build,sharing=locked \
  mix deps.compile

COPY priv priv

COPY lib lib

COPY assets assets

# compile assets
RUN --mount=type=cache,target=/app/_build,sharing=locked \
  mix assets.deploy

# Compile the release
RUN --mount=type=cache,target=/app/_build,sharing=locked \
  mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN --mount=type=cache,target=/app/_build,sharing=locked \
  mix release --overwrite \
  && rm -rf /app/release \
  && mkdir -p /app/release \
  && cp -a /app/_build/${MIX_ENV}/rel/stackcoin /app/release/stackcoin

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
  && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' \
       > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder /app/release/stackcoin/. ./

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/bin/sh", "-c", "/app/bin/migrate && /app/bin/server"]
