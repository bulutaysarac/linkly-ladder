# Tüm seviyelerde aynı Dockerfile. ARG SVC → cmd/$SVC derlenir. Distroless: shell yok, curl yok — saldırı yüzeyi küçük.
FROM golang:1.26-alpine AS build
ARG SVC=linkly
ARG VERSION=dev
WORKDIR /src
COPY go.mod ./
COPY go.su[m] ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w -X main.version=${VERSION}" -o /out/app ./cmd/${SVC}

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
