FROM alpine:3.20
RUN apk add --no-cache socat iproute2 iptables iptables-legacy nftables bash
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
