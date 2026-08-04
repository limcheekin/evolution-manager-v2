# Evolution API WhatsApp Gateway → Azure Container Apps

**Implementation guide for Claude Code.** Deploys the `docker-compose.yml` stack (Evolution API v2.3.7 + Evolution Manager v2) to Azure Container Apps in Southeast Asia, backed by Azure Database for PostgreSQL Flexible Server.

Read this file top to bottom before running anything. Every command has been checked against current Microsoft docs and the actual application source at tag `2.3.7`. Section 13 lists the traps that will silently produce a broken-but-apparently-working deployment.

---

## 1. What this deploys

| Compose service | Becomes | Why |
|---|---|---|
| `evolution-api` | Container App `evolution-api`, main container, external ingress :8080 | Long-running WhatsApp gateway |
| `redis` | **Sidecar container** inside `evolution-api`, reachable on `localhost:6379` | Containers in one Container App share a network namespace |
| `postgres` | **Azure Database for PostgreSQL Flexible Server** (managed) | Holds WhatsApp credentials; Postgres is unsupported on Azure Files SMB |
| `evolution-manager` | Container App `evolution-manager`, external ingress :80 | Static nginx SPA, built from source into ACR |
| `evolution_instances` volume | **Dropped** | With `CACHE_REDIS_ENABLED=true` the code writes signal keys to Redis, never to this path. See §13.1 |
| `postgres_data` volume | **Dropped** | Superseded by managed Postgres |
| `evolution-network` | **Dropped** | ACA provides service discovery; the sidecar uses `localhost` |
| `depends_on` | **Dropped** | No ordering primitive in ACA. Evolution API retries its DB connection |
| `restart: unless-stopped` | Implicit | ACA restarts failed containers automatically |

### Final topology

```
Internet
   │
   ├─── https://evolution-manager.<suffix>.southeastasia.azurecontainerapps.io  (:80 → TLS at ingress)
   │         └── nginx + React SPA  ── browser calls the API cross-origin ──┐
   │                                                                        │
   └─── https://evolution-api.<suffix>.southeastasia.azurecontainerapps.io  ◄┘  (:8080 → TLS at ingress)
             Container App "evolution-api", 1 replica pinned
             ├── container: evolution-api   (1.0 vCPU / 2.0Gi)
             └── container: redis           (0.25 vCPU / 0.5Gi)   localhost:6379
                        │
                        └──► Azure Database for PostgreSQL Flexible Server (TLS, sslmode=require)
```

### Decisions already made

- **Bash + `az` CLI**, idempotent, phase by phase.
- **Redis as a sidecar**, not managed. You accepted the durability risk — see §13.1 for what breaks and §14 for the one-revision escape hatch.
- **Both endpoints public.** ACA terminates TLS on both.
- **Region `southeastasia`.**
- **API pinned to exactly 1 replica** (`minReplicas: 1, maxReplicas: 1`). Non-negotiable — see §13.2.

---

## 2. Prerequisites

```bash
# Azure CLI 2.80.0 or newer. Older versions accept flags that were removed;
# newer ones reject flags older guides still use.
az version

# The containerapp extension. Harmless if already present.
az extension add --name containerapp --upgrade

az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"

# Confirm Container Apps is actually available in the target region
az provider show -n Microsoft.App \
  --query "resourceTypes[?resourceType=='managedEnvironments'].locations" -o tsv | tr ',' '\n' | grep -i "southeast asia"

# Register providers (no-op if already registered)
az provider register --namespace Microsoft.App --wait
az provider register --namespace Microsoft.ContainerRegistry --wait
az provider register --namespace Microsoft.DBforPostgreSQL --wait
az provider register --namespace Microsoft.OperationalInsights --wait
```

If the region grep returns nothing, stop and pick another region rather than guessing.

---

## 3. Phase 0 — Variables

Create `.env.deploy`. **Do not commit it.**

```bash
cat > .env.deploy <<'EOF'
# ---- Identity / location ----
export LOCATION="southeastasia"
export RG="evolution-rg"
export SUFFIX="$(whoami | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]' | cut -c1-6)"

# ---- Container registry (must be globally unique, 5-50 alphanumeric) ----
export ACR_NAME="evolutionacr${SUFFIX}"

# ---- PostgreSQL (server name must be globally unique) ----
export PG_SERVER="evolution-pg-${SUFFIX}"
export PG_ADMIN_USER="evoadmin"
export PG_VERSION="16"
export PG_TIER="Burstable"
export PG_SKU="Standard_B1ms"
export PG_STORAGE_GB="32"
export PG_DB_NAME="evolution"

# ---- Container Apps ----
export ACA_ENV="evolution-env"
export API_APP="evolution-api"
export MANAGER_APP="evolution-manager"

# ---- Images ----
export API_IMAGE="evoapicloud/evolution-api:v2.3.7"
export MANAGER_REPO="https://github.com/limcheekin/evolution-manager-v2.git"
export MANAGER_GIT_REF="main"
export MANAGER_IMAGE_NAME="evolution-manager"
export MANAGER_IMAGE_TAG="v2"

# ---- Runtime ----
export TZ_VALUE="Asia/Kuala_Lumpur"
EOF

# Generate secrets separately so they never land in the file above by accident
export POSTGRES_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)Aa1!"
export AUTHENTICATION_API_KEY="$(openssl rand -hex 32)"

source .env.deploy

echo "Save these somewhere safe NOW — they are not recoverable later:"
echo "  POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
echo "  AUTHENTICATION_API_KEY=$AUTHENTICATION_API_KEY"
```

