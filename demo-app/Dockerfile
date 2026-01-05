FROM alpine:3.19

LABEL maintainer="DigitalOcean Solutions"
LABEL description="Simple demo app for GitHub Runner DOKS demo"

RUN apk add --no-cache curl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
