# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the builder image
#     E.g.: docker.io/hexpm/elixir:1.20.2-erlang-29.0.3-debian-trixie-20260713-slim
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260713-slim - for the runner image
#     E.g.: docker.io/debian:trixie-20260713-slim
#
# Find builder and runner images on Docker Hub or on Hex's Build Server (Bob).
# We recommend using Bob's Web UI to find recent tags:
#
#   - https://bob.hex.pm/docker
#
# We suggest using the same Debian version for both the builder and runner images.
#
# We suggest Debian/Ubuntu instead of Alpine to avoid production compatibility issues
# (such as DNS resolution failures, and dynamically linked NIFs/precompiled binaries).
#
# For finding packages in Debian, search on https://packages.debian.org/.

ARG ELIXIR_VERSION=1.20.2
ARG OTP_VERSION=29.0.3
ARG DEBIAN_VERSION=trixie-20260713-slim
# The Debian release alone, for the Rust image of the rules NIF stage (keep
# in step with DEBIAN_VERSION: the NIF must match the runtime's glibc).
ARG DEBIAN_RELEASE=trixie

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# The FSDC rules engine NIF (native/rules: GoRules ZEN, Rust;
# docs/design/data-consistency.md), built in its own stage on the same
# Debian release as the runtime image. Dependencies are compiled first from
# the manifest and lock alone, so Docker's layer cache keeps them (several
# minutes on arm64) until Cargo.toml or Cargo.lock change.
FROM docker.io/rust:1.98.1-slim-${DEBIAN_RELEASE} AS rules-nif
WORKDIR /build
COPY native/rules/Cargo.toml native/rules/Cargo.lock ./
RUN mkdir src && echo "// dependency cache" > src/lib.rs && cargo build --release && rm -rf src
COPY native/rules/src src
RUN touch src/lib.rs && cargo build --release

# The FSDC rule editor (assets/rules_editor: GoRules JDM Editor, React,
# built with Vite; docs/design/data-consistency.md), loaded only on the
# rule editor page. npm ci from the lockfile; cached until it changes.
FROM docker.io/node:22.23.3-${DEBIAN_RELEASE}-slim AS rules-editor
WORKDIR /build/assets/rules_editor
COPY assets/rules_editor/package.json assets/rules_editor/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY assets/rules_editor/vite.config.js ./
COPY assets/rules_editor/src src
RUN npm run build

FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force \
  && mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv

# The prebuilt rules NIF; Rustler then only loads it (App.Rules.Engine).
COPY --from=rules-nif /build/target/release/librules.so priv/native/librules.so
ENV RULES_NIF_PREBUILT=1

COPY lib lib

# Compile the release
RUN mix compile

COPY assets assets

# The rule editor bundle, digested with the other static assets below.
COPY --from=rules-editor /build/priv/static/assets/rules_editor priv/static/assets/rules_editor

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Typst renders printed documents (App.Documents.Pdf,
# docs/design/documents-core.md): a static binary, pinned and checked
# against the release's published SHA-256, for this machine's architecture
# (the VPS builds natively on arm64; CI on amd64).
ARG TYPST_VERSION=0.15.1
ARG TYPST_SHA256_AMD64=a6d077d0a95eed5a2eba715b2dae06be954f624ccbf85758a03f389ded33118c
ARG TYPST_SHA256_ARM64=5aa8d74a3d906e60ea12a66ac2f37f8eef1b14cbad7182a745e393a10c23dcee
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl xz-utils \
  && arch="$(dpkg --print-architecture)" \
  && case "$arch" in \
       amd64) target=x86_64; sum="$TYPST_SHA256_AMD64" ;; \
       arm64) target=aarch64; sum="$TYPST_SHA256_ARM64" ;; \
       *) echo "no Typst build for $arch" && exit 1 ;; \
     esac \
  && curl -fsSL -o /tmp/typst.tar.xz \
       "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${target}-unknown-linux-musl.tar.xz" \
  && echo "$sum  /tmp/typst.tar.xz" | sha256sum -c - \
  && tar -xJf /tmp/typst.tar.xz -C /tmp \
  && install -m 0755 "/tmp/typst-${target}-unknown-linux-musl/typst" /usr/local/bin/typst \
  && rm -rf /tmp/typst* \
  && apt-get purge -y curl xz-utils && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/app ./

USER nobody

# If using an environment that doesn't automatically reap zombie processes, it is
# advised to add an init process such as tini via `apt-get install`
# above and adding an entrypoint. See https://github.com/krallin/tini for details
# ENTRYPOINT ["/tini", "--"]

CMD ["/app/bin/server"]
