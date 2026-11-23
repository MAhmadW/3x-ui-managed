# ========================================================
# Stage: Frontend (Vite)
# ========================================================
FROM --platform=$BUILDPLATFORM node:26-alpine AS frontend
WORKDIR /src/frontend
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci
COPY frontend/ ./
COPY internal/web/translation /src/internal/web/translation
RUN npm run build

# ========================================================
# Stage: Builder
# ========================================================
FROM golang:1.27-alpine AS builder
WORKDIR /app
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk --no-cache --update add \
  build-base \
  gcc \
  curl \
  unzip

COPY . .
COPY --from=frontend /src/internal/web/dist ./internal/web/dist

ENV CGO_ENABLED=1
ENV CGO_CFLAGS="-D_LARGEFILE64_SOURCE"
RUN go build -ldflags "-w -s" -o build/x-ui main.go
RUN ./DockerInit.sh "$TARGETARCH" "$TARGETVARIANT"

# ========================================================
# Stage: Final Image of 3x-ui
# ========================================================
FROM alpine AS upstream
ENV TZ=Asia/Tehran
WORKDIR /app

RUN apk add --no-cache --update \
  ca-certificates \
  tzdata \
  fail2ban \
  bash \
  curl \
  openssl

COPY --from=builder /app/build/ /app/
COPY --from=builder /app/DockerEntrypoint.sh /app/
COPY --from=builder /app/x-ui.sh /usr/bin/x-ui
COPY --from=builder /app/internal/web/translation /app/internal/web/translation


# Configure fail2ban
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

RUN chmod +x \
  /app/DockerEntrypoint.sh \
  /app/x-ui \
  /usr/bin/x-ui

ENV XUI_IN_DOCKER="true"
ENV XUI_MAIN_FOLDER="/app"
ENV XUI_ENABLE_FAIL2BAN="true"
ENV XUI_DB_TYPE=""
ENV XUI_DB_DSN=""
EXPOSE 2053
# No VOLUME: some managed platforms (Railway, for one) reject images that
# declare one. Mount /etc/x-ui at deploy time to keep the database.
CMD [ "./x-ui" ]
ENTRYPOINT [ "/app/DockerEntrypoint.sh" ]

# ========================================================
# Stage: managed — single-port image (Caddy in front of the
# panel, the subscription server and Xray inbounds).
# This is the default build target; use --target upstream
# for the stock 3x-ui image.
# ========================================================
FROM upstream AS managed
RUN apk add --no-cache caddy
COPY managed/ /app/managed/
RUN chmod +x /app/managed/entrypoint.sh
ENV XUI_ENABLE_FAIL2BAN="false"
ENV XUI_SKIP_HSTS="true"
ENV XUI_PORT="2053"
ENV XDG_DATA_HOME="/etc/x-ui/caddy/data"
ENV XDG_CONFIG_HOME="/etc/x-ui/caddy/config"
ENV PROXY_MODE="edge"
ENV PORT="8080"
ENV PANEL_PATH="/panel/"
ENV VPN_PATH_PREFIX="/vpn"
EXPOSE 8080 443
ENTRYPOINT [ "/app/managed/entrypoint.sh" ]
