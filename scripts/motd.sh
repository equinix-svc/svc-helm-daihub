# DAI Hub login banner. Day 0 installs this file as /etc/profile.d/dai-hub-motd.sh; it is shown on interactive logins only
# (not for scp, "ssh host command" or VS Code Remote-SSH). It never prints a secret. MOTD_FORCE=1 shows it anywhere (testing).
[ -n "${BASH_VERSION:-}" ] || return 0 2>/dev/null
if [ -z "${MOTD_FORCE:-}" ]; then
  case $- in *i*) ;; *) return 0 2>/dev/null ;; esac
  [ -t 1 ] || return 0
  [ -z "${DAIHUB_MOTD_SHOWN:-}" ] || return 0
fi
export DAIHUB_MOTD_SHOWN=1

_daihub_motd() {
  local dns dip B="" D="" G="" Y="" N="" ip host ready total status fqdn base
  if [ -z "${NO_COLOR:-}" ]; then B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; fi
  _k() {   # kubectl as the login user (kubeconfig copied by Day 0), else sudo; never blocks the login for long
    if [ -r "$HOME/.kube/config" ]; then KUBECONFIG="$HOME/.kube/config" timeout 3 k3s kubectl "$@" 2>/dev/null
    else timeout 3 sudo -n k3s kubectl "$@" 2>/dev/null; fi
  }
  host=$(hostname)
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  ip=${ip:-<node-ip>}
  fqdn=$(cat /etc/ai-gateway/fqdn 2>/dev/null)             # set by Day 0 when the node has a public name with a signed certificate
  base="https://${fqdn:-$ip}"
  read -r ready total < <(_k -n ai-gateway get pods --no-headers | awk '$3!="Terminating"{t++; split($2,a,"/"); if($3=="Running" && a[1]==a[2]) r++} END{print r+0, t+0}')
  if [ "${total:-0}" -eq 0 ]; then status="${Y}not available yet (k3s or the stack is still starting)${N}"
  elif [ "$ready" -eq "$total" ]; then status="${G}${ready}/${total} pods ready${N}"
  else status="${Y}${ready}/${total} pods ready${N}  ${D}(first start takes about 10 minutes)${N}"; fi

  printf '\n%sDAI Hub%s · AI gateway on k3s          %s%s%s\n' "$B" "$N" "$D" "$host" "$N"
  printf '%s\n' "──────────────────────────────────────────────────────────────────────────────"
  printf '  Stack       %s\n\n' "$status"
  dns=$(cat /etc/ai-gateway/dns-wait.state 2>/dev/null)
  case "$dns" in
    waiting*)
      dip=${dns#*ip=}; dip=${dip% *}; [ "$dip" = pending ] && dip="this node's public IP (see the portal)"
      printf '  %s! DNS not ready%s: create A record(s) pointing to %s%s%s\n' "$Y" "$N" "$B" "$dip" "$N"
      for n in $(printf '%s' "${dns#*names=}" | tr ',' ' '); do printf '      %s\n' "$n"; done
      printf '    The certificates are requested automatically within a minute of the records resolving.\n\n' ;;
  esac
  printf '  %sWEB INTERFACES%s\n' "$B" "$N"
  printf '  %-15s %-35s %s\n' "Chat page"      "$base/chat/"               "login: the admin account"
  printf '  %-15s %-35s %s\n' "LiteLLM admin"  "$base/ui/"                 "login: the admin account"
  printf '  %-15s %-35s %s\n' "LiteLLM API"    "$base/"                    "Authorization: Bearer <key>"
  if [ -n "$fqdn" ]; then
    printf '  %-15s %-35s %s\n' "Langfuse"     "https://langfuse.$fqdn"    "login: the admin account"
    printf '  %-15s %-35s %s\n' "Qdrant"       "http://localhost:6333/dashboard" "SSH tunnel (not exposed)"
    printf '  %-15s %-35s %s\n' "SeaweedFS"    "http://localhost:8888"     "SSH tunnel (RAG documents)"
    printf '\n  Tunnel for Qdrant or SeaweedFS, from your laptop (change the service and port):\n'
  else
    printf '  %-15s %-35s %s\n' "Langfuse"     "http://localhost:3000"     "SSH tunnel (below)"
    printf '  %-15s %-35s %s\n' "Qdrant"       "http://localhost:6333/dashboard" "SSH tunnel"
    printf '  %-15s %-35s %s\n' "SeaweedFS"    "http://localhost:8888"     "SSH tunnel (RAG documents)"
    printf '\n  Tunnel, from your laptop (change the service and port per interface):\n'
  fi
  if [ -n "$fqdn" ]; then
    printf '    ssh -L 6333:localhost:6333 %s@%s \\\n' "${USER:-<user>}" "$ip"
    printf '        "sudo k3s kubectl -n ai-gateway port-forward svc/qdrant 6333"\n\n'
  else
    printf '    ssh -L 3000:localhost:3000 %s@%s \\\n' "${USER:-<user>}" "$ip"
    printf '        "sudo k3s kubectl -n ai-gateway port-forward svc/langfuse-web 3000"\n\n'
  fi
  printf '  %-15s sudo cat /etc/ai-gateway/credentials.env  (ADMIN_EMAIL / ADMIN_PASSWORD)\n\n' "Credentials"
  printf '  %sTIPS%s\n' "$B" "$N"
  if [ -n "$fqdn" ]; then printf '   • The certificate is signed (Let'"'"'s Encrypt) on %s.\n' "$fqdn"
  else printf '   • The browser warns about the certificate: it is Traefik'"'"'s default, accept it.\n'; fi
  printf '   • Pods:      sudo k3s kubectl -n ai-gateway get pods\n'
  printf '   • Logs:      sudo k3s kubectl -n ai-gateway logs deploy/ai-litellm --tail=30\n'
  printf '   • Health:    curl -fsSL https://raw.githubusercontent.com/equinix-svc/svc-helm-daihub/main/scripts/check-install.sh \\\n'
  printf '                  | sudo bash\n'
  printf '   • RAG:       add .txt/.md files to bucket rag-docs (SeaweedFS), then ingest (README, "Use")\n'
  printf '   • Day 0 log: /var/log/day0.log\n\n'
}
_daihub_motd
unset -f _daihub_motd _k 2>/dev/null
