# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04 AS build

ARG SIMPLEXMQ_REF=c5184b72cdd48d9ecede01eff4f639f9d2b0f0f4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libgmp3-dev libnuma-dev libpq-dev libssl-dev llvm-18 llvm-18-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ENV BOOTSTRAP_HASKELL_GHC_VERSION=9.6.3
ENV BOOTSTRAP_HASKELL_CABAL_VERSION=3.12.1.0
ENV BOOTSTRAP_HASKELL_INSTALL_NO_STACK=true
ENV BOOTSTRAP_HASKELL_INSTALL_NO_STACK_HOOK=true
ENV PATH=/root/.cabal/bin:/root/.ghcup/bin:$PATH

RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org \
      | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 sh \
    && ghcup set ghc "$BOOTSTRAP_HASKELL_GHC_VERSION" \
    && ghcup set cabal "$BOOTSTRAP_HASKELL_CABAL_VERSION"

RUN git clone --filter=blob:none https://github.com/eXsoria/simplexmq.git /src/simplexmq \
    && git -C /src/simplexmq checkout "$SIMPLEXMQ_REF" \
    && test "$(git -C /src/simplexmq rev-parse HEAD)" = "$SIMPLEXMQ_REF"

WORKDIR /src/simplexmq
RUN cabal update \
    && cabal build -fserver_postgres exe:ntf-server \
    && install -D -m 0755 "$(cabal list-bin -fserver_postgres exe:ntf-server)" /out/ntf-server

FROM ubuntu:24.04

LABEL org.opencontainers.image.source="https://github.com/eXsoria/simplexmq/tree/c5184b72cdd48d9ecede01eff4f639f9d2b0f0f4"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgmp10 libnuma1 libpq5 libssl3 openssl \
    && ln -sf /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/ntf-server /usr/local/bin/ntf-server
COPY server/ntf/entrypoint.sh /usr/local/bin/xauxat-ntf-entrypoint

EXPOSE 443
STOPSIGNAL SIGINT
ENTRYPOINT ["/usr/local/bin/xauxat-ntf-entrypoint"]
