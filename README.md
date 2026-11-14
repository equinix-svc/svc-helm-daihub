# svc-helm-daihub

<img src="assets/logo.svg" alt="DAI Hub" width="120">

AI gateway stack for a single k3s node, as **one file**: [`ai-gateway.yaml`](ai-gateway.yaml). It runs on the plain `k3s-node` image of [svc-ne-byoi-builder](https://github.com/equinix-svc/svc-ne-byoi-builder) (Equinix Network Edge BYOI) and works on any k3s with Traefik and the local-path StorageClass. There are no custom container images and no registry to maintain. It has been validated statically (section 9) but **not yet deployed on a device**, so first-boot behaviour is untested.

## 1. Stack

| Area | Component | How it is deployed |
|---|---|---|
| Gateway | LiteLLM 1.108.0 | public OCI chart `ghcr.io/berriai/litellm-helm` (release `ai`, Service `ai-litellm:4000`) |
| Observability | Langfuse 4.75 (web, worker) | public chart `langfuse` 2.2.3 |
| Guardrails | Presidio analyzer + anonymizer | `mcr.microsoft.com/presidio-*`, plain Deployments |
| | LLM Guard: DeBERTa v3 prompt injection, secrets | `python:3.12-slim`, code in a ConfigMap, `llm-guard` on CPU-only PyTorch installed on first start |
| RAG | Qdrant 1.20 | public chart `qdrant` 1.20.0 |
| | rag-service: fastembed `bge-small-en-v1.5`, ingest from S3 | `python:3.12-slim`, code in a ConfigMap |
| Data | Postgres 16 (databases `litellm`, `langfuse`), Redis 7, ClickHouse 26.8 | official images, plain Deployments |
| S3 | SeaweedFS all-in-one (buckets `langfuse`, `rag-docs`) | shipped by the Langfuse chart; replaces MinIO, whose images are no longer published |

Only LiteLLM is exposed, on 80/443 through Traefik. Everything else stays inside the cluster. Langfuse's own Postgres, Redis and ClickHouse sub-charts are turned off (its ClickHouse needs an operator and a three-node Keeper, too heavy for one node), so Langfuse uses the shared Postgres, Redis and ClickHouse above.

## 2. Quick start

| Step | What |
|---|---|
| 1. VM image | Plain `k3s-node` image (`k3s-node.qcow2`) from [svc-ne-byoi-builder](https://github.com/equinix-svc/svc-ne-byoi-builder). Portal settings: `docs/portal-values.md` in that repo. |
| 2. Container images | The stack uses public images. The chat page image `ghcr.io/equinix-svc/svc-helm-daihub/chat-ui:0.1.0` is private: the node pulls it with `REGISTRY_USER` and `REGISTRY_TOKEN` (required). |
| 3. Day 0 file | [`day0/day0-ai-gateway-basic.yaml`](day0/day0-ai-gateway-basic.yaml) for a single node with two parameters, [`day0/day0-ai-gateway-advanced.yaml`](day0/day0-ai-gateway-advanced.yaml) to join a cluster or set credentials. |
| 4. Parameters | BASIC: `REGISTRY_USER`, `REGISTRY_TOKEN`, `ADMIN_EMAIL` and `FQDN` (required); `GROQ_API_KEY` and `GEMINI_API_KEY` (set them for the models to answer); `ADMIN_PASSWORD` (optional). Create the DNS records for `FQDN` once the node has its IP. Full list: [Day 0 templates](#3-day-0-templates). |

ACL: allow 22 and 80/443. First start takes about 10 minutes (see First start).

## 3. Day 0 templates

Both templates are the Equinix Network Edge Day 0 for the unchanged `k3s-node.qcow2` (portal settings in `docs/portal-values.md` of svc-ne-byoi-builder). They do what that image's own Day 0 does (hostname, static network, portal user, k3s), then on a `single` node or the first `server`, once k3s is Ready:

1. generate the two Secrets (see 6. How it works) with random values, except the keys you pass in, and write the ones you need to `/etc/ai-gateway/credentials.env` (root only);
2. download `ai-gateway.yaml` and the chat page manifest (`chat-ui.yaml`) from this repo into `/var/lib/rancher/k3s/server/manifests/`, where k3s deploys them.

| Template | Use | Portal parameters |
|---|---|---|
| [`day0/day0-ai-gateway-basic.yaml`](day0/day0-ai-gateway-basic.yaml) | **BASIC**: single node, everything else fixed or generated | 7, 4 required |
| [`day0/day0-ai-gateway-advanced.yaml`](day0/day0-ai-gateway-advanced.yaml) | **ADVANCED**: cluster join, chosen credentials, pinned repo version | 14, 4 required |

Equinix predefined (both): `hostname` `userName` `publicKey` `adminPwd` `ipAddressWithCidr` `gateway`. Declare every other variable as a custom parameter in the portal. Render locally with `DAY0_FILE=<file> scripts/render-day0.sh`. Log: `/var/log/day0.log`.

### Parameters

The **BASIC** and **ADVANCED** columns show whether the parameter is required in that template: `yes`, `no`, or `-` (not used). **Default** is what the template uses when a parameter that is not required is left empty. BASIC fixes the unused ones to their default.

| Parameter | BASIC | ADVANCED | Default | Example (paste in the portal) | Meaning |
|---|---|---|---|---|---|
| `REGISTRY_USER` | yes | yes | - | `my-github-user` | GitHub login used to pull the private chat page image from ghcr.io. Day 0 stops the stack install without it. |
| `REGISTRY_TOKEN` | yes | yes | - | `ghp_AbCdEf1234567890AbCdEf1234567890AbCd` | Classic personal access token with only `read:packages`. Written to `/etc/rancher/k3s/registries.yaml` (root only) before k3s starts. Expires: set a reminder to rotate it. |
| `ADMIN_EMAIL` | yes | yes | - | `xxxx@eu.equinix.com` | Login name of the shared admin account (Langfuse, LiteLLM admin UI, chat page login). It must be a real address: it is also the contact for the Let's Encrypt certificates. |
| `FQDN` | yes | yes | - | `fred-dai-par01.example.net` | Public name of the node. Serves `https://<FQDN>` (LiteLLM, chat page) and `https://langfuse.<FQDN>` with Let's Encrypt certificates issued by Traefik. The node's public IP is only known after creation, so create the DNS records afterwards: the node waits (checks every 30 seconds) until `<FQDN>` and `langfuse.<FQDN>` both resolve to it, then enables the certificates, so the first Let's Encrypt attempt succeeds. The login banner shows the IP to use and what each name resolves to now (`not found` or `WRONG` when it points elsewhere, for example after a rebuild with a new IP). Keep port 80 reachable from the internet. |
| `GROQ_API_KEY` | no (for Groq models) | no (for Groq models) | empty | `gsk_AbCdEf1234567890` | Groq API key. |
| `GEMINI_API_KEY` | no (for Gemini models) | no (for Gemini models) | empty | `AIzaSyAbCdEf1234567890` | Gemini API key. |
| `LITELLM_MASTER_KEY` | - | no | generated | `sk-lab-0123456789abcdef` | LiteLLM admin key. |
| `K3S_ROLE` | - | no | `single` | `single` | `single`: standalone node. `server`: control-plane node. With `K3S_SERVER_URL` empty it starts a new cluster and installs the stack; with it set it joins that cluster and the stack is not installed on it. `agent`: k3s worker node that joins an existing cluster; the stack is not installed on it. |
| `K3S_SERVER_URL` | - | no | empty | `https://10.0.0.5:6443` | Agent or joining server. API address (port 6443) of the first server. Empty for `single` or the first `server`. |
| `K3S_TOKEN` | - | no | empty | `K10abc123def456::server:789xyz` | Secret of the k3s cluster. Set the same value on the first `server` (it fixes the secret, so you know it before that node exists) and on every agent or joining server. Empty: k3s generates one. |
| `K3S_TLS_SAN` | - | no | empty | `203.0.113.20` | Extra name or IP in the k3s API server certificate, for `kubectl` or agents reaching port 6443 from outside. Not needed for local `sudo k3s kubectl`. |
| `K3S_PRIVATE_IFACE` | fixed `ens4` | no | `ens4` | `ens4` | Interface used for the private path between nodes. Skipped when it does not exist. |
| `K3S_PRIVATE_IP_CIDR` | fixed (derived) | no | `10.250.<3rd>.<4th>/16` from the node's public IP | `10.250.0.11/24` | Static private address on the private interface. By default derived from the public IP (public `87.237.190.93` gives `10.250.190.93/16`), so nodes do not collide. `none` turns the private path off. |
| `ADMIN_PASSWORD` | no | no | generated | `ChangeMe-2026` | Password of the shared admin account. |

ACL: allow 22 and 80/443. Langfuse, Qdrant and S3 are not exposed.

Private path: by default each node also configures `ens4` with a private address in `10.250.0.0/16` and uses it as the k3s `node-ip` and `flannel-iface`, so cluster traffic (flannel, etcd, the API for joining nodes) stays on it. k3s also listens on the private address only: `bind-address` for the API (6443, plus loopback for k3s itself) on servers and `kubelet-arg address=` for the kubelet (10250); etcd already follows `node-ip`. Only the flannel VXLAN socket (UDP 8472) cannot be restricted in the k3s config: keep it closed in the Equinix ACL. Attach the `ens4` interface (Network Edge `interface2`) of every node to one Fabric Network (EVPLAN, any-to-any), so they share this Layer 2 subnet; a third node is one more connection to the same network. Pick the interface by hand when creating the connection (portal or Terraform): the Fabric MCP tool ignores the interface you give it and may attach `interface3` or `interface4`, which are the encryptor interfaces; joining nodes then use `K3S_SERVER_URL=https://<first node's private IP>:6443`, and port 6443 does not need to be open on the public ACL. The web interfaces stay on the public address. `ens5` (encryptor master to slave) and `ens6` (KME to KME) are reserved for other uses and are not configured here.

## 4. Web interfaces

`<node>` is the public name (`FQDN`, section 3). Until the DNS records exist and the certificates are issued, `https://<node-IP>/` also works, with Traefik's default certificate. One admin account (`ADMIN_EMAIL`, and `ADMIN_PASSWORD` generated when empty) is the login for the chat page, the LiteLLM admin UI and Langfuse. It is in `/etc/ai-gateway/credentials.env`.

| Interface | URL | Access | Login |
|---|---|---|---|
| Chat page (section 5) | `https://<node>/chat/` | public | browser login prompt (Traefik basic auth), then no key to paste |
| LiteLLM admin UI | `https://<node>/ui/` | public | the admin account (`UI_USERNAME` and `UI_PASSWORD`) |
| LiteLLM API | `https://<node>/` | public | `Authorization: Bearer <key>` on `/v1/...` |
| Langfuse (traces) | `https://langfuse.<FQDN>` | public | the admin account |
| Qdrant dashboard (vectors) | `http://localhost:6333/dashboard` | SSH tunnel | none |
| SeaweedFS filer (S3 buckets, RAG documents) | `http://localhost:8888` | SSH tunnel | none |
| rag-service API docs | `http://localhost:8000/docs` | SSH tunnel | none |

The certificates are Let's Encrypt certificates for `FQDN`. Qdrant, SeaweedFS and the rag-service have no login of their own, so they are never exposed.

Tunnel (one terminal per interface; replace the service and ports):

```bash
ssh -L 3000:localhost:3000 <user>@<node> "sudo k3s kubectl -n ai-gateway port-forward svc/langfuse-web 3000"
# Qdrant: svc/qdrant 6333    SeaweedFS filer: svc/langfuse-s3-all-in-one 8888    rag-service: svc/rag-service 8000
```

The login banner (`scripts/motd.sh`, installed by Day 0 in `/etc/profile.d/`) lists these URLs with the live pod count on each interactive SSH login. On an existing node: `sudo curl -fsSL https://raw.githubusercontent.com/equinix-svc/svc-helm-daihub/main/scripts/motd.sh -o /etc/profile.d/dai-hub-motd.sh`.

## 5. Chat page

[`src/chat-ui/`](src/chat-ui/) is a light chat console to test the gateway end to end: one static HTML page served by nginx behind the same Traefik. Day 0 installs it with the stack as its own manifest, `chat-ui.yaml`, and its own container image built by the `images` GitHub workflow on every change under `src/chat-ui/`.

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

## 6. How it works

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

## 7. First start

| Component | What happens |
|---|---|
| LLM Guard | Installs CPU PyTorch and `llm-guard` into its volume and downloads the DeBERTa weights: about 10 minutes and a few GB. Its startup probe allows 30 minutes. Later restarts reuse the volume. |
| rag-service | Installs its packages and downloads the embedding model the same way (smaller). |
| LiteLLM, Langfuse, databases | Wait for each other through probes and retries. Expect several restarts in the first minutes. |

## 8. Use

```bash
sudo cat /etc/ai-gateway/credentials.env            # master key, Langfuse login (when installed by Day 0)
curl -k https://<ip>/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"llm-pool","messages":[{"role":"user","content":"hi"}]}'
# Langfuse UI: ssh -L 3000:localhost:3000 <ip>, then on the node: sudo k3s kubectl -n ai-gateway port-forward svc/langfuse-web 3000
# RAG: add .txt/.md files to bucket rag-docs, then ingest
sudo k3s kubectl -n ai-gateway exec deploy/rag-service -- python -c \
  "import httpx;print(httpx.post('http://localhost:8000/ingest',json={},timeout=600).json())"
```

## 9. What was tested

- The public name path: `fqdn.sh` writes valid manifests (accepted by the cluster API in a server-side dry run); the Traefik chart renders the Let's Encrypt resolver, the certificate volume and the permissions init container; the chat proxy keeps the browser login out of LiteLLM and takes a user's own key from `X-Api-Key`.
- The Qdrant (1.20.0), Langfuse (2.2.3) and LiteLLM (1.108.0) charts render with `helm template` using the values in this file, and every image they use exists (`scripts/validate.sh`).
- A throwaway k3s accepted all 28 resources, including the three `HelmChart`s, in a server-side dry run.
- The LiteLLM guardrail modules import under the real LiteLLM 1.108.0 image, and their hook signatures match.
- Both Day 0 templates (about 12 KB each) render and pass a shell syntax check.

## 10. Findings and limits

- **Public name:** the DNS wait was tested with stand-ins for DNS and the node's addresses. Let's Encrypt issued the certificates on a real node. Traefik requests a certificate about a second after it starts, so its Deployment uses the `Recreate` strategy and its Service publishes not-ready addresses (the validation can otherwise reach the old pod or no pod). The wait compares the DNS answer with the node's own addresses and with the address the internet sees (`api.ipify.org`), through the system resolver; a negative DNS answer can stay cached for a few minutes after you create a record. `sudo cat /etc/ai-gateway/dns-wait.state` shows the state, and `check-install.sh` shows the certificate issuer.
- **Shared login:** one account, three separate sessions (no single sign-on): you type it once per site. The chat page login is browser basic auth.
- **Fail open:** the LLM Guard and RAG modules let a request through unchanged (logged) if their service is unreachable, so injection blocking applies only while LLM Guard answers. How LiteLLM's native Presidio hooks behave when Presidio is down is untested.
- **Floating tags:** `presidio-*:latest`, `python:3.12-slim`, and the packages installed at first start (`llm-guard`, `torch`) can change between boots. Pin them once a deployment is validated.
- **Model names:** the Groq and Gemini names in `src/litellm/config.yaml` come from an earlier lab config and may be stale.
- **Day 0 size:** the Equinix portal limit is 20,000 characters; the template is about 12 KB.
- **Not provided:** TLS certificate beyond Traefik's default, volume backups, and authentication in front of LiteLLM's `/ui` other than its own login.
- **Internet:** the node needs outbound internet at first boot (GitHub, container registries, PyPI, Hugging Face).

## 11. Build and validate

Edit `ai-gateway.yaml.in` and the files under `src/`, then run `scripts/validate.sh`. It builds `ai-gateway.yaml` and renders every chart with `helm template` in Docker. Commit both the sources and the generated file.
