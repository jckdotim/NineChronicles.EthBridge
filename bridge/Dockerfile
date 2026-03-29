# syntax=docker/dockerfile:1
# Multi-arch Dockerfile: supports linux/amd64 and linux/arm64 (t4g.nano/Graviton2)
# Build: docker buildx build --platform linux/arm64 -t <image> .
# Build multi-arch: docker buildx build --platform linux/amd64,linux/arm64 -t <image> .

ARG BUILDPLATFORM=linux/amd64
ARG TARGETPLATFORM=linux/amd64

FROM --platform=$BUILDPLATFORM node:20.4-alpine AS build-env

ARG TARGETARCH

COPY . /build
WORKDIR /build
RUN npm install
RUN yarn tsc --project tsconfig.production.json

# Download the correct pre-built SQLite binary for the target architecture.
# Using pre-built NAPI bindings avoids native compilation in Alpine (musl libc).
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      wget -q https://github.com/TryGhost/node-sqlite3/releases/download/v5.1.2/napi-v6-linux-musl-arm64.tar.gz \
        && tar -xzf napi-v6-linux-musl-arm64.tar.gz \
        && mv ./napi-v6-linux-musl-arm64 /build/node_modules/sqlite3/lib/binding; \
    else \
      wget -q https://github.com/TryGhost/node-sqlite3/releases/download/v5.1.2/napi-v6-linux-musl-x64.tar.gz \
        && tar -xzf napi-v6-linux-musl-x64.tar.gz \
        && mv ./napi-v6-linux-musl-x64 /build/node_modules/sqlite3/lib/binding; \
    fi

FROM --platform=$TARGETPLATFORM node:20.4-alpine

COPY --from=build-env /build/dist /app
COPY --from=build-env /build/node_modules /app/node_modules
COPY package.json /app

WORKDIR /app
ENTRYPOINT ["npx", "tsx", "src/index.js"]
