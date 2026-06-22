# syntax=docker/dockerfile:1

# --- build stage ---------------------------------------------------------
FROM golang:1.26-alpine AS build
WORKDIR /src

# Cache deps first.
COPY go.mod go.sum ./
RUN go mod download

# Build a fully static binary (no cgo) so it runs on a scratch image.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o /out/server ./cmd/server

# --- runtime stage -------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /app
COPY --from=build /out/server /app/server

# Migrations are embedded in the binary (server/migrations) and run on boot,
# so no extra files are needed at runtime.
EXPOSE 8110
USER nonroot:nonroot
ENTRYPOINT ["/app/server"]
