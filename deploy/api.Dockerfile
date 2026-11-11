# The hello-web API image. Built by the build-api step in .woodpecker.yml on
# every push to main, and locally with:
#
#   docker build -f deploy/api.Dockerfile -t hello-web-api .
#
# Stage 1 compiles a static binary; stage 2 is distroless with no shell, run
# as the image's non-root user (uid 65532).

FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/hello-web ./cmd/hello-web

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
COPY --from=build /out/hello-web /usr/local/bin/hello-web
USER nonroot:nonroot
# The default HELLO_WEB_ADDR is :8080; set HELLO_WEB_ADDR to listen elsewhere.
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/hello-web"]
CMD ["serve"]
