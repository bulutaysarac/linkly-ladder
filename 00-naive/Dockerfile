# Tüm seviyelerde aynı Dockerfile. ARG SVC → cmd/$SVC derlenir. Distroless: shell yok, curl yok — saldırı yüzeyi küçük.
#
# BuildKit cache mount'ları (--mount=type=cache) katman önbelleğinden FARKLIDIR: katman önbelleği
# kaynak değişince düşer, cache mount ise DERLEME ÇIKTILARINI (go build cache + modül deposu)
# build'ler arasında taşır. Bu merdivende tek satırlık bir kod değişikliği tüm bağımlılıkları
# (pgx, otel, prometheus...) yeniden derletiyordu — seviye başına 10+ dakika. Ölçüldü ve düzeltildi.
FROM golang:1.26-alpine AS build
ARG SVC=linkly
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY go.su[m] ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app ./cmd/${SVC}

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