**On `PG_ADMIN_USER`:** do not use `postgres`. Azure Flexible Server rejects a set of reserved admin names, and `postgres` is the one people most often trip over. `evoadmin` is safe.

**On `AUTHENTICATION_API_KEY`:** you must set this explicitly. See §13.3 — the published image ships with a publicly known default.

---

## 4. Phase 1 — Resource group, ACR, build the manager image

The `evolution-manager` service in the compose file uses `build: .`, which ACA cannot do. Build it in ACR instead.

```bash
source .env.deploy

az group create --name "$RG" --location "$LOCATION" --output table

az acr create \
  --resource-group "$RG" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true \
  --output table

# Build from the public git repo. ACR builds linux/amd64 by default, which is
# what both ACA and ACI require.
az acr build \
  --registry "$ACR_NAME" \
  --image "${MANAGER_IMAGE_NAME}:${MANAGER_IMAGE_TAG}" \
  --file Dockerfile \
  "${MANAGER_REPO}#${MANAGER_GIT_REF}"
```

**The `.git` suffix on the repo URL is mandatory.** The CLI matches `\.git(?:#.+)?$` to decide whether a URL is a git repo. Without it, the URL falls through to a `HEAD` request, succeeds (a GitHub repo page returns 200), and gets sent to ACR as a *remote tarball* — the build then fails with a confusing error.

For reproducible rebuilds, replace `#main` with a commit SHA:

```bash
az acr build -r "$ACR_NAME" -t "${MANAGER_IMAGE_NAME}:${MANAGER_IMAGE_TAG}" \
  "${MANAGER_REPO}#a1b2c3d4e5f6"
```

Capture the registry details:

```bash
export ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" -g "$RG" --query loginServer -o tsv)"
export ACR_USERNAME="$(az acr credential show -n "$ACR_NAME" -g "$RG" --query username -o tsv)"
export ACR_PASSWORD="$(az acr credential show -n "$ACR_NAME" -g "$RG" --query 'passwords[0].value' -o tsv)"
export MANAGER_IMAGE="${ACR_LOGIN_SERVER}/${MANAGER_IMAGE_NAME}:${MANAGER_IMAGE_TAG}"

echo "Manager image: $MANAGER_IMAGE"
```

**Verify:**

```bash
az acr repository show-tags -n "$ACR_NAME" --repository "$MANAGER_IMAGE_NAME" -o table
```

---

## 5. Phase 2 — PostgreSQL Flexible Server

```bash
source .env.deploy

az postgres flexible-server create \
  --resource-group "$RG" \
  --name "$PG_SERVER" \
  --location "$LOCATION" \
  --admin-user "$PG_ADMIN_USER" \
  --admin-password "$POSTGRES_PASSWORD" \
  --tier "$PG_TIER" \
  --sku-name "$PG_SKU" \
  --version "$PG_VERSION" \
  --storage-size "$PG_STORAGE_GB" \
  --public-access 0.0.0.0 \
  --yes \
  --output table
```

### Two things that will bite you here

**`--public-access 0.0.0.0` vs `All` mean opposite things.**

| Value | Effect |
|---|---|
| `0.0.0.0` | Firewall rule with start == end == `0.0.0.0` → **Azure services only**. This is what we want. |
| `All` | Expands to `0.0.0.0-255.255.255.255` → **every IP on the internet**. Never use this. |
| `Enabled` | Public networking on, **zero firewall rules** — nothing can connect. |
| `None` | CLI help and CLI implementation disagree. Avoid entirely. |

Security caveat worth stating plainly: `0.0.0.0` allows connections from any IP allocated to any Azure service — **including other customers' subscriptions**. Your admin password is the only thing protecting the server. See §15 for the VNet + private endpoint hardening path.

**`--database-name` no longer works here.** Azure CLI 2.80.0 removed it from `create` (it now applies only to elastic clusters with `--node-count`). The default database is `postgres`. Create the application database explicitly:

```bash
az postgres flexible-server db create \
  --resource-group "$RG" \
  --server-name "$PG_SERVER" \
  --database-name "$PG_DB_NAME" \
  --output table
```

