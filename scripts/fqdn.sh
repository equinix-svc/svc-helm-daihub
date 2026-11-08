#!/usr/bin/env bash
# fqdn.sh - public name with a signed certificate (Let's Encrypt through Traefik). Run by Day 0 when FQDN is set.
# Needs in the environment: FQDN, ADMIN_EMAIL (the certificate contact), MAN (the k3s manifests directory).
# Writes traefik-config.yaml (Let's Encrypt resolver, persistent certificate store), langfuse-config.yaml (Langfuse login URL) and
# fqdn-ingress.yaml (LiteLLM and the chat page on the name, Langfuse on langfuse.<name>), plus ${FQDN_FILE:-${FQDN_FILE:-/etc/ai-gateway/fqdn}}.
set -euo pipefail
MAN="${MAN:-/var/lib/rancher/k3s/server/manifests}"
  FQDN="$(printf '%s' "$FQDN" | tr 'A-Z' 'a-z')"
  printf '%s' "$FQDN" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || { echo "FQDN is not a valid name: $FQDN"; exit 1; }
  case "${ADMIN_EMAIL:-}" in *@*.*) ;; *) echo "FQDN needs a real e-mail address in ADMIN_EMAIL (got: '${ADMIN_EMAIL:-}')"; exit 1 ;; esac
  CA=https://acme-v02.api.letsencrypt.org/directory
  cat > "$MAN/traefik-config.yaml" <<FQDNEOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: traefik, namespace: kube-system }
spec:
  valuesContent: |-
    persistence: { enabled: true, size: 128Mi }
    certificatesResolvers:
      le:
        acme:
          email: "$ADMIN_EMAIL"
          caServer: "$CA"
          storage: /data/acme.json
          httpChallenge: { entryPoint: web }
    deployment:
      initContainers:
        - name: volume-permissions
          image: busybox:1.37
          command: ["sh", "-c", "touch /data/acme.json; chmod -v 600 /data/acme.json"]
          volumeMounts: [{ name: data, mountPath: /data }]
    podSecurityContext: { fsGroup: 65532, fsGroupChangePolicy: OnRootMismatch }
FQDNEOF
  cat > "$MAN/langfuse-config.yaml" <<FQDNEOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: langfuse, namespace: kube-system }
spec:
  valuesContent: |-
    langfuse:
      nextauth:
        url: https://langfuse.$FQDN
FQDNEOF
  cat > "$MAN/fqdn-ingress.yaml" <<FQDNEOF
# https://$FQDN/ (LiteLLM API and admin UI), /chat (login), and https://langfuse.$FQDN/ ; certificates from Let's Encrypt
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fqdn-litellm
  namespace: ai-gateway
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: le
spec:
  tls: [{ hosts: ["$FQDN"] }]
  rules:
    - host: "$FQDN"
      http: { paths: [{ path: /, pathType: Prefix, backend: { service: { name: ai-litellm, port: { number: 4000 } } } }] }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fqdn-chat
  namespace: ai-gateway
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: le
    traefik.ingress.kubernetes.io/router.middlewares: ai-gateway-basic-auth@kubernetescrd
spec:
  tls: [{ hosts: ["$FQDN"] }]
  rules:
    - host: "$FQDN"
      http: { paths: [{ path: /chat, pathType: Prefix, backend: { service: { name: chat-ui, port: { number: 80 } } } }] }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fqdn-langfuse
  namespace: ai-gateway
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls.certresolver: le
spec:
  tls: [{ hosts: ["langfuse.$FQDN"] }]
  rules:
    - host: "langfuse.$FQDN"
      http: { paths: [{ path: /, pathType: Prefix, backend: { service: { name: langfuse-web, port: { number: 3000 } } } }] }
FQDNEOF
  printf '%s\n' "$FQDN" > ${FQDN_FILE:-${FQDN_FILE:-/etc/ai-gateway/fqdn}}
  echo "FQDN $FQDN configured (ACME CA: $CA)"
