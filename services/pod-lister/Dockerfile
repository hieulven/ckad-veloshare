FROM alpine:3.20

RUN apk add --no-cache bash curl jq \
    && addgroup -S -g 10001 podlister \
    && adduser -S -u 10001 -G podlister podlister

COPY list-pods.sh /usr/local/bin/list-pods.sh
RUN chmod +x /usr/local/bin/list-pods.sh

USER podlister

ENTRYPOINT ["/usr/local/bin/list-pods.sh"]
