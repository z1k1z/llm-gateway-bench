FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /mock .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /mock /mock
EXPOSE 9000
USER nonroot
ENTRYPOINT ["/mock"]
