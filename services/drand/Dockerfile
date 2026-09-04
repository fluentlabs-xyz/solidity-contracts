# drand-publisher, built and shipped as one image.
#
#   forge build                                       # the ABI the crate compiles against
#   docker build -f services/drand/Dockerfile -t drand-publisher .
#
# The context is the repository root, not this directory: the publisher's `sol!`
# reads `out/DrandOracle.sol/DrandOracle.json`, forge's artifact, which lives
# outside the service. `.dockerignore` keeps everything else out of the context.
#
# Two stages, so the toolchain never reaches the running image. What ships is the
# binary, a C runtime and the CA bundle the relays are verified against — no
# shell, no package manager.

FROM rust:1-slim-bookworm AS build
WORKDIR /src
# The artifact the ABI is generated from, at the path the crate expects: four
# levels above its manifest, which is the repository root.
COPY out/DrandOracle.sol/DrandOracle.json out/DrandOracle.sol/DrandOracle.json
WORKDIR /src/services/drand
# Manifests first: dependencies are the slow half of the build and they change
# only when these files do, so editing a source reuses the cached layer.
COPY services/drand/Cargo.toml services/drand/Cargo.lock ./
COPY services/drand/crates/beacon/Cargo.toml crates/beacon/
COPY services/drand/crates/publisher/Cargo.toml crates/publisher/
RUN mkdir -p crates/beacon/src crates/publisher/src \
 && echo 'fn main() {}' > crates/publisher/src/main.rs \
 && touch crates/beacon/src/lib.rs crates/publisher/src/lib.rs \
 && cargo build --release --locked \
 && rm -rf crates/beacon/src crates/publisher/src
COPY services/drand/crates crates
# The stub left its fingerprints in the cache; without this cargo keeps them and
# ships an empty binary.
RUN touch crates/beacon/src/lib.rs crates/publisher/src/lib.rs crates/publisher/src/main.rs \
 && cargo build --release --locked

FROM gcr.io/distroless/cc-debian12
COPY --from=build /src/services/drand/target/release/drand-publisher /usr/local/bin/drand-publisher
# Rounds are addressed by wall-clock time; UTC everywhere removes one way to be wrong.
ENV TZ=UTC RUST_LOG=drand_publisher=info
USER nonroot
ENTRYPOINT ["/usr/local/bin/drand-publisher"]
