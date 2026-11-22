# svc-helm-daihub

<img src="assets/logo.svg" alt="DAI Hub" width="120">

AI gateway stack for a single k3s node or a two or three node k3s cluster, as **one file**: [`ai-gateway.yaml`](ai-gateway.yaml). It runs on the plain `k3s-node` image of [svc-ne-byoi-builder](https://github.com/equinix-svc/svc-ne-byoi-builder) (Equinix Network Edge BYOI) and works on any k3s with Traefik. Deployed on two Network Edge devices, as a single node and as a two-node cluster; a third node is not tested yet.

| Section | Topic |
|---|---|
| [1](#1-overall-design) | Overall design |
| [2](#2-deployment-modes-and-steps) | Deployment modes and steps |
| [3](#3-day-0-parameters) | Day 0 templates and parameters |
| [4](#4-web-interfaces) | Web interfaces and chat page |
| [5](#5-names-and-certificates) | Names and certificates |
| [6](#6-cluster-mode) | Cluster mode: network, nodes, API address |
| [7](#7-exposure-and-redundancy) | Internal and external exposure, redundancy |
| [8](#8-storage-replication) | Storage replication |
| [9](#9-ai-request-flow) | How a request flows, secrets, first start, use |
| [10](#10-repository-build-and-validate) | Repository, build and validate |

## 1. Overall design

One Day 0 file per node turns the unchanged `k3s-node` image into a k3s node and, on the first node, deploys the whole stack from this repository.

| Area | Component | How it is deployed |
|---|---|---|
| Gateway | LiteLLM 1.108.0 | public OCI chart `ghcr.io/berriai/litellm-helm` (release `ai`, Service `ai-litellm:4000`) |
| Observability | Langfuse 4.75 (web, worker) | public chart `langfuse` 2.2.3 |
| Guardrails | Presidio analyzer + anonymizer | `mcr.microsoft.com/presidio-*`, plain Deployments |
| | LLM Guard: DeBERTa v3 prompt injection, secrets | `python:3.12-slim`, code in a ConfigMap, CPU-only PyTorch installed on first start |
| RAG | Qdrant 1.20 | public chart `qdrant` 1.20.0 |
| | rag-service: fastembed `bge-small-en-v1.5`, ingest from S3 | `python:3.12-slim`, code in a ConfigMap |
| Data | Postgres 16 (databases `litellm`, `langfuse`), Redis 7, ClickHouse 26.8 | official images, plain Deployments |
| S3 | SeaweedFS all-in-one (buckets `langfuse`, `rag-docs`) | shipped by the Langfuse chart |
| Chat page | nginx with one static page | image `ghcr.io/equinix-svc/svc-helm-daihub/chat-ui`, manifest `chat-ui.yaml` |
| Web entry | Traefik (k3s built-in), cert-manager | Traefik DaemonSet; cert-manager chart; configured by `scripts/fqdn.sh` |
| Cluster | k3s embedded etcd, kube-vip, Longhorn | `scripts/api-vip.sh`, `longhorn.yaml` |

Only LiteLLM (with the chat page and Langfuse) is exposed, on 80/443 through Traefik. Everything else stays inside the cluster. Langfuse's own Postgres, Redis and ClickHouse sub-charts are turned off, so Langfuse uses the shared ones above.

Tools used on behalf of the install: **k3s** (its manifests directory is the deployment mechanism: any file placed there is applied, and `HelmChart` objects install charts), **Helm** (through k3s's helm-controller), **cloud-init** (the Day 0 runs once at first boot), **GitHub API** (Day 0 fetches scripts and manifests from this repository).

```mermaid
flowchart LR
  P["Equinix portal<br/>Day 0 + parameters"] --> N["k3s-node<br/>first boot"]
  N --> K["k3s manifests directory"]
  G["this repository<br/>ai-gateway.yaml, chat-ui.yaml,<br/>longhorn.yaml, scripts"] -- "fetched by Day 0" --> K
  K --> S["stack: LiteLLM, Langfuse,<br/>guardrails, RAG, databases"]
  K --> E["web entry:<br/>Traefik + cert-manager"]
  K --> V["volumes: Longhorn (cluster)"]
```

## 2. Deployment modes and steps

| | Single node | Cluster (2 or 3 servers) |
|---|---|---|
| Day 0 template | BASIC | ADVANCED |
| `K3S_ROLE` | `single` | `server` |
| Private network | none | Fabric Network on `ens4` (section 6) |
| API address | the node | shared address `10.250.0.10` (kube-vip) |
| Web names | `FQDN` | `FQDN` is shared by all nodes; `NODE_FQDNS` adds one name per node |
| Volumes | `local-path` | `local-path`, or `longhorn` after you move them (section 8) |
| Survives a node loss | no | web entry yes; API only with 3 nodes; data on Longhorn volumes |

| Step | Single node | Cluster |
|---|---|---|
| 1. Image | plain `k3s-node` image (`k3s-node.qcow2`) from [svc-ne-byoi-builder](https://github.com/equinix-svc/svc-ne-byoi-builder); portal settings in `docs/portal-values.md` there | same |
| 2. Network | none | one Fabric Network connected to `ens4` of every node (section 6) |
| 3. Day 0 | paste [`day0-ai-gateway-basic.yaml`](day0/day0-ai-gateway-basic.yaml) | paste [`day0-ai-gateway-advanced.yaml`](day0/day0-ai-gateway-advanced.yaml) on every node |
| 4. Parameters | `REGISTRY_USER`, `REGISTRY_TOKEN`, `ADMIN_EMAIL`, `FQDN` (required); API keys; `ADMIN_PASSWORD` | node 1: the same plus `K3S_ROLE=server`, `K3S_TOKEN`, `NODE_FQDNS`; nodes 2 and 3: `K3S_ROLE=server`, `K3S_SERVER_URL`, `K3S_TOKEN` |
| 5. Order | one node | node 1 first; wait until it is Ready and the API address answers; then nodes 2 and 3 |
| 6. DNS | `FQDN` and `langfuse.<FQDN>` to the node, after it has its public IP | the same names to every node's public IP |
| 7. ACL | allow 22 and 80/443 | the same; keep 6443, 10250 and UDP 8472 closed from the internet |
| 8. Start | about 10 minutes (section 9) | the same, plus the join time of each node |

On the node, `check-install.sh` is a read-only check:  `curl -fsSL https://raw.githubusercontent.com/equinix-svc/svc-helm-daihub/main/scripts/check-install.sh | sudo bash`.

## 3. Day 0 parameters

Both templates are the Equinix Network Edge Day 0 for the unchanged `k3s-node.qcow2`. They do what that image's own Day 0 does (hostname, static network, portal user, k3s), then on a `single` node or the first `server`, once k3s is Ready:

1. generate the two Secrets (section 9) with random values, except the keys you pass in, and write the ones you need to `/etc/ai-gateway/credentials.env` (root only);
2. download `ai-gateway.yaml` and `chat-ui.yaml` (and, on a cluster, `longhorn.yaml`) from this repo into `/var/lib/rancher/k3s/server/manifests/`, where k3s deploys them;
3. run `scripts/fqdn.sh` (names and certificates), and on a cluster `scripts/api-vip.sh` and the `open-iscsi` install.

| Template | Use | Size | Portal parameters |
|---|---|---|---|
| [`day0/day0-ai-gateway-basic.yaml`](day0/day0-ai-gateway-basic.yaml) | **BASIC**: single node only, everything else fixed or generated | 13.9 KB | 7, 4 required |
| [`day0/day0-ai-gateway-advanced.yaml`](day0/day0-ai-gateway-advanced.yaml) | **ADVANCED**: cluster (private network, shared API address), chosen credentials | 17.0 KB | 15, 4 required |

Equinix predefined (both): `hostname` `userName` `publicKey` `adminPwd` `ipAddressWithCidr` `gateway`. Declare every other variable as a custom parameter in the portal. The portal limit is 20,000 characters. Render locally with `DAY0_FILE=<file> scripts/render-day0.sh`. Log: `/var/log/day0.log`.

### Parameters

Legend: **yes** = required, **no** = optional, **-** = not used. Default = what the template uses when an optional parameter is left empty.

| Parameter | BASIC | ADVANCED | Default | Example (paste in the portal) | Meaning |
|---|---|---|---|---|---|
| `REGISTRY_USER` | yes | yes | - | `my-github-user` | GitHub login used to pull the private chat page image from ghcr.io. Day 0 stops the stack install without it. |
| `REGISTRY_TOKEN` | yes | yes | - | `ghp_AbCdEf1234567890AbCdEf1234567890AbCd` | Classic personal access token with only `read:packages`. Written to `/etc/rancher/k3s/registries.yaml` (root only) before k3s starts. Expires: set a reminder to rotate it. |
| `ADMIN_EMAIL` | yes | yes | - | `xxxx@eu.equinix.com` | Login name of the shared admin account (Langfuse, LiteLLM admin UI, chat page login). It must be a real address: it is also the contact for the Let's Encrypt certificates. |
| `FQDN` | yes | yes | - | `fred-dai-par01.example.net` | Public name of the node. Serves `https://<FQDN>` (LiteLLM, chat page) and `https://langfuse.<FQDN>` with Let's Encrypt certificates issued by cert-manager. The node's public IP is only known after creation, so create the DNS records afterwards: the node waits (checks every 30 seconds) until `<FQDN>` and `langfuse.<FQDN>` both resolve to it, then enables the certificates, so the first Let's Encrypt attempt succeeds. The login banner shows the IP to use and what each name resolves to now (`not found` or `WRONG` when it points elsewhere, for example after a rebuild with a new IP). Keep port 80 reachable from the internet. On a cluster it is the shared name (section 5). |
| `NODE_FQDNS` | - | no | empty | `svc-dai-par01.example.net,svc-dai-par02.example.net` | Cluster only, first server. The nodes' own names (comma separated): each gets its own Let's Encrypt certificate and its own Ingresses, so `https://<name>` is valid on that node too. Create their DNS records like the shared name's. |
| `GROQ_API_KEY` | no (for Groq models) | no (for Groq models) | empty | `gsk_AbCdEf1234567890` | Groq API key. |
| `GEMINI_API_KEY` | no (for Gemini models) | no (for Gemini models) | empty | `AIzaSyAbCdEf1234567890` | Gemini API key. |
| `LITELLM_MASTER_KEY` | - | no | generated | `sk-lab-0123456789abcdef` | LiteLLM admin key. |
| `K3S_ROLE` | - | no | `single` | `single` | `single`: standalone node. `server`: control-plane node. With `K3S_SERVER_URL` empty it starts a new cluster and installs the stack; with it set it joins that cluster and the stack is not installed on it. `agent`: k3s worker node that joins an existing cluster; the stack is not installed on it. |
| `K3S_SERVER_URL` | - | no | empty | `https://10.250.0.10:6443` | Agent or joining server. The shared API address (`K3S_API_VIP`, port 6443): it keeps working whichever server is up. A server's own private address also works, but then that server must be up when the node starts. Empty for `single` or the first `server`. |
| `K3S_TOKEN` | - | no | empty | `K10abc123def456::server:789xyz` | Secret of the k3s cluster. Set the same value on the first `server` (it fixes the secret, so you know it before that node exists) and on every agent or joining server. Empty: k3s generates one. |
| `K3S_TLS_SAN` | - | no | empty | `203.0.113.20` | Extra name or IP in the k3s API server certificate, for `kubectl` or agents reaching port 6443 from outside. Not needed for local `sudo k3s kubectl`. |
| `K3S_PRIVATE_IFACE` | - | no | `ens4` | `ens4` | Interface used for the private path between nodes. Skipped when it does not exist. |
| `K3S_PRIVATE_IP_CIDR` | - | no | `10.250.<3rd>.<4th>/16` from the node's public IP | `10.250.0.11/24` | Static private address on the private interface. By default derived from the public IP (public `87.237.190.93` gives `10.250.190.93/16`), so nodes do not collide. `none` turns the private path off. |
| `K3S_API_VIP` | - | no | `10.250.0.10` | `10.250.0.10` | Address shared by the control-plane nodes on the private network, held by one of them at a time (kube-vip). Used as `K3S_SERVER_URL` by joining nodes. Only with the private path on; `none` turns it off. Must be unused on the `ens4` network. |
| `ADMIN_PASSWORD` | no | no | generated | `ChangeMe-2026` | Password of the shared admin account. |

ACL: allow 22 and 80/443. Langfuse, Qdrant and S3 are not exposed.

Private path (ADVANCED only): by default each node also configures `ens4` with a private address in `10.250.0.0/16`, used as the k3s `node-ip` and `flannel-iface`. The cluster mode built on it is described in [section 6](#6-cluster-mode).

## 4. Web interfaces

`<node>` is the public name (`FQDN`, section 5). One admin account (`ADMIN_EMAIL`, and `ADMIN_PASSWORD` generated when empty) is the login for the chat page, the LiteLLM admin UI and Langfuse. It is in `/etc/ai-gateway/credentials.env`.

| Interface | URL | Access | Login |
|---|---|---|---|
| Chat page | `https://<node>/chat/` | public | browser login prompt (Traefik basic auth), then no key to paste |
| LiteLLM admin UI | `https://<node>/ui/` | public | the admin account (`UI_USERNAME` and `UI_PASSWORD`) |
| LiteLLM API | `https://<node>/` | public | `Authorization: Bearer <key>` on `/v1/...` |
| Langfuse (traces) | `https://langfuse.<FQDN>` | public | the admin account |
| Qdrant dashboard (vectors) | `http://localhost:6333/dashboard` | SSH tunnel | none |
| SeaweedFS filer (S3 buckets, RAG documents) | `http://localhost:8888` | SSH tunnel | none |
| rag-service API docs | `http://localhost:8000/docs` | SSH tunnel | none |

Qdrant, SeaweedFS and the rag-service have no login of their own, so they are never exposed. Until the DNS records exist and the certificates are issued, `https://<node-IP>/` also works, with Traefik's default certificate. Tools: Traefik (routing, basic auth middleware), nginx (chat page proxy), `scripts/motd.sh` (login banner listing these URLs with live pod counts).

Tunnel (one terminal per interface; replace the service and ports):

```bash
ssh -L 3000:localhost:3000 <user>@<node> "sudo k3s kubectl -n ai-gateway port-forward svc/langfuse-web 3000"
# Qdrant: svc/qdrant 6333    SeaweedFS filer: svc/langfuse-s3-all-in-one 8888    rag-service: svc/rag-service 8000
```

### Chat page

[`src/chat-ui/`](src/chat-ui/) is a light chat console to test the gateway end to end: one static HTML page served by nginx behind the same Traefik. Its image is built by the `images` GitHub workflow on every change under `src/chat-ui/`.

```mermaid
flowchart LR
  B["browser"] -- "login (basic auth)" --> T["Traefik"] --> C["chat-ui nginx"]
  C -- "adds the demo key<br/>if the request has none" --> L["LiteLLM"]
```

| Item | Detail |
|---|---|
| Image | `ghcr.io/equinix-svc/svc-helm-daihub/chat-ui:0.1.0` (nginx 1.27 with the page baked in) |
| Open | `https://<node>/chat/`: a browser login prompt (the admin account), then no key to paste: the page uses the demo key |
| Demo key | Day 0 generates it, writes it to `/etc/ai-gateway/credentials.env` as `CHAT_DEMO_KEY` and to Secret `chat-demo-key`. Job `chat-demo-key-init` registers it in LiteLLM with the master key (alias `chat-demo`, model `llm-pool` only, budget 5 USD, 30 requests per minute). nginx adds it to requests that carry no key, at `/chat/api/`. The browser never sees it. |
| Own key | "Use my own key" in the page: the key is sent in an `X-Api-Key` header (the `Authorization` header carries the browser login) and stays in the tab (`sessionStorage`) |
| Features | model list, RAG switch (`rag-augment` guardrail), samples (PII masking, secret redaction, prompt injection), links to the web interfaces. Each answer shows which real model served it (e.g. `groq/qwen/qwen3.8-27b` or `gemini/gemini-3.5-flash-lite` behind `llm-pool`), tokens, latency, cost and the guardrails applied |
| Private package | Day 0 sets `REGISTRY_USER` and `REGISTRY_TOKEN` (section 3). On a node created before, create the pull secret first: `sudo k3s kubectl -n ai-gateway create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username=<user> --docker-password=<token with read:packages>` |
| Install on an existing node | create the two Secrets, `sudo k3s kubectl -n ai-gateway create secret generic chat-demo-key --from-literal=DEMO_KEY=sk-demo-$(openssl rand -hex 8)` and `sudo k3s kubectl -n ai-gateway create secret generic basic-auth --from-literal=users="<email>:$(openssl passwd -apr1 '<password>')"`, then `sudo k3s kubectl apply -f https://raw.githubusercontent.com/equinix-svc/svc-helm-daihub/main/chat-ui.yaml` |
| Update | push a change under `src/chat-ui/`, then `sudo k3s kubectl -n ai-gateway rollout restart deploy/chat-ui` (the manifest pulls the image again) |
| Remove | `sudo k3s kubectl delete -f` the same URL |
| Sources | `src/chat-ui/` (`index.html`, `default.conf.template`, `equinix-logo.svg`, `Dockerfile`) and the manifest `chat-ui.yaml` |

Anyone who passes the login can use the demo key, within its budget and rate limit. To turn that off, delete Secret `chat-demo-key` and restart `chat-ui`: the page then asks for a key. To change the limits, edit the Job in `chat-ui.yaml`, or change the key in the LiteLLM admin UI. The master key is never exposed by the page.


## 5. Names and certificates

Every public name gets a Let's Encrypt certificate from **cert-manager** (HTTP-01). **Traefik** runs on every node (a DaemonSet) and serves the certificate from a Secret, so any node can answer for a name. A single node uses the same pieces, with one pod each. `scripts/fqdn.sh`, run by Day 0, writes all the manifests.

| Element | What it does |
|---|---|
| cert-manager (chart v1.16.2, one pod) | asks Let's Encrypt for the certificates and keeps them in Secrets; answers the HTTP-01 challenge through a temporary Ingress |
| ClusterIssuers `letsencrypt-http`, `letsencrypt-http-staging` | the production and staging CAs (`ACME_STAGING=1` selects staging) |
| Traefik DaemonSet | one pod per node on 80/443; reads the Secrets from the Ingresses; no ACME resolver of its own |
| `dai-dns-wait` (systemd service) | waits until the names resolve to this node, then enables the certificates, so the first attempt succeeds |
| DNS | one A record per node's public address for each name; you create them |

What each name gets:

| Name | Certificate (Secret) | Ingresses |
|---|---|---|
| `<FQDN>` | `dai-tls` | `fqdn-litellm` (`/`), `fqdn-chat` (`/chat`) |
| `langfuse.<FQDN>` | `dai-tls` | `fqdn-langfuse` |
| node name *N* from `NODE_FQDNS`, and `langfuse.<name>` | `dai-node`*N*`-tls` | `node`*N*`-litellm`, `node`*N*`-chat`, `node`*N*`-langfuse` |
| any other name pointing at a node | none: Traefik's default certificate | none |

```mermaid
flowchart LR
  LE["Let's Encrypt"] -- "HTTP-01, port 80" --> T1["Traefik<br/>node 1"]
  LE -.-> T2["Traefik<br/>node 2"]
  CM["cert-manager"] -- "challenge Ingress" --> T1
  CM -- "writes" --> S[("Secret dai-tls")]
  S --> T1
  S --> T2
  T1 --> SV["LiteLLM, chat, Langfuse"]
  T2 --> SV
```

How it works: Let's Encrypt fetches the challenge on port 80 from whichever node DNS points it to; every node forwards it to the same cert-manager pod, so one certificate is issued for all nodes. Port 80 must be reachable from the internet. Check: `sudo k3s kubectl -n ai-gateway get certificate` shows `READY True`. A rebuilt node only needs its A record updated. Another name can be added later with the annotation `cert-manager.io/cluster-issuer: letsencrypt-http` on its Ingress and a `tls.secretName`. A node that ran with Traefik's own Let's Encrypt resolver must drop it first: that resolver answers every `/.well-known/acme-challenge/` request itself (404 for cert-manager's tokens).

## 6. Cluster mode

Two or three control-plane nodes (`K3S_ROLE=server`, embedded etcd) on one private Layer 2 network. Use the [ADVANCED Day 0 template](day0/day0-ai-gateway-advanced.yaml) on every node.

| Element | What it does | Tool |
|---|---|---|
| Fabric Network (EVPLAN) | the private Layer 2 network, `10.250.0.0/16` on `ens4` | Equinix portal or Terraform |
| `ens4` address | static, derived from the public IP by default; k3s `node-ip` and flannel use it | Day 0 (netplan) |
| etcd | embedded in k3s; needs a majority of servers | k3s |
| flannel VXLAN | pod network between nodes | k3s |
| Shared API address `K3S_API_VIP` | one address held by one server at a time, in the API certificate | kube-vip (static pod, ARP) + an iptables DNAT, installed by `scripts/api-vip.sh` |
| `open-iscsi` | needed by Longhorn on every node | apt, installed by Day 0 |

```mermaid
flowchart LR
  C["joining nodes<br/>and kubectl"] -- "https://10.250.0.10:6443" --> V
  subgraph NET["Fabric Network (EVPLAN) on ens4, 10.250.0.0/16"]
    V(["API address<br/>held by one node at a time"])
    N1["Node 1<br/>server, etcd"]
    N2["Node 2<br/>server, etcd"]
    N3["Node 3<br/>server, etcd"]
    V -.-> N1
  end
  N1 <-- "etcd, flannel" --> N2
  N2 <-- "etcd, flannel" --> N3
  N1 <-- "etcd, flannel" --> N3
```

How it works: the API, kubelet and etcd listen on the private address only. kube-vip elects one server (through the API) to hold the shared address; a DNAT rule forwards it to that node's own API. Joining nodes use it as `K3S_SERVER_URL`, so they join whichever server is up.

### Network

| NIC | Portal interface | Use |
|---|---|---|
| `ens3` | interface1 | public: SSH and the web interfaces |
| `ens4` | interface2 | cluster traffic, one subnet for all nodes |
| `ens5`, `ens6` | interface3, interface4 | reserved for the encryptor (master to slave, KME to KME), not configured here |

1. Create one Fabric Network (EVPLAN) in the metro.
2. Connect the `ens4` interface (`interface2`) of every node to it. A third node is one more connection.
3. Pick the interface by hand when you create the connection (portal or Terraform). The Fabric MCP tool ignores the interface you give it and may attach `interface3` or `interface4`, the encryptor interfaces.
4. ACL: allow 22 and 80/443. Port 6443 does not need to be open on the public side.


### Create the nodes

| Node | `K3S_ROLE` | `K3S_SERVER_URL` | `K3S_TOKEN` | Other parameters |
|---|---|---|---|---|
| 1 | `server` | empty: it starts the cluster and installs the stack | a secret you choose | `REGISTRY_USER`, `REGISTRY_TOKEN`, `ADMIN_EMAIL`, `FQDN`, the API keys |
| 2 and 3 | `server` | `https://10.250.0.10:6443` | the same value as node 1 | none |

Create node 1 first and wait until it is Ready and the API address answers, then create the others. A node that starts before its `ens4` link is up keeps retrying for up to 30 minutes. With the ADVANCED template, Day 0 on `server` and `agent` nodes also installs `open-iscsi` (apt, from the Debian mirror) and loads `iscsi_tcp`, which replicated volumes need; if the install fails, Day 0 goes on and logs it in `/var/log/open-iscsi-install.log`.


### What listens where

| What | How | Listens on |
|---|---|---|
| Cluster traffic (flannel, etcd, kubelet to API) | `node-ip` and `flannel-iface` set to the `ens4` address | `ens4` |
| API (6443) | `bind-address` on servers | the node's private address and loopback |
| Kubelet (10250) | `kubelet-arg address=` | the private address |
| etcd (2379, 2380) | follows `node-ip` | the private address and loopback |
| Shared API address | [`scripts/api-vip.sh`](scripts/api-vip.sh), downloaded by Day 0 once k3s is Ready: kube-vip (static pod, ARP) holds `K3S_API_VIP` on `ens4`, and `k3s-api-vip.service` forwards it to the node's own API. The address is in the API certificate (`tls-san`) | `10.250.0.10` on one node at a time |
| flannel VXLAN (UDP 8472) | cannot be restricted in the k3s config | every interface: keep it closed in the Equinix ACL |
| Web (80, 443) | ServiceLB | each node's public address |

## 7. Exposure and redundancy

Two paths enter the cluster. Each has its own mechanism.

| | Internal exposure (the API) | External exposure (web) |
|---|---|---|
| Who uses it | joining nodes, `kubectl` | users, clients |
| Entry | shared API address `10.250.0.10` | DNS names, one A record per node |
| Mechanism | kube-vip moves the address to a live server | Traefik runs on every node with the same certificate |
| Certificate | the address is in the API certificate (`tls-san`) | cert-manager, Secret `dai-tls` |
| When a node fails | the address moves, if etcd still has a majority | the other node still answers; DNS keeps listing the failed node |
| Needs | 3 servers for a real failover | 2 nodes |

```mermaid
flowchart TB
  subgraph EXT["external"]
    U["user"] -- "svc-dai... A records" --> T1["Traefik node 1"]
    U -.-> T2["Traefik node 2"]
  end
  subgraph INT["internal"]
    J["node or kubectl"] --> VIP(["API address<br/>kube-vip"])
    VIP --> A1["API node 1"]
    VIP -.-> A2["API node 2"]
  end
  T1 --> SVC["stack services<br/>(volumes: section 8)"]
  T2 --> SVC
```

### When a node fails

| Servers up | etcd majority | API | API address |
|---|---|---|---|
| 3 of 3 | yes | works | on one node |
| 2 of 3 | yes | works | moves to a live node (not tested yet) |
| 1 of 3, or 1 of 2 | no | stops; running pods keep serving | cannot move: kube-vip needs the API to choose a holder |

A two-node cluster has no spare: any failure is the last row. The web entry keeps answering on the live node, with the pods that run there.

### Check

- `kubectl get nodes`: all nodes `Ready`, roles `control-plane,etcd`.
- `ip -br a show ens4` on each node: the API address appears on exactly one.
- `curl -sk https://10.250.0.10:6443/healthz` from a node answers `401` (reachable, login required).
- From the internet, 6443 and 10250 are closed.

## 8. Storage replication

**Longhorn** keeps each volume on two nodes. With `K3S_ROLE=server` the first node installs [`longhorn.yaml`](longhorn.yaml) (Longhorn 1.12.2, a `HelmChart`).

| Element | What it does |
|---|---|
| StorageClass `longhorn` | 2 replicas, not the default; `local-path` stays the default |
| Replicas | one copy of the volume on each node, rebuilt automatically |
| Engine | runs next to the pod and writes to both replicas |
| `open-iscsi` | needed on every node; the ADVANCED Day 0 installs it |
| Node failure | `nodeDownPodDeletionPolicy` deletes the pod of a failed node so it restarts on a live node with its copy |
| Over-provisioning | 200%: volumes are thin, and the copies made during a move would otherwise not fit |

```mermaid
flowchart LR
  P["pod"] --> PVC["PVC<br/>class longhorn"] --> E["engine"]
  E --> R1[("replica<br/>node 1")]
  E --> R2[("replica<br/>node 2")]
```

How it works: the PVC is bound to a Longhorn volume; the engine writes each block to both replicas. If a node fails, the pod restarts on the other node and attaches the surviving replica.

A fresh install puts the stack volumes on `local-path`. To move one (stop its workload first): create a `longhorn` PVC, copy the data into it with a pod that mounts both, delete the old PVC, create the real PVC on `longhorn`, copy back, and start the workload. Set the old volume's reclaim policy to `Retain` first, so its data stays on disk as a backup.

| Volume | Size |
|---|---|
| `postgres-data` | 10 Gi |
| `clickhouse-data`, `langfuse-s3-all-in-one-data` | 20 Gi each |
| `llm-guard-data` | 8 Gi |
| `qdrant-storage-qdrant-0` | 5 Gi |
| `rag-service-data` | 3 Gi |
| `redis-data` | 1 Gi |

## 9. AI request flow

```
client -> Traefik :80/:443 -> LiteLLM (ai-litellm:4000)
            pre-call : rag-augment (opt-in) -> rag-service -> Qdrant + SeaweedFS
                       llm-guard -> llm-guard service (prompt injection blocks, secrets redacted)
                       presidio-pre-call -> Presidio (PII masked)
            model    : llm-pool = Groq + Gemini, usage-based routing
            post-call: llm-guard (secrets), presidio-post-call (PII)
            traces   : Langfuse (web -> Postgres, ClickHouse, Redis, SeaweedFS)
```

| Feature | Behaviour |
|---|---|
| Guardrails | LiteLLM loads two custom modules from a ConfigMap (`llm_guard_guardrail.py`, `rag_augment.py`) and uses its native Presidio integration. |
| Injection gate | DeBERTa must flag the text and explicit injection wording must be present before a request is blocked, to avoid false positives on ordinary instructions. |
| RAG | Opt-in per request with `"guardrails": ["rag-augment"]`. Documents (`.txt`, `.md`) go in bucket `rag-docs` and are ingested into Qdrant collection `knowledge-base`. |
| Secrets | None are in `ai-gateway.yaml`. Day 0 creates two Secrets in namespace `ai-gateway`: `ai-secrets` and `litellm-env`. The S3 password is generated by the Langfuse chart. |
| Config source | `ai-gateway.yaml` is generated from `ai-gateway.yaml.in` and `src/` by `scripts/build.py`. |

| Secret | Keys |
|---|---|
| `ai-secrets` | `POSTGRES_USER` `POSTGRES_PASSWORD` `REDIS_PASSWORD` `CLICKHOUSE_PASSWORD` `LANGFUSE_SALT` `LANGFUSE_ENCRYPTION_KEY` (64 hex) `LANGFUSE_NEXTAUTH_SECRET` `LANGFUSE_PUBLIC_KEY` `LANGFUSE_SECRET_KEY` `LANGFUSE_INIT_USER_EMAIL` `LANGFUSE_INIT_USER_PASSWORD` |
| `litellm-env` | `LITELLM_MASTER_KEY` `REDIS_PASSWORD` `GROQ_API_KEY` `GEMINI_API_KEY` `LANGFUSE_PUBLIC_KEY` `LANGFUSE_SECRET_KEY` (same values as in `ai-secrets`) |


### First start

| Component | What happens |
|---|---|
| LLM Guard | Installs CPU PyTorch and `llm-guard` into its volume and downloads the DeBERTa weights: about 10 minutes and a few GB. Its startup probe allows 30 minutes. Later restarts reuse the volume. |
| rag-service | Installs its packages and downloads the embedding model the same way (smaller). |
| LiteLLM, Langfuse, databases | Wait for each other through probes and retries. Expect several restarts in the first minutes. |


### Use

```bash
sudo cat /etc/ai-gateway/credentials.env            # master key, Langfuse login (when installed by Day 0)
curl -k https://<ip>/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"llm-pool","messages":[{"role":"user","content":"hi"}]}'
# Langfuse UI: ssh -L 3000:localhost:3000 <ip>, then on the node: sudo k3s kubectl -n ai-gateway port-forward svc/langfuse-web 3000
# RAG: add .txt/.md files to bucket rag-docs, then ingest
sudo k3s kubectl -n ai-gateway exec deploy/rag-service -- python -c \
  "import httpx;print(httpx.post('http://localhost:8000/ingest',json={},timeout=600).json())"
```

## 10. Repository, build and validate

| Path | What |
|---|---|
| `ai-gateway.yaml` (generated), `ai-gateway.yaml.in`, `src/` | the stack manifest and its sources (LiteLLM config, guardrail modules, chart values) |
| `chat-ui.yaml`, `src/chat-ui/` | the chat page manifest and image |
| `longhorn.yaml` | Longhorn, cluster only |
| `day0/` | the two Day 0 templates |
| `scripts/fqdn.sh` | names and certificates (cert-manager, Traefik, Ingresses, DNS wait) |
| `scripts/api-vip.sh` | shared API address (kube-vip) |
| `scripts/motd.sh`, `scripts/check-install.sh` | login banner, read-only check |
| `scripts/build.py`, `scripts/validate.sh`, `scripts/render-day0.sh` | build the manifest, render every chart, render a Day 0 |

Edit `ai-gateway.yaml.in` and the files under `src/`, then run `scripts/validate.sh`. It builds `ai-gateway.yaml` and renders every chart with `helm template` in Docker. Commit both the sources and the generated file.
