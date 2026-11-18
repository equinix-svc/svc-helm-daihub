#!/usr/bin/env bash
# fqdn.sh - public name with a signed certificate (Let's Encrypt). Run by Day 0 when FQDN is set.
# Two modes. With R53_ZONE_ID set (shared name, several nodes): cert-manager issues ONE certificate by DNS-01 on Route 53, kept in a
# Secret that every node's Traefik reads; Traefik runs on every node; nothing waits for DNS. The Route 53 key is not handled here: create
# Secret route53-credentials in namespace cert-manager (access-key-id, secret-access-key). ACME_STAGING=1 uses the Let's Encrypt staging CA.
# Without R53_ZONE_ID (one node): Traefik asks Let's Encrypt itself (HTTP-01), as described below.
# Needs in the environment: FQDN, ADMIN_EMAIL (the certificate contact), MAN (the k3s manifests directory).
# The node's public IP is only known after creation, so the DNS records come later. This script therefore writes
# traefik-config.yaml (Let's Encrypt resolver, persistent certificate store), langfuse-config.yaml (Langfuse login URL) and
# fqdn-ingress.yaml (LiteLLM and the chat page on the name, Langfuse on langfuse.<name>) into a PENDING directory, and installs
# a systemd service that moves them into MAN as soon as both names resolve to this node: the first Let's Encrypt attempt
# then succeeds. It also writes ${FQDN_FILE:-$CONF_DIR/fqdn} and the service's state file (read by the login banner).
set -euo pipefail
MAN="${MAN:-/var/lib/rancher/k3s/server/manifests}"
CONF_DIR="${CONF_DIR:-/etc/ai-gateway}"
PENDING="${PENDING:-/var/lib/ai-gateway/pending}"
BIN="${BIN:-/usr/local/bin/dai-dns-wait.sh}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
  FQDN="$(printf '%s' "$FQDN" | tr 'A-Z' 'a-z')"
  printf '%s' "$FQDN" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || { echo "FQDN is not a valid name: $FQDN"; exit 1; }
  case "${ADMIN_EMAIL:-}" in *@*.*) ;; *) echo "FQDN needs a real e-mail address in ADMIN_EMAIL (got: '${ADMIN_EMAIL:-}')"; exit 1 ;; esac
  CA=https://acme-v02.api.letsencrypt.org/directory
  mkdir -p "$PENDING" "$CONF_DIR"
  chmod 0755 "$CONF_DIR"          # the login banner (run as the login user) reads fqdn and dns-wait.state; secrets stay 0600 files
  rm -f "$MAN/traefik-config.yaml" "$MAN/langfuse-config.yaml" "$MAN/fqdn-ingress.yaml"
  if [ -n "${R53_ZONE_ID:-}" ]; then
    # ---- DNS-01 mode: cert-manager, Traefik on every node, no DNS wait
    printf '%s' "$R53_ZONE_ID" | grep -Eq '^[A-Z0-9]{10,32}$' || { echo "R53_ZONE_ID is not a hosted zone id: $R53_ZONE_ID"; exit 1; }
    ISSUER=letsencrypt-dns; [ -z "${ACME_STAGING:-}" ] || ISSUER=letsencrypt-dns-staging
    rm -f "$MAN/cert-manager.yaml" "$MAN/dai-certificate.yaml" "$MAN/traefik-config.yaml"
    cat > "$MAN/cert-manager.yaml" <<FQDNEOF
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata: { name: cert-manager, namespace: kube-system }
spec:
  repo: https://charts.jetstack.io
  chart: cert-manager
  version: v1.16.2
  targetNamespace: cert-manager
  createNamespace: true
  valuesContent: |-
    crds: { enabled: true }
    resources: { requests: { cpu: 10m, memory: 48Mi } }
    webhook: { resources: { requests: { cpu: 10m, memory: 32Mi } } }
    cainjector: { resources: { requests: { cpu: 10m, memory: 48Mi } } }
---
# Let's Encrypt through DNS-01 on Route 53. The key is read from Secret route53-credentials in namespace cert-manager.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: letsencrypt-dns }
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "$ADMIN_EMAIL"
    privateKeySecretRef: { name: letsencrypt-dns-account }
    solvers:
      - dns01:
          route53:
            region: us-east-1
            hostedZoneID: "$R53_ZONE_ID"
            accessKeyIDSecretRef: { name: route53-credentials, key: access-key-id }
            secretAccessKeySecretRef: { name: route53-credentials, key: secret-access-key }
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: letsencrypt-dns-staging }
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "$ADMIN_EMAIL"
    privateKeySecretRef: { name: letsencrypt-dns-staging-account }
    solvers:
      - dns01:
          route53:
            region: us-east-1
            hostedZoneID: "$R53_ZONE_ID"
            accessKeyIDSecretRef: { name: route53-credentials, key: access-key-id }
            secretAccessKeySecretRef: { name: route53-credentials, key: secret-access-key }
FQDNEOF
    cat > "$MAN/dai-certificate.yaml" <<FQDNEOF
# One certificate for both names, in a Secret every Traefik reads. Pending until Secret route53-credentials exists.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: dai-tls, namespace: ai-gateway }
spec:
  secretName: dai-tls
  issuerRef: { name: $ISSUER, kind: ClusterIssuer }
  dnsNames: ["$FQDN", "langfuse.$FQDN"]
