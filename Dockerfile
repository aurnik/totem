# Totem server for Railway (or any container host). Build context is the
# repo root because the server depends on the local TotemKit package.
FROM swift:5.10-jammy AS build
COPY TotemKit /TotemKit
COPY Server /build
WORKDIR /build
RUN swift build -c release --product App

FROM swift:5.10-jammy-slim
COPY --from=build /build/.build/release/App /app/App
WORKDIR /app
# Railway injects PORT; persistent state lives on the mounted volume via
# DB_PATH and ONBOARD_DIR (see MINI_SETUP.md).
CMD /app/App serve --env production --hostname 0.0.0.0 --port ${PORT:-8080}
