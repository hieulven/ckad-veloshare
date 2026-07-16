FROM alpine:3.20

# postgresql-client provides psql 16 (matches the postgres:16 server) for the
# aggregate report queries. No curl/jq needed since this is no longer a health poll.
RUN apk add --no-cache bash postgresql-client \
    && addgroup -S fleet-monitor \
    && adduser -S -G fleet-monitor fleet-monitor

COPY report.sh /usr/local/bin/report.sh
RUN chmod +x /usr/local/bin/report.sh

USER fleet-monitor

ENTRYPOINT ["/usr/local/bin/report.sh"]
