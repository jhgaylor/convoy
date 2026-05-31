# Convoy builder image: the language toolchains + a tiny compile API. Runs in
# an isolated, no-secrets, no-egress pod (see k8s/builder-*.yaml). Built for
# linux/arm64 (the home-cloud cluster).
FROM debian:trixie-slim

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:/usr/local/tinygo/bin:/usr/local/go/bin:$PATH \
    TINYGO_VERSION=0.41.1 \
    GO_VERSION=1.25.6

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils nodejs npm \
  && rm -rf /var/lib/apt/lists/*

# Go (TinyGo needs a host Go toolchain).
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-arm64.tar.gz" -o /tmp/go.tgz \
  && tar -C /usr/local -xzf /tmp/go.tgz && rm /tmp/go.tgz

# TinyGo (self-contained release; bundles the LLVM tools it needs).
RUN curl -fsSL "https://github.com/tinygo-org/tinygo/releases/download/v${TINYGO_VERSION}/tinygo${TINYGO_VERSION}.linux-arm64.tar.gz" -o /tmp/tinygo.tgz \
  && tar -C /usr/local -xzf /tmp/tinygo.tgz && rm /tmp/tinygo.tgz

# Rust + the wasm target, installed to a world-readable location so the
# non-root runtime user can invoke rustc.
RUN curl --proto '=https' --tlsv1.2 -fsSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
  && rustup target add wasm32-unknown-unknown \
  && chmod -R a+rX /usr/local/rustup /usr/local/cargo

# AssemblyScript compiler (asc).
RUN npm install -g assemblyscript@0.28.17

COPY server.js /app/server.js
WORKDIR /app

# Non-root, unprivileged. Build scratch goes to an emptyDir mounted at /tmp.
RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin builder
USER 10001
ENV PORT=8080
EXPOSE 8080
CMD ["node", "/app/server.js"]
