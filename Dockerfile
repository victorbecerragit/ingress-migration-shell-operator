FROM ghcr.io/flant/shell-operator:v1.4.16

# Install required tools (bash, curl, jq, gettext, yq are often useful)
RUN apk add --no-cache bash curl jq gettext

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Install ingress2gateway v0.5.0
RUN curl -LO "https://github.com/kubernetes-sigs/ingress2gateway/releases/download/v0.5.0/ingress2gateway_Linux_x86_64.tar.gz" \
    && tar -xzf ingress2gateway_Linux_x86_64.tar.gz \
    && chmod +x ingress2gateway \
    && mv ingress2gateway /usr/local/bin/ \
    && rm ingress2gateway_Linux_x86_64.tar.gz

# Note: Flant shell-operator executes executable scripts mounted into /hooks
# Our Helm chart mounts a ConfigMap containing migrate.sh, rollback.sh, and validate.sh into /hooks