Always pin `--version`. If you omit it, the CLI silently selects the newest version the region offers, so the same script produces different servers over time.

### Build the connection URI

```bash
export PG_FQDN="$(az postgres flexible-server show -g "$RG" -n "$PG_SERVER" --query fullyQualifiedDomainName -o tsv)"

export DATABASE_CONNECTION_URI="postgresql://${PG_ADMIN_USER}:${POSTGRES_PASSWORD}@${PG_FQDN}:5432/${PG_DB_NAME}?schema=evolution_api&sslmode=require"

echo "PG FQDN: $PG_FQDN"
```

`sslmode=require` is mandatory — Flexible Server enforces TLS and rejects TLS 1.0/1.1. If your password contains characters outside the `A-Za-z0-9` + `!` set produced in Phase 0, URL-encode them before interpolating.

**Verify connectivity** (optional; requires `psql` locally and your own IP allowed):

```bash
MY_IP="$(curl -s https://api.ipify.org)"
az postgres flexible-server firewall-rule create \
  -g "$RG" --server-name "$PG_SERVER" \
  --rule-name "temp-admin" --start-ip-address "$MY_IP"

PGPASSWORD="$POSTGRES_PASSWORD" psql \
  "host=$PG_FQDN port=5432 dbname=$PG_DB_NAME user=$PG_ADMIN_USER sslmode=require" -c '\l'

# Remove it when done
az postgres flexible-server firewall-rule delete \
  -g "$RG" --server-name "$PG_SERVER" --rule-name "temp-admin" --yes
```

---

## 6. Phase 3 — Container Apps environment

```bash
source .env.deploy

# Explicit Log Analytics workspace. If you omit --logs-workspace-*, the CLI
# silently creates a workspace with a generated name, which makes the script
# non-reproducible and the resource hard to find later.
export LAW_NAME="evolution-logs-${SUFFIX}"

az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$LAW_NAME" \
  --location "$LOCATION" \
  --output table

export LAW_CUSTOMER_ID="$(az monitor log-analytics workspace show \
  -g "$RG" -n "$LAW_NAME" --query customerId -o tsv)"
export LAW_SHARED_KEY="$(az monitor log-analytics workspace get-shared-keys \
  -g "$RG" -n "$LAW_NAME" --query primarySharedKey -o tsv)"

az containerapp env create \
  --name "$ACA_ENV" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --enable-workload-profiles true \
  --logs-destination log-analytics \
  --logs-workspace-id "$LAW_CUSTOMER_ID" \
  --logs-workspace-key "$LAW_SHARED_KEY" \
  --output table

export ACA_ENV_ID="$(az containerapp env show -g "$RG" -n "$ACA_ENV" --query id -o tsv)"
echo "Environment ID: $ACA_ENV_ID"
```

A workload-profiles environment is created with a single profile named `Consumption`, which is why `workloadProfileName: Consumption` works in the app YAML with no extra setup. Environments cannot be created from YAML — CLI flags only.

---

## 7. Phase 4 — Deploy `evolution-api` with the Redis sidecar

`az containerapp create` has no repeatable `--container` flag. Two containers in one app **requires `--yaml`**.

### 7.1 Write the manifest

```bash
source .env.deploy

cat > evolution-api.yaml <<YAML
location: ${LOCATION}
name: ${API_APP}
type: Microsoft.App/containerApps
properties:
  environmentId: ${ACA_ENV_ID}
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Single
    secrets:
    - name: db-connection-uri
      value: "${DATABASE_CONNECTION_URI}"
    - name: auth-api-key
      value: "${AUTHENTICATION_API_KEY}"
    ingress:
      external: true
      targetPort: 8080
      transport: auto
      allowInsecure: false
      traffic:
      - latestRevision: true
        weight: 100
  template:
    revisionSuffix: r1
    containers:
    - name: evolution-api
      image: ${API_IMAGE}
      resources:
        cpu: 1.0
        memory: 2.0Gi
      env:
      # --- carried over from docker-compose.yml ---
      - name: DATABASE_PROVIDER
        value: postgresql
      - name: DATABASE_CONNECTION_URI
        secretRef: db-connection-uri
      - name: AUTHENTICATION_API_KEY
        secretRef: auth-api-key
      - name: SERVER_PORT
        value: "8080"
      - name: CACHE_REDIS_ENABLED
        value: "true"
      # rewritten: compose service name "redis" -> sidecar on localhost
      - name: CACHE_REDIS_URI
        value: redis://localhost:6379/6
      - name: CACHE_REDIS_PREFIX_KEY
        value: evolution
      # --- added for Azure / correctness (see section 13) ---
      - name: SERVER_TYPE
        value: http
      - name: DATABASE_SAVE_DATA_INSTANCE
        value: "true"
      - name: CACHE_REDIS_SAVE_INSTANCES
        value: "false"
      - name: DATABASE_CONNECTION_CLIENT_NAME
        value: evolution_azure
      - name: CORS_ORIGIN
        value: "*"
      - name: TELEMETRY_ENABLED
        value: "false"
      - name: LOG_COLOR
        value: "false"
      - name: LOG_LEVEL
        value: "ERROR,WARN,INFO"
      - name: TZ
        value: "${TZ_VALUE}"
      probes:
      - type: Startup
        tcpSocket:
          port: 8080
        initialDelaySeconds: 30
        periodSeconds: 10
        failureThreshold: 30
      - type: Liveness
        tcpSocket:
          port: 8080
        periodSeconds: 30
        timeoutSeconds: 5
        failureThreshold: 3
    - name: redis
      image: redis:7-alpine
      resources:
        cpu: 0.25
        memory: 0.5Gi
      args:
      - "--save"
      - ""
      - "--appendonly"
      - "no"
      - "--maxmemory"
      - "384mb"
      - "--maxmemory-policy"
      - "volatile-lru"
    scale:
      minReplicas: 1
      maxReplicas: 1
YAML
```

