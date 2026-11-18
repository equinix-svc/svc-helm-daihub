#!/usr/bin/env bash
# api-vip.sh - a stable address for the k3s API on the private network, on one control-plane node.
# kube-vip (a static pod, ARP, leader election) holds the address on the private NIC; one NAT rule forwards it to this
# node's own API address, so the API keeps listening on the node address only. Day 0 runs it on every server node once
# k3s is Ready, when the private path is on. Idempotent.
# Needs in the environment: VIP (the shared address), PRIV_IF (the private NIC), NODE_IP (this node's private address).
# Optional: KUBE_VIP_IMAGE, POD_DIR, SBIN, UNIT_DIR, NO_SYSTEMD (for tests).
set -euo pipefail
VIP="${VIP:?VIP}"; PRIV_IF="${PRIV_IF:?PRIV_IF}"; NODE_IP="${NODE_IP:?NODE_IP}"
KUBE_VIP_IMAGE="${KUBE_VIP_IMAGE:-ghcr.io/kube-vip/kube-vip:v0.8.9}"
POD_DIR="${POD_DIR:-/var/lib/rancher/k3s/agent/pod-manifests}"
SBIN="${SBIN:-/usr/local/sbin}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
mkdir -p "$POD_DIR" "$SBIN" "$UNIT_DIR"

# kube-vip talks to the API through the node's own kubeconfig (127.0.0.1), so it needs no VIP to start.
cat > "$POD_DIR/kube-vip.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata: { name: kube-vip, namespace: kube-system }
spec:
  hostNetwork: true
  hostAliases: [{ hostnames: [kubernetes], ip: 127.0.0.1 }]
  containers:
    - name: kube-vip
      image: $KUBE_VIP_IMAGE
      args: [manager]
      env:
        - { name: vip_arp, value: "true" }
        - { name: port, value: "6443" }
        - { name: vip_interface, value: $PRIV_IF }
        - { name: vip_cidr, value: "32" }
        - { name: cp_enable, value: "true" }
        - { name: cp_namespace, value: kube-system }
        - { name: vip_leaderelection, value: "true" }
        - { name: vip_leaseduration, value: "5" }
        - { name: vip_renewdeadline, value: "3" }
        - { name: vip_retryperiod, value: "1" }
        - { name: address, value: $VIP }
      securityContext: { capabilities: { add: [NET_ADMIN, NET_RAW] } }
      volumeMounts: [{ mountPath: /etc/kubernetes/admin.conf, name: kubeconfig }]
  volumes: [{ name: kubeconfig, hostPath: { path: /etc/rancher/k3s/k3s.yaml } }]
EOF

cat > "$SBIN/k3s-api-vip" <<'EOF'
#!/bin/sh
# Stable API address: the node that holds the kube-vip address rewrites VIP:PORT to its own node address, where the k3s API
# listens. Own chain in the nat table, hooked first in PREROUTING (other hosts) and OUTPUT (this host). Idempotent.
# Usage: k3s-api-vip <VIP> <this node's address> [port]
VIP="${1:?VIP}"; NODE="${2:?node address}"; PORT="${3:-6443}"
IPT=/usr/sbin/iptables; C=K3S-API-VIP
"$IPT" -t nat -N "$C" 2>/dev/null || true
"$IPT" -t nat -F "$C"
"$IPT" -t nat -A "$C" -d "$VIP/32" -p tcp --dport "$PORT" -j DNAT --to-destination "$NODE:$PORT"
for H in PREROUTING OUTPUT; do "$IPT" -t nat -C "$H" -j "$C" 2>/dev/null || "$IPT" -t nat -I "$H" 1 -j "$C"; done
EOF
chmod 0755 "$SBIN/k3s-api-vip"

cat > "$UNIT_DIR/k3s-api-vip.service" <<EOF
[Unit]
Description=k3s API reachable on the kube-vip address
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SBIN/k3s-api-vip $VIP $NODE_IP 6443

[Install]
WantedBy=multi-user.target
EOF

if [ -d /run/systemd/system ] && [ -z "${NO_SYSTEMD:-}" ]; then
  systemctl daemon-reload
  systemctl enable --now k3s-api-vip.service
fi
echo "API address $VIP on $PRIV_IF: kube-vip pod and forwarding to $NODE_IP:6443 installed"
