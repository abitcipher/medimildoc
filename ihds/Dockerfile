# IHDS — reference-data service (docs/design/reference-data-and-files.md).
# The seed files are baked into the image: a new seed version is a new
# image, and every start rebuilds the in-memory index from them. Learned
# values (organisational names entered before) are the only state, kept
# on the /data volume.

ARG RUST_VERSION=1.98
ARG DEBIAN_VERSION=trixie-slim

FROM docker.io/rust:${RUST_VERSION}-slim-trixie AS builder
WORKDIR /src
# Dependencies first, so source edits don't rebuild them.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && touch src/lib.rs \
    && cargo build --release --locked && rm -rf src
COPY src ./src
RUN touch src/main.rs src/lib.rs && cargo build --release --locked

FROM docker.io/debian:${DEBIAN_VERSION}
RUN useradd --system --uid 10001 ihds && mkdir /data && chown ihds /data
WORKDIR /app
COPY --from=builder /src/target/release/ihds /app/ihds
COPY seed/*.json /app/seed/
USER ihds
# /data: learned values (append-only file); mount a volume there.
ENV IHDS_SEED_DIR=/app/seed IHDS_ADDR=0.0.0.0:4100 IHDS_DATA_DIR=/data
EXPOSE 4100
HEALTHCHECK --interval=10s --timeout=5s --retries=5 CMD ["/app/ihds", "healthcheck"]
CMD ["/app/ihds"]