### 7.2 Why each non-obvious choice

**vCPU/memory must sum to a legal pair.** On the Consumption plan the total across *all* containers in the app must equal one of the allowed combinations (0.25-core steps, memory = 2× vCPU in Gi). Here: `1.0 + 0.25 = 1.25 vCPU` and `2.0 + 0.5 = 2.5 Gi` — a valid pair. Change one container's resources without adjusting the other and `create` fails.

**TCP probes, not HTTP.** Evolution API has **no `/health` endpoint** — I grepped the v2.3.7 tree. `GET /` works and needs no API key, but its handler calls `fetchLatestWaWebVersion()`, which does an **untimed** `axios.get('https://web.whatsapp.com/sw.js')`. With restricted egress that handler can block until the OS TCP timeout, tripping the probe and flapping your app. A TCP probe on 8080 avoids the whole problem.

**`failureThreshold: 30` on the startup probe.** The image's entrypoint is:

```
/bin/bash -c '. ./Docker/scripts/deploy_database.sh && npm run start:prod'
```

`deploy_database.sh` runs `prisma migrate deploy` then `prisma generate` *before* Node starts. First boot against an empty database takes a while. The `&&` also means a migration failure is a startup failure — the container exits and ACA restart-loops. That is correct behaviour, but it means **no separate migration job is needed**.

**`SERVER_URL` is deliberately absent.** It's a chicken-and-egg: the FQDN doesn't exist until the app does. Nothing in the core request path reads it — it only populates the `server_url` field in webhook payloads and registers Chatwoot/Meta callbacks. Phase 6 fills it in.

**Redis `args`.** Persistence off (the data is ephemeral regardless) and a `maxmemory` ceiling so Redis can't OOM-kill its container and take the replica's cache with it. `volatile-lru` evicts only keys that carry a TTL. Caveat: I did not verify whether Baileys signal keys are written with a TTL. If they are, this policy can still evict them under pressure — one more reason §14 exists.

### 7.3 Create

```bash
az containerapp create \
  --name "$API_APP" \
  --resource-group "$RG" \
  --yaml evolution-api.yaml \
  --output table

export API_FQDN="$(az containerapp show -g "$RG" -n "$API_APP" \
  --query properties.configuration.ingress.fqdn -o tsv)"
export API_URL="https://${API_FQDN}"
echo "API URL: $API_URL"
```

`--name` and `--resource-group` are still required alongside `--yaml`; everything else in the YAML wins.

### 7.4 Verify before moving on

```bash
# Watch the migration run. Expect Prisma output, then the Evolution banner.
az containerapp logs show -g "$RG" -n "$API_APP" \
  --container evolution-api --tail 100 --follow

# In another shell — should return JSON with "version": "2.3.7"
curl -s "$API_URL" | jq .

# Confirm the sidecar is reachable from the main container
az containerapp exec -g "$RG" -n "$API_APP" --container evolution-api \
  --command "sh -c 'apt-get install -y redis-tools >/dev/null 2>&1; redis-cli -h localhost ping'"
```

`curl "$API_URL"` should return:

```json
{
  "status": 200,
  "message": "Welcome to the Evolution API, it is working!",
  "version": "2.3.7",
  "clientName": "evolution_azure",
  "manager": "https://evolution-api.<suffix>.southeastasia.azurecontainerapps.io/manager",
  "documentation": "https://doc.evolution-api.com"
}
```

If it hangs rather than returning, egress to `web.whatsapp.com` is blocked — the app is fine, the `GET /` handler is just waiting on that upstream call.

---

## 8. Phase 5 — Deploy `evolution-manager`