FQDNEOF
    cat > "$MAN/traefik-config.yaml" <<FQDNEOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: traefik, namespace: kube-system }
spec:
  valuesContent: |-
    deployment: { kind: DaemonSet }
    updateStrategy: { type: RollingUpdate, rollingUpdate: { maxUnavailable: 1, maxSurge: 0 } }
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
# https://$FQDN/ (LiteLLM API and admin UI), /chat (login), and https://langfuse.$FQDN/ ; certificate from Secret dai-tls
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fqdn-litellm
  namespace: ai-gateway
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls: [{ hosts: ["$FQDN"], secretName: dai-tls }]
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
    traefik.ingress.kubernetes.io/router.middlewares: ai-gateway-basic-auth@kubernetescrd
spec:
  tls: [{ hosts: ["$FQDN"], secretName: dai-tls }]
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
spec:
  tls: [{ hosts: ["langfuse.$FQDN"], secretName: dai-tls }]
  rules:
    - host: "langfuse.$FQDN"
      http: { paths: [{ path: /, pathType: Prefix, backend: { service: { name: langfuse-web, port: { number: 3000 } } } }] }
FQDNEOF
    printf '%s\n' "$FQDN" > ${FQDN_FILE:-$CONF_DIR/fqdn}
    echo "ready dns-01 $(date -Is)" > "$CONF_DIR/dns-wait.state"
    echo "FQDN $FQDN: shared name by DNS-01 ($ISSUER). Create Secret route53-credentials in namespace cert-manager, and one A record per node for $FQDN and langfuse.$FQDN"
    exit 0
  fi
  cat > "$PENDING/traefik-config.yaml" <<FQDNEOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: traefik, namespace: kube-system }
spec:
  valuesContent: |-
    persistence: { enabled: true, size: 128Mi }
    updateStrategy: { type: Recreate, rollingUpdate: null }
    service: { spec: { publishNotReadyAddresses: true } }
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
  cat > "$PENDING/langfuse-config.yaml" <<FQDNEOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata: { name: langfuse, namespace: kube-system }
spec:
  valuesContent: |-
    langfuse:
      nextauth:
        url: https://langfuse.$FQDN
FQDNEOF
  cat > "$PENDING/fqdn-ingress.yaml" <<FQDNEOF
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
  printf '%s\n' "$FQDN" > ${FQDN_FILE:-$CONF_DIR/fqdn}

  # --- wait for DNS, then enable the certificates
  cat > "$CONF_DIR/dns-wait.conf" <<DNSEOF
NAMES="$FQDN langfuse.$FQDN"
PENDING="$PENDING"
MAN="$MAN"
STATE="$CONF_DIR/dns-wait.state"
DNSEOF
  cat > "$BIN" <<'WAITEOF'
#!/usr/bin/env bash
# dai-dns-wait.sh <conf> - wait until every name in NAMES resolves to this node (a local address or the address the internet
# sees), then move the pending manifests into the k3s manifests directory: Traefik then asks Let's Encrypt for the certificates.
# State (one line) goes to $STATE: "waiting ip=<address to use> names=<a,b> cur=<name=ips/ok|wrong|none|...>" or "ready <date>".
set -u
. "$1"
if grep -q '^ready' "$STATE" 2>/dev/null; then exit 0; fi          # done before (reboot): the manifests are already in place
while true; do
  ext=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null | grep -E '^[0-9.]+$' || true)
  mine=$( { ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1; [ -n "$ext" ] && echo "$ext"; } | sort -u )
  use=${ext:-$(echo "$mine" | head -1)}
  ok=1; cur=""
  for n in $NAMES; do
    got=$(getent ahostsv4 "$n" 2>/dev/null | awk '{print $1}' | sort -u)
    if [ -z "$got" ]; then st=none; ips=-; ok=0
    elif comm -12 <(echo "$got") <(echo "$mine") | grep -q .; then st=ok; ips=$(echo $got | tr ' ' '+')
    else st=wrong; ips=$(echo $got | tr ' ' '+'); ok=0; fi
    cur="${cur:+$cur|}$n=$ips/$st"
  done
  if [ "$ok" = 1 ]; then
    cp "$PENDING"/*.yaml "$MAN"/ && echo "ready $(date -Is)" > "$STATE"
    exit 0
  fi
  echo "waiting ip=$use names=$(echo $NAMES | tr ' ' ',') cur=$cur" > "$STATE"
  sleep "${DNS_WAIT_INTERVAL:-30}"
done
WAITEOF
  chmod 0755 "$BIN"
  echo "waiting ip=pending names=$FQDN,langfuse.$FQDN" > "$CONF_DIR/dns-wait.state"
  cat > "$UNIT_DIR/dai-dns-wait.service" <<UNITEOF
[Unit]
Description=Wait for the DNS records of the public name, then enable the certificates
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$BIN $CONF_DIR/dns-wait.conf
Restart=on-failure
RestartSec=30
[Install]
WantedBy=multi-user.target
UNITEOF
  if [ -d /run/systemd/system ] && [ -z "${NO_SYSTEMD:-}" ]; then systemctl daemon-reload; systemctl enable --now dai-dns-wait.service; fi
  echo "FQDN $FQDN: certificates are enabled as soon as the DNS records of $FQDN and langfuse.$FQDN point to this node"
