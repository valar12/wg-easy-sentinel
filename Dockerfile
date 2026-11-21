FROM alpine:3.24

RUN apk add --no-cache \
      bash ca-certificates coreutils curl docker-cli jq tzdata util-linux

WORKDIR /app
COPY wg-easy-sentinel.sh entrypoint.sh /app/
RUN chmod 755 /app/wg-easy-sentinel.sh /app/entrypoint.sh \
    && mkdir -p /app/data

ENV WG_CONTAINER_NAME=wg-easy \
    WG_INTERFACE=wg0 \
    VPN_NAME=wg-vpn \
    POLL_INTERVAL=60 \
    TIMEOUT_THRESHOLD=180

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/app/wg-easy-sentinel.sh", "--healthcheck"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/app/wg-easy-sentinel.sh", "--watch"]
