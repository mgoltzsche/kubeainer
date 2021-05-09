FROM alpine:3.10
RUN apk add --update --no-cache bind bind-tools
COPY bind /etc/bind

EXPOSE 53

CMD ["named", "-c", "/etc/bind/named.conf", "-g", "-u", "named"]