```bash
source .env.deploy

cat > evolution-manager.yaml <<YAML
location: ${LOCATION}
name: ${MANAGER_APP}
type: Microsoft.App/containerApps
properties:
  environmentId: ${ACA_ENV_ID}
  workloadProfileName: Consumption
  configuration:
    activeRevisionsMode: Single
    secrets:
    - name: acr-password
      value: "${ACR_PASSWORD}"
    registries:
    - server: ${ACR_LOGIN_SERVER}
      username: ${ACR_USERNAME}
      passwordSecretRef: acr-password
    ingress:
      external: true
      targetPort: 80
      transport: auto
      allowInsecure: false
      traffic:
      - latestRevision: true
        weight: 100
  template:
    revisionSuffix: r1
    containers:
    - name: evolution-manager
      image: ${MANAGER_IMAGE}
      resources:
        cpu: 0.25
        memory: 0.5Gi
      probes:
      - type: Readiness
        httpGet:
          path: /health
          port: 80
        periodSeconds: 10
        failureThreshold: 3
      - type: Liveness
        httpGet:
          path: /health
          port: 80
        periodSeconds: 30
        failureThreshold: 3
    scale:
      minReplicas: 1
      maxReplicas: 3
      rules:
      - name: http-rule
        http:
          metadata:
            concurrentRequests: "100"
YAML

az containerapp create \
  --name "$MANAGER_APP" \
  --resource-group "$RG" \
  --yaml evolution-manager.yaml \
  --output table

export MANAGER_FQDN="$(az containerapp show -g "$RG" -n "$MANAGER_APP" \
  --query properties.configuration.ingress.fqdn -o tsv)"
export MANAGER_URL="https://${MANAGER_FQDN}"
echo "Manager URL: $MANAGER_URL"
```

The manager **can** scale — it's stateless nginx serving static assets, and `.docker/nginx.conf` provides `location /health { return 200; }`, so HTTP probes are safe here. Its `NODE_ENV=production` env var from the compose file is inert for a static nginx image and has been dropped.

**Verify:**

```bash
curl -s -o /dev/null -w "%{http_code}\n" "$MANAGER_URL/health"   # 200
curl -s "$MANAGER_URL" | head -20                                 # SPA index.html
```

---

## 9. Phase 6 — Set `SERVER_URL` (second revision)

Now that the FQDN exists, patch it in. This creates a new revision and restarts the app.

```bash
az containerapp update \
  --name "$API_APP" \
  --resource-group "$RG" \
  --set-env-vars "SERVER_URL=${API_URL}" \
  --output table
```

> **If you later re-apply `evolution-api.yaml`**, remember that the manifest in §7.1 has no `SERVER_URL` entry — applying it with `--yaml` **removes** the value you just set, because `--yaml` replaces the whole template. Either add `SERVER_URL` to the manifest before re-applying, or re-run this phase afterwards. (`deploy.sh` handles this automatically: phase 4 reads the live value and carries it forward.)

Confirm it took effect:

```bash
curl -s "$API_URL" | jq -r .manager   # should show your API FQDN, not localhost
```

---

## 10. Phase 7 — Smoke test

```bash
source .env.deploy

# 1. API responds
curl -s "$API_URL" | jq '{version, clientName}'

# 2. API key is enforced — expect 401
curl -s -o /dev/null -w "no key:   %{http_code}\n" "$API_URL/instance/fetchInstances"

# 3. API key works — expect 200
curl -s -o /dev/null -w "with key: %{http_code}\n" \
  -H "apikey: $AUTHENTICATION_API_KEY" "$API_URL/instance/fetchInstances"

# 4. CORS preflight from the manager origin — expect access-control-allow-origin
curl -s -I -X OPTIONS "$API_URL/instance/fetchInstances" \
  -H "Origin: $MANAGER_URL" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: apikey" | grep -i access-control

# 5. Manager serves
curl -s -o /dev/null -w "manager:  %{http_code}\n" "$MANAGER_URL/health"

# 6. Migrations actually created tables
az containerapp logs show -g "$RG" -n "$API_APP" --container evolution-api --tail 200 \
  | grep -iE "migration|prisma" | head -20
```

All six must pass before you try to link a phone.

---

## 11. Phase 8 — Link a WhatsApp number

```bash
# Create an instance
curl -s -X POST "$API_URL/instance/create" \
  -H "apikey: $AUTHENTICATION_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"instanceName":"primary","integration":"WHATSAPP-BAILEYS","qrcode":true}' | jq .

# Fetch the QR (base64 PNG)
curl -s "$API_URL/instance/connect/primary" \
  -H "apikey: $AUTHENTICATION_API_KEY" | jq -r '.base64' \
  | sed 's|^data:image/png;base64,||' | base64 -d > qr.png
```

Open `qr.png` and scan it from WhatsApp → **Linked Devices → Link a Device**.

### Using the manager UI

Open `$MANAGER_URL` in a browser. You'll land on the login screen.

**The pre-filled Server URL is wrong.** The SPA defaults that field to its own origin (`window.location.origin`), which is correct only in the upstream layout where Evolution API serves the manager at `/manager` on the same host. On this split deployment you must **overwrite it with the API URL**:

| Field | Value |
|---|---|
| Server URL | `https://evolution-api.<suffix>.southeastasia.azurecontainerapps.io` |
| API Key | your `AUTHENTICATION_API_KEY` |

The value is stored in browser `localStorage` under the key `apiUrl`. There is no env var or build arg that can preconfigure it — the image contains no `VITE_`/`import.meta.env` references at all, despite what its README claims. It is per-browser-profile and lost on logout or on clearing site data.

**Live chat updates will not work**, and that's expected. Websockets are off by default (`WEBSOCKET_ENABLED=false`). Enabling them for the manager would additionally require `WEBSOCKET_ALLOWED_HOSTS=*`, because the browser cannot attach an `apikey` header to a WebSocket handshake and behind ACA ingress the socket peer address is never `127.0.0.1`. That combination disables websocket authentication entirely and would expose your whole event stream unauthenticated on a public endpoint. Leave it off; use webhooks for event delivery. Instance CRUD and QR display go over REST and work fine.

---

## 12. Verification checklist

| # | Check | Command | Expected |
|---|---|---|---|
| 1 | Manager image in ACR | `az acr repository show-tags -n $ACR_NAME --repository evolution-manager` | `v2` |
| 2 | Postgres reachable | Phase 2 `psql` block | database list |
| 3 | `evolution` DB exists | `az postgres flexible-server db list -g $RG -s $PG_SERVER -o table` | `evolution` present |
| 4 | API revision healthy | `az containerapp revision list -g $RG -n $API_APP --query "[].{n:name,active:properties.active,healthy:properties.healthState}" -o table` | `active: true`, `healthy: Healthy` |
| 5 | Both containers running | `az containerapp replica list -g $RG -n $API_APP -o json \| jq '.[].properties.containers[].name'` | `evolution-api`, `redis` |
| 6 | Replica count pinned | `az containerapp show -g $RG -n $API_APP --query properties.template.scale` | `min 1 / max 1` |
| 7 | Migrations ran | logs grep for `prisma` | migration output, no errors |
| 8 | API key enforced | Phase 7 step 2 | `401` |
| 9 | CORS headers present | Phase 7 step 4 | `access-control-allow-origin` |
| 10 | Manager health | `curl $MANAGER_URL/health` | `200` |
| 11 | `SERVER_URL` correct | `curl -s $API_URL \| jq -r .manager` | API FQDN, not localhost |
| 12 | Secrets not plaintext | `az containerapp show -g $RG -n $API_APP -o yaml \| grep -A2 "name: DATABASE_CONNECTION_URI"` | `secretRef`, no value |

---

## 13. Traps

Each of these produces a deployment that looks fine and isn't.

### 13.1 Redis holds signal keys, not just cache — **you accepted this risk**

`use-multi-file-auth-state-prisma.ts`:

```ts
async function writeData(data, key) {
  if (key != 'creds') {
    if (cacheConfig.REDIS.ENABLED) { return await cache.hSet(sessionId, key, data); }
    else { await fs.writeFile(localFile(key), dataString); return; }
  }
  await saveKey(sessionId, dataString);   // creds → Postgres, always
}
```

`CACHE_REDIS_SAVE_INSTANCES=false` sends **credentials** to Postgres. But the Baileys **signal keys** — per-contact Signal sessions, pre-keys, `app-state-sync-key`, sender-keys — follow `CACHE_REDIS_ENABLED`, which is `true` here. They live in the ephemeral sidecar.

**Failure mode:** any revision update, image change, container restart, or Redis OOM loses them. The session still authenticates from Postgres, so the API reports `state: open` and the phone shows the device as linked — but inbound messages fail to decrypt ("Bad MAC", "waiting for this message"). It looks like a WhatsApp problem, not an infrastructure one.

**Anything that triggers it:** `az containerapp update`, a new image tag, an ACA platform maintenance restart, Redis exceeding 384 MB.

If you see decryption failures after any deployment, go to §14.

### 13.2 Never scale the API past one replica

