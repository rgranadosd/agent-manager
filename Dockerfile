# Build stage — runs natively on the build platform (M1/M2 arm64)
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder

ARG TARGETOS
ARG TARGETARCH

WORKDIR /app

COPY agent-manager-service/go.mod agent-manager-service/go.sum ./
COPY agent-manager-service/clients/openchoreosvc/auth ./clients/openchoreosvc/auth

RUN go mod download

COPY agent-manager-service/ .

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build \
    -a \
    -installsuffix cgo \
    -ldflags="-w -s" \
    -o /go/bin/agent-manager-service \
    -buildvcs=false

# Runtime stage — alpine:3.21 is arm64 compatible
FROM alpine:3.21

RUN apk add --no-cache ca-certificates tzdata bash openssl

RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

RUN mkdir -p /app/clients/openchoreosvc/client /app/keys /app/data/certs && chown -R 1000:1000 /app

COPY --from=builder --chown=1000:1000 /go/bin/agent-manager-service /go/bin/agent-manager-service
COPY --from=builder --chown=1000:1000 /app/clients/openchoreosvc/client/default-openapi-schema.yaml /app/clients/openchoreosvc/client/default-openapi-schema.yaml
COPY --from=builder --chown=1000:1000 /app/scripts/gen_keys.sh /app/scripts/gen_keys.sh
COPY --from=builder --chown=1000:1000 /app/entrypoint.sh /app/entrypoint.sh

RUN chmod +x /app/entrypoint.sh /app/scripts/gen_keys.sh

USER 1000:1000

WORKDIR /app

ENV GODEBUG=x509negativeserial=1

# 8080 = main API server, 9243 = internal HTTPS server
EXPOSE 8080 9243

ENTRYPOINT ["/app/entrypoint.sh"]