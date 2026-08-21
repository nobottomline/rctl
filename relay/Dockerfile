FROM golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36 AS build

ARG VERSION=dev
ARG COMMIT=unknown

WORKDIR /src
COPY relay/go.mod relay/go.sum* ./
RUN go mod download
COPY relay/ .
RUN CGO_ENABLED=0 go build -trimpath \
    -ldflags="-s -w -X github.com/nobottomline/rctl/relay/internal/relay.Version=${VERSION}" \
    -o /out/rctl-relay ./cmd/rctl-relay
RUN mkdir -p /out/data

FROM node:22-bookworm-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436 AS web

WORKDIR /src/web
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
COPY control /src/control
RUN npm run build

FROM gcr.io/distroless/static-debian12:nonroot@sha256:1b7b9f0f0e0a1d2155f531db587cc48ec26aaf97ab64364225f5bf18a054e66a

ARG VERSION=dev
ARG COMMIT=unknown
LABEL org.opencontainers.image.source="https://github.com/nobottomline/rctl" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT}" \
      org.opencontainers.image.licenses="MIT"

COPY --from=build /out/rctl-relay /usr/local/bin/rctl-relay
COPY --from=build --chown=nonroot:nonroot /out/data /data
COPY --from=web --chown=nonroot:nonroot /src/web/dist /app/web
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/rctl-relay"]
