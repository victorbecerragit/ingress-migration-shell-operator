# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Multi-arch build: supports linux/amd64 and linux/arm64.
# Build with:
#   docker buildx build --platform linux/amd64,linux/arm64 -t <image> .
# ---------------------------------------------------------------------------
FROM ghcr.io/flant/shell-operator:v1.4.16

ARG TARGETARCH=amd64
ARG INGRESS2GATEWAY_VERSION=v0.5.0

RUN apk add --no-cache bash curl jq gettext

# Install kubectl for the target architecture
RUN KUBE_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt) && \
    curl -fsSL \
      "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
      -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install ingress2gateway for the target architecture.
# ingress2gateway release tarballs use x86_64 / arm64 naming (not amd64).
RUN ARCH_NAME=$([ "$TARGETARCH" = "amd64" ] && echo "x86_64" || echo "arm64") && \
    curl -fsSL \
      "https://github.com/kubernetes-sigs/ingress2gateway/releases/download/${INGRESS2GATEWAY_VERSION}/ingress2gateway_Linux_${ARCH_NAME}.tar.gz" \
      | tar -xz -C /usr/local/bin ingress2gateway && \
    chmod +x /usr/local/bin/ingress2gateway

# ---------------------------------------------------------------------------
# Smoke-test: copy scripts into the image at build time so we can verify each
# hook's --config path exits 0 before the image is pushed.
# At runtime, the Helm chart overwrites /hooks/ via a ConfigMap volume mount.
# ---------------------------------------------------------------------------
COPY scripts/ /hooks/
# Copy library scripts to /usr/local/lib/hooks/ so shell-operator does not
# discover them as hooks (it only scans /hooks/).
RUN mkdir -p /usr/local/lib/hooks && \
  cp /hooks/lib/common.sh        /usr/local/lib/hooks/common.sh        && \
  cp /hooks/lib/status.sh        /usr/local/lib/hooks/status.sh        && \
  cp /hooks/lib/history.sh       /usr/local/lib/hooks/history.sh       && \
  cp /hooks/lib/provider.sh      /usr/local/lib/hooks/provider.sh      && \
  cp /hooks/lib/nginx_gotchas.sh /usr/local/lib/hooks/nginx_gotchas.sh && \
  chmod +x /hooks/migrate.sh /hooks/validate.sh /hooks/rollback.sh

RUN echo '=== smoke-testing hook --config paths ==' && \
    bash /hooks/migrate.sh  --config >/dev/null && echo 'migrate.sh  OK' && \
    bash /hooks/validate.sh --config >/dev/null && echo 'validate.sh OK' && \
    bash /hooks/rollback.sh --config >/dev/null && echo 'rollback.sh OK'