Two replicas share one credential set, so both present the same linked-device identity to WhatsApp. WhatsApp responds with `Stream Errored (conflict)` → `device_removed` → `401 Logged Out`, and you re-scan. Separately, every replica races `prisma migrate deploy` on start (Prisma takes an advisory lock, so it's safe but serialised).

Scale-to-zero is equally wrong, for a different reason: inbound messages arrive over the **persistent WebSocket** Baileys holds open to WhatsApp, not over inbound HTTP. ACA's HTTP scaler only wakes a replica on an incoming HTTP request. At zero replicas there's no socket, so messages are silently missed and nothing will ever wake the app.

`minReplicas: 1, maxReplicas: 1`. Do not "optimize" this.

### 13.3 The image ships a publicly known API key

The Dockerfile does `COPY ./.env.example ./.env`, and `dotenv.config()` runs at import. dotenv does not overwrite variables you set explicitly — but **anything you omit falls back to the baked `.env.example` value, not to the code default.**

The most dangerous instance: `AUTHENTICATION_API_KEY` defaults to `429683C4C977415CAAFCCE10F7D57E11`, which is in the public repo. Omit it on a public endpoint and your gateway is world-writable. `CACHE_REDIS_URI` similarly defaults to `redis://localhost:6379/6` and `DATABASE_CONNECTION_URI` to a bogus placeholder that yields a confusing migration error rather than a clear "unset" one. The manifest in §7.1 sets all three explicitly.

### 13.4 Keep `CORS_ORIGIN=*`

An explicit allowlist returns **HTTP 500 for every request with no `Origin` header**. In `main.ts` the origin callback does `ORIGIN.indexOf(requestOrigin)`, `requestOrigin` is `undefined` for non-browser callers, `indexOf(undefined) === -1`, so it calls `callback(new Error('Not allowed by CORS'))` → `next(err)` → the 500 handler. That breaks `curl`, server-to-server integrations, n8n, Postman, and HTTP health probes.

If you must use an allowlist: no spaces after commas (`split(',')` does not trim), always include the scheme, never a trailing slash — and don't use an HTTP probe.

`*` here is safe to combine with credentials, incidentally: the middleware calls `callback(null, true)`, and `cors@2.8.5` reflects the request origin rather than emitting a literal `*`. It's still open CORS. Restrict at the ingress or WAF layer instead.

### 13.5 `DATABASE_SAVE_DATA_INSTANCE` is load-bearing

It gates `useMultiFileAuthStatePrisma` in `defineAuthState()`. If it's false *and* Redis-save is off, `defineAuthState()` returns `undefined` and instances cannot persist credentials at all. The baked `.env` sets it `true`, but the code default is `false` — so set it explicitly rather than relying on which one wins.

### 13.6 Leave `PROVIDER_ENABLED` unset

It is *not* a local file-storage backend — it's a client for a separate remote HTTP microservice. If enabled without that service running, `onModuleInit()` fails its ping and the app **self-terminates with `execFileSync('kill', ['-9', ...])`**, giving you an unrecoverable ACA crash-loop with a baffling signature. It also takes priority over both Redis and Postgres credential storage.

### 13.7 Telemetry is opt-out

`TELEMETRY_ENABLED` is on unless explicitly `'false'`, and posts `{route, apiVersion, timestamp}` to `https://log.evolution-api.com/telemetry` on every request except `/`. Disabled in the manifest above.

### 13.8 Miscellaneous

- **`TZ` defaults to `America/Sao_Paulo`** in the image. Set it.
- **`LOG_COLOR=true`** in the baked `.env` — ANSI escapes pollute Log Analytics. Set `false`.
- **`DATABASE_URL` is not the variable.** The entrypoint exports it but the Prisma schema reads `env("DATABASE_CONNECTION_URI")`. Set only the latter.
- **No read-only root filesystem.** `db:deploy` does `rm -rf ./prisma/migrations && cp -r …` on every start.
- **ACA request timeout is 240 s**, fixed.
- **The git tag is `2.3.7`, not `v2.3.7`** (the *image* tag has the `v`). The canonical repo is now `evolution-foundation/evolution-api`.

---

## 14. Escape hatch: move signal keys to durable storage

If §13.1 bites — decryption failures after a deployment — this migrates signal keys from ephemeral Redis to an Azure Files share. It costs roughly ten cents a month and removes a container. Expect to re-link your instances once during the switch.

```bash
source .env.deploy
export SA_NAME="evolutionsa${SUFFIX}"

az storage account create -g "$RG" -n "$SA_NAME" -l "$LOCATION" --sku Standard_LRS --output table
az storage share-rm create -g "$RG" --storage-account "$SA_NAME" -n evolution-instances --quota 5 --output table

export SA_KEY="$(az storage account keys list -g "$RG" -n "$SA_NAME" --query '[0].value' -o tsv)"

# Note: omit --storage-type. It only exists with the containerapp extension
# installed, and AzureFile is the default, so omitting it works everywhere.
az containerapp env storage set \
  --name "$ACA_ENV" \
  --resource-group "$RG" \
  --storage-name evolution-instances \
  --access-mode ReadWrite \
  --azure-file-account-name "$SA_NAME" \
  --azure-file-account-key "$SA_KEY" \
  --azure-file-share-name evolution-instances \
  --output table
```

Then edit `evolution-api.yaml`:

1. Set `CACHE_REDIS_ENABLED` to `"false"`.
2. Delete the entire `redis` container block.
3. Change the `evolution-api` container resources to `cpu: 1.25` / `memory: 2.5Gi` — the app now owns the whole allocation, and the total must still be a legal pair.
4. Add to the `evolution-api` container:

```yaml
      volumeMounts:
      - volumeName: instances
        mountPath: /evolution/instances
```

5. Add under `template:` (sibling of `containers:` and `scale:`):

```yaml
    volumes:
    - name: instances
      storageType: AzureFile
      storageName: evolution-instances
```

6. Apply: `az containerapp update -g "$RG" -n "$API_APP" --yaml evolution-api.yaml`

Trade-off: no cache layer, so slightly more Postgres queries. For a single-tenant gateway that's immaterial. Note that Azure Cache for Redis is *not* an alternative here — [data persistence is Premium-tier only](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-premium-persistence), so Basic and Standard lose the keys just as the sidecar does.

---

## 15. Hardening (after it works)

Ordered by value per unit of effort.

1. **Managed identity for ACR** instead of admin credentials. Assign `acrPull` to the app's identity and drop the `acr-password` secret and `--admin-enabled`.
2. **Key Vault for secrets.** ACA secrets support `keyVaultUrl` + `identity` in place of inline `value`, which gets the Postgres password and API key out of your YAML and shell history.
3. **VNet + private endpoint for Postgres.** Replaces the `0.0.0.0` Azure-services firewall rule, which today permits connections from any Azure IP including other tenants'. Requires `--infrastructure-subnet-resource-id` on the ACA environment, which cannot be added to an existing environment — plan it before you care about uptime.
4. **Custom domain + managed certificate.** Also lets you set `SERVER_URL` correctly up front instead of in a second revision.
5. **IP restrictions on the manager.** It's an admin console on a public URL. `az containerapp ingress access-restriction set` limits it to your office ranges.
6. **`--zone-redundant`** on the ACA environment and `--zonal-resiliency Enabled` on Postgres, if downtime matters. Both are create-time only.
7. **Alerts** on API replica restarts and Postgres connection failures — restarts are your §13.1 early-warning signal.

---

## 16. Cost shape

I have not verified current Southeast Asia rates, so treat this as a shape rather than a quote — check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

| Component | Driver |
|---|---|
| Container App `evolution-api` | 1.25 vCPU / 2.5 GiB running 24/7. The dominant line item. |
| Container App `evolution-manager` | 0.25 vCPU / 0.5 GiB, scales 1–3. |
| PostgreSQL Flexible Server | Burstable `Standard_B1ms` + 32 GiB storage. |
| ACR Basic | Flat, small. |
| Log Analytics | Ingestion volume — the reason for `LOG_LEVEL=ERROR,WARN,INFO`. |

Container Apps' free monthly grant (180,000 vCPU-seconds = 50 vCPU-hours per subscription) covers about 7% of one always-on 1-vCPU replica across a 730-hour month. Don't plan around it. Because the API is pinned to one replica, you get none of Container Apps' scale-to-zero savings here — you're paying for managed TLS, a stable FQDN, and revision rollback, not for elasticity.

---

## 17. Teardown

```bash
source .env.deploy
az group delete --name "$RG" --yes --no-wait
```

Removes everything. The linked WhatsApp device stays registered on the phone until you remove it manually in **WhatsApp → Linked Devices**.

---

## 18. Source notes

Verified against primary sources, not recalled:

- Compose→ACI retirement, `az containerapp compose create` GA status: Azure CLI reference.
- No repeatable `--container` flag; `--yaml` ARM envelope shape; secret/`secretRef` syntax; legal vCPU/memory pairs: `az containerapp` CLI reference + [Containers in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/containers).
- `--public-access 0.0.0.0` vs `All`; `--database-name` removal in CLI 2.80.0; TLS enforcement: `az postgres flexible-server` reference + Azure CLI source.
- `az acr build` requiring `.git`, defaulting to linux/amd64: ACR Tasks docs + `_archive_utils.py`.
- Entrypoint, migration behaviour, env var defaults, CORS callback, `writeData` key routing, absence of `/health`, websocket `allowRequest` logic: `evolution-foundation/evolution-api` at tag `2.3.7` plus the published `evoapicloud/evolution-api:v2.3.7` image config blob.
- Manager port 80, `/health` location, `localStorage.apiUrl`, absence of any `VITE_` handling: `limcheekin/evolution-manager-v2` at `main`.
- Redis persistence being Premium-only: [Azure Cache for Redis data persistence](https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-how-to-premium-persistence).

**Not verified:** no runtime testing was performed. The two behaviours most worth confirming empirically on first deploy are the CORS 500-on-missing-`Origin` path (§13.4) and whether Baileys signal keys carry a TTL, which determines how much the `volatile-lru` policy actually protects them (§7.2).
