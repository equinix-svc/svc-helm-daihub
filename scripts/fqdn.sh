#!/usr/bin/env bash
# fqdn.sh - public name with a signed certificate (Let's Encrypt through Traefik). Run by Day 0 when FQDN is set.
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
  cat > "$PENDING/traefik-config.yaml" <<FQDNEOF
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
