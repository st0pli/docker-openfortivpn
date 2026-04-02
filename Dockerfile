FROM alpine:latest

# 安装必要软件包
RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    iptables \
    iptables-legacy \
    openfortivpn \
    && mknod /dev/ppp c 108 0

# 创建必要目录
RUN mkdir -p /etc/openfortivpn /var/log/openfortivpn

# 复制启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
