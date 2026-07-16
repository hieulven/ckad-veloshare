FROM alpine:3.20

RUN apk add --no-cache curl jq bash \
    && addgroup -S fleet-monitor \
    && adduser -S -G fleet-monitor fleet-monitor

COPY monitor.sh /usr/local/bin/monitor.sh
RUN chmod +x /usr/local/bin/monitor.sh

USER fleet-monitor

ENTRYPOINT ["/usr/local/bin/monitor.sh"]
