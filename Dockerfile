# syntax=docker/dockerfile:1
#
# mosdns v5 + AdGuard Home combined image for MikroTik RouterOS containers
# Chain:  LAN clients -> AdGuard Home :53 (ad filtering + web UI :3000)
#                     -> mosdns :5335 (CN/foreign split DNS)
#
# Versions are injected by GitHub Actions (see .github/workflows/build.yml),
# but sane defaults are kept here so a plain `docker build` also works.

ARG MOSDNS_VERSION=v5.3.4
ARG ADGUARD_VERSION=v0.107.64

########################################
# Stage 1: download binaries and rules
########################################
FROM alpine:3.21 AS downloader
ARG TARGETARCH
ARG MOSDNS_VERSION
ARG ADGUARD_VERSION

RUN apk add --no-cache curl unzip tar

# mosdns (asset names use amd64/arm64, matching TARGETARCH)
RUN curl -fsSL -o /tmp/mosdns.zip \
      "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VERSION}/mosdns-linux-${TARGETARCH}.zip" \
 && mkdir -p /out/bin \
 && unzip -o /tmp/mosdns.zip -d /tmp/mosdns \
 && mv /tmp/mosdns/mosdns /out/bin/mosdns \
 && chmod +x /out/bin/mosdns

# AdGuard Home
RUN curl -fsSL -o /tmp/agh.tar.gz \
      "https://github.com/AdguardTeam/AdGuardHome/releases/download/${ADGUARD_VERSION}/AdGuardHome_linux_${TARGETARCH}.tar.gz" \
 && tar -xzf /tmp/agh.tar.gz -C /tmp \
 && mv /tmp/AdGuardHome/AdGuardHome /out/bin/AdGuardHome \
 && chmod +x /out/bin/AdGuardHome

# China / proxy rule lists, processed at BUILD time (see scripts/build-rules.py).
# Merging, dedup, suffix-collapse and the proxy reduction all happen here so
# the router only ever loads entries that can change a routing decision.
# python3 in its own layer so it stays cached across builds
RUN apk add --no-cache python3
COPY scripts/build-rules.py /tmp/build-rules.py

# RULES_VERSION exists ONLY to bust the layer cache. Without it, a weekly
# build where mosdns and AdGuardHome are unchanged would reuse the cached
# layer below and ship LAST WEEK's rule lists, while the release notes
# claim they were refreshed. The workflow passes the Loyalsoldier release
# tags; any change to either forces this layer to rebuild.
ARG RULES_VERSION=dev
RUN echo "rule lists built against: ${RULES_VERSION}" \
 && python3 /tmp/build-rules.py /out/rules

########################################
# Stage 2: runtime image
########################################
FROM alpine:3.21

RUN apk add --no-cache ca-certificates tzdata
ENV TZ=Asia/Shanghai

COPY --from=downloader /out/bin/mosdns       /usr/local/bin/mosdns
COPY --from=downloader /out/bin/AdGuardHome  /usr/local/bin/AdGuardHome
COPY --from=downloader /out/rules            /opt/defaults/rules

COPY config/mosdns.yaml       /opt/defaults/mosdns.yaml
COPY config/AdGuardHome.yaml  /opt/defaults/AdGuardHome.yaml
COPY entrypoint.sh            /entrypoint.sh
RUN chmod +x /entrypoint.sh

# /data holds all mutable state; mount it from RouterOS so
# config and settings survive image upgrades
VOLUME /data

EXPOSE 53/udp 53/tcp 3000/tcp 8080/tcp

HEALTHCHECK --interval=60s --timeout=5s \
  CMD nslookup -timeout=3 www.taobao.com 127.0.0.1 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
