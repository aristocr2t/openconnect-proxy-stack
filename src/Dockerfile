FROM alpine:3.21

RUN apk add --no-cache openconnect bash iproute2 iptables python3 openssl socat

COPY src/proxy.py /proxy.py
COPY src/connect.py /connect.py
COPY src/mtg /usr/local/bin/mtg
RUN chmod +x /proxy.py /connect.py /usr/local/bin/mtg

COPY src/start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
