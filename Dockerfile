FROM --platform=$BUILDPLATFORM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETARCH
ARG TARGETOS
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -ldflags "-s -w -X main.version=${VERSION}" -o rtor2tran-migrator .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /app/rtor2tran-migrator /usr/local/bin/rtor2tran-migrator
ENTRYPOINT ["rtor2tran-migrator"]
