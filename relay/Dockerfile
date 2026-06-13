FROM golang:1.22-bookworm AS build

WORKDIR /src
COPY relay/go.mod relay/go.sum* ./
RUN go mod download
COPY relay/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/rctl-relay ./cmd/rctl-relay
RUN mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/rctl-relay /usr/local/bin/rctl-relay
COPY --from=build --chown=nonroot:nonroot /out/data /data
COPY web /app/web
VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/rctl-relay"]
