#!/usr/bin/env bash
#
# Evolution API WhatsApp gateway -> Azure Container Apps (Southeast Asia)
#
# Companion script to EVOLUTION_ACA_DEPLOYMENT_GUIDE.md. Read that first —
# it explains why each setting is what it is, and section 13 lists the traps.
#
# Usage:
#   ./deploy.sh init          # write .env.deploy and generate secrets
#   ./deploy.sh all           # run phases 1-6 in order
#   ./deploy.sh 1             # resource group + ACR + build manager image
#   ./deploy.sh 2             # PostgreSQL Flexible Server
#   ./deploy.sh 3             # Container Apps environment
#   ./deploy.sh 4             # evolution-api (with redis sidecar)
#   ./deploy.sh 5             # evolution-manager
#   ./deploy.sh 6             # patch SERVER_URL
#   ./deploy.sh verify        # smoke tests
#   ./deploy.sh urls          # print both FQDNs
#   ./deploy.sh logs          # tail the API container
#   ./deploy.sh destroy       # delete the whole resource group
#
# Every phase is idempotent: re-running it is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.deploy"
SECRETS_FILE="${SCRIPT_DIR}/.secrets.deploy"

# ---------------------------------------------------------------- helpers ----

c_reset=$'\033[0m'; c_blue=$'\033[34m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_red=$'\033[31m'

step()  { printf '%s==>%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s ERR%s %s\n' "$c_red"   "$c_reset" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

exists() {
  # exists <az-show-command...>  -> 0 if the resource is there
  "$@" >/dev/null 2>&1
}

# ------------------------------------------------------------------- init ----

cmd_init() {
  need az; need openssl

  if [[ -f "$ENV_FILE" ]]; then
    warn "$ENV_FILE already exists — leaving it alone"
  else
    local suffix
    suffix="$(openssl rand -hex 3)"
    cat > "$ENV_FILE" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). Safe to commit? NO.
export LOCATION="southeastasia"
export RG="evolution-rg"
export SUFFIX="${suffix}"

export ACR_NAME="evolutionacr\${SUFFIX}"

export PG_SERVER="evolution-pg-\${SUFFIX}"
export PG_ADMIN_USER="evoadmin"
export PG_VERSION="16"
export PG_TIER="Burstable"
export PG_SKU="Standard_B1ms"
export PG_STORAGE_GB="32"
export PG_DB_NAME="evolution"

export ACA_ENV="evolution-env"
export LAW_NAME="evolution-logs-\${SUFFIX}"
export API_APP="evolution-api"
export MANAGER_APP="evolution-manager"

export API_IMAGE="evoapicloud/evolution-api:v2.3.7"
export MANAGER_REPO="https://github.com/limcheekin/evolution-manager-v2.git"
export MANAGER_GIT_REF="main"
export MANAGER_IMAGE_NAME="evolution-manager"
export MANAGER_IMAGE_TAG="v2"

export TZ_VALUE="Asia/Kuala_Lumpur"
EOF
    ok "wrote $ENV_FILE"
  fi

  if [[ -f "$SECRETS_FILE" ]]; then
    warn "$SECRETS_FILE already exists — keeping existing secrets"
  else
    local pg_pw api_key
    # Azure Postgres requires 8-128 chars from 3 of 4 categories.
    # Restricted to URL-safe characters so the connection URI needs no encoding.
    pg_pw="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)Aa1"
    api_key="$(openssl rand -hex 32)"
    umask 077
    cat > "$SECRETS_FILE" <<EOF
export POSTGRES_PASSWORD='${pg_pw}'
export AUTHENTICATION_API_KEY='${api_key}'
EOF
    ok "wrote $SECRETS_FILE (mode 600)"
    warn "back this file up — the values are not recoverable from Azure"
  fi

  printf '\nNext: ./deploy.sh all\n'
}

load_env() {
  [[ -f "$ENV_FILE" ]]     || die "$ENV_FILE not found — run: ./deploy.sh init"
  [[ -f "$SECRETS_FILE" ]] || die "$SECRETS_FILE not found — run: ./deploy.sh init"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  : "${LOCATION:?}" "${RG:?}" "${ACR_NAME:?}" "${PG_SERVER:?}"
  : "${POSTGRES_PASSWORD:?}" "${AUTHENTICATION_API_KEY:?}"
}

preflight() {
  need az; need jq; need curl
  az account show >/dev/null 2>&1 || die "not logged in — run: az login"

  local ver
  ver="$(az version --query '"azure-cli"' -o tsv)"
  step "azure-cli $ver"
  # 2.80.0 removed --database-name from postgres flexible-server create.
  if [[ "$(printf '%s\n2.80.0\n' "$ver" | sort -V | head -1)" != "2.80.0" ]]; then
    warn "azure-cli $ver is older than 2.80.0; this script targets 2.80.0+"
  fi

  az extension show --name containerapp >/dev/null 2>&1 \
    || { step "installing containerapp extension"; az extension add --name containerapp --only-show-errors; }
}

# ---------------------------------------------------- phase 1: ACR + image ----

phase_1() {
  load_env; preflight

  step "resource group $RG"
  if exists az group show -n "$RG"; then ok "exists"; else
    az group create -n "$RG" -l "$LOCATION" -o none && ok "created"
  fi

  step "container registry $ACR_NAME"
  if exists az acr show -n "$ACR_NAME" -g "$RG"; then ok "exists"; else
    az acr create -g "$RG" -n "$ACR_NAME" --sku Basic --admin-enabled true -o none && ok "created"
  fi

  step "building ${MANAGER_IMAGE_NAME}:${MANAGER_IMAGE_TAG} from ${MANAGER_GIT_REF}"
  # The .git suffix is mandatory — without it the CLI treats the URL as a
  # remote tarball and the build fails confusingly.
  #
  # --no-logs is a Windows workaround, not a behaviour change. az.cmd starts
  # Python in isolated mode (-I implies -E), so PYTHONIOENCODING / PYTHONUTF8 are
  # ignored and sys.stdout stays cp1252. The Vite build log contains U+2713,
  # which makes the CLI's log streamer (acr/_stream_utils.py) die with
  # UnicodeEncodeError *after* ACR has already built and pushed the image — a
  # non-zero exit for a build that actually succeeded. --no-format does not help;
  # it only bypasses colorama, not the cp1252 stdout.
  #
  # --no-logs still polls to a terminal state (unlike --no-wait) and still
  # reports a genuine build failure, which the status assertion below catches.
  # To read build logs, use the printed run ID from a UTF-8 console or the portal:
  #   az acr task logs -r "$ACR_NAME" --run-id <runId>
  local build_result
  build_result="$(az acr build \
    --registry "$ACR_NAME" \
    --image "${MANAGER_IMAGE_NAME}:${MANAGER_IMAGE_TAG}" \
    --file Dockerfile \
    --no-logs -o json \
    "${MANAGER_REPO}#${MANAGER_GIT_REF}" | jq -r '.runId + " " + .status')"
  [[ "$build_result" == *" Succeeded" ]] || die "acr build failed: run $build_result"
  ok "image pushed (run $build_result)"

  az acr repository show-tags -n "$ACR_NAME" --repository "$MANAGER_IMAGE_NAME" -o table
}

acr_facts() {
  ACR_LOGIN_SERVER="$(az acr show -n "$ACR_NAME" -g "$RG" --query loginServer -o tsv)"
  ACR_USERNAME="$(az acr credential show -n "$ACR_NAME" -g "$RG" --query username -o tsv)"
  ACR_PASSWORD="$(az acr credential show -n "$ACR_NAME" -g "$RG" --query 'passwords[0].value' -o tsv)"
  MANAGER_IMAGE="${ACR_LOGIN_SERVER}/${MANAGER_IMAGE_NAME}:${MANAGER_IMAGE_TAG}"
}

# ------------------------------------------------------ phase 2: postgres ----

phase_2() {
  load_env; preflight

  step "postgres flexible server $PG_SERVER"
  if exists az postgres flexible-server show -g "$RG" -n "$PG_SERVER"; then
    ok "exists"
  else
    # --public-access 0.0.0.0 == "Azure services only".
    # --public-access All    == every IP on the internet. Do not use.
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
      --yes -o none
    ok "created"
  fi

  step "database $PG_DB_NAME"
  # --database-name was removed from `create` in azure-cli 2.80.0; the default
  # database is `postgres`, so the app database must be created separately.
  if az postgres flexible-server db show -g "$RG" -s "$PG_SERVER" -d "$PG_DB_NAME" >/dev/null 2>&1; then
    ok "exists"
  else
    az postgres flexible-server db create -g "$RG" -s "$PG_SERVER" -d "$PG_DB_NAME" -o none && ok "created"
  fi

  pg_facts
  ok "FQDN $PG_FQDN"
}

pg_facts() {
  PG_FQDN="$(az postgres flexible-server show -g "$RG" -n "$PG_SERVER" \
    --query fullyQualifiedDomainName -o tsv)"
  DATABASE_CONNECTION_URI="postgresql://${PG_ADMIN_USER}:${POSTGRES_PASSWORD}@${PG_FQDN}:5432/${PG_DB_NAME}?schema=evolution_api&sslmode=require"
}

# ---------------------------------------------------------- phase 3: env -----

phase_3() {
  load_env; preflight

  step "log analytics workspace $LAW_NAME"
  if exists az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME"; then ok "exists"; else
    az monitor log-analytics workspace create -g "$RG" -n "$LAW_NAME" -l "$LOCATION" -o none && ok "created"
  fi

  local law_id law_key
  law_id="$(az monitor log-analytics workspace show -g "$RG" -n "$LAW_NAME" --query customerId -o tsv)"
  law_key="$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LAW_NAME" --query primarySharedKey -o tsv)"

  step "container apps environment $ACA_ENV"
  if exists az containerapp env show -g "$RG" -n "$ACA_ENV"; then ok "exists"; else
    az containerapp env create \
      --name "$ACA_ENV" \
      --resource-group "$RG" \
      --location "$LOCATION" \
      --enable-workload-profiles true \
      --logs-destination log-analytics \
      --logs-workspace-id "$law_id" \
      --logs-workspace-key "$law_key" -o none
    ok "created"
  fi

  env_facts
  ok "environment id captured"
}

env_facts() {
  ACA_ENV_ID="$(az containerapp env show -g "$RG" -n "$ACA_ENV" --query id -o tsv)"
}

# ------------------------------------------------------- phase 4: API app ----

render_api_yaml() {
  local server_url="${1:-}"
  cat > "${SCRIPT_DIR}/evolution-api.yaml" <<YAML
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
    containers:
    - name: evolution-api
      image: ${API_IMAGE}
      resources:
        cpu: 1.0
        memory: 2.0Gi
      env:
      - name: DATABASE_PROVIDER
        value: postgresql
      - name: DATABASE_CONNECTION_URI
        secretRef: db-connection-uri
      - name: DATABASE_CONNECTION_CLIENT_NAME
        value: evolution_azure
      - name: DATABASE_SAVE_DATA_INSTANCE
        value: "true"
      - name: AUTHENTICATION_API_KEY
        secretRef: auth-api-key
      - name: SERVER_PORT
        value: "8080"
      - name: SERVER_TYPE
        value: http$([[ -n "$server_url" ]] && printf '\n      - name: SERVER_URL\n        value: "%s"' "$server_url")
      - name: CACHE_REDIS_ENABLED
        value: "true"
      - name: CACHE_REDIS_URI
        value: redis://localhost:6379/6
      - name: CACHE_REDIS_PREFIX_KEY
        value: evolution
      - name: CACHE_REDIS_SAVE_INSTANCES
        value: "false"
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
}

phase_4() {
  load_env; preflight; pg_facts; env_facts

  # If phase 6 has already run, SERVER_URL is set on the live app. Re-rendering
  # the manifest without it would silently remove it, so carry it forward.
  local existing_server_url=""
  if exists az containerapp show -g "$RG" -n "$API_APP"; then
    existing_server_url="$(az containerapp show -g "$RG" -n "$API_APP" -o json 2>/dev/null \
      | jq -r '[.properties.template.containers[]?.env[]?
                | select(.name=="SERVER_URL") | .value] | first // ""')"
    [[ -n "$existing_server_url" ]] && ok "preserving SERVER_URL=$existing_server_url"
  fi

  # Two containers in one app cannot be expressed with CLI flags — no
  # repeatable --container exists. --yaml is the only route.
  render_api_yaml "$existing_server_url"
  ok "rendered evolution-api.yaml"

  step "container app $API_APP"
  if exists az containerapp show -g "$RG" -n "$API_APP"; then
    az containerapp update -g "$RG" -n "$API_APP" --yaml "${SCRIPT_DIR}/evolution-api.yaml" -o none
    ok "updated"
  else
    az containerapp create -g "$RG" -n "$API_APP" --yaml "${SCRIPT_DIR}/evolution-api.yaml" -o none
    ok "created"
  fi

  api_facts
  ok "API $API_URL"
  warn "first boot runs prisma migrate deploy — allow 1-3 minutes"
}

api_facts() {
  API_FQDN="$(az containerapp show -g "$RG" -n "$API_APP" \
    --query properties.configuration.ingress.fqdn -o tsv)"
  API_URL="https://${API_FQDN}"
}

# --------------------------------------------------- phase 5: manager app ----

phase_5() {
  load_env; preflight; env_facts; acr_facts

  cat > "${SCRIPT_DIR}/evolution-manager.yaml" <<YAML
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
  ok "rendered evolution-manager.yaml"

  step "container app $MANAGER_APP"
  if exists az containerapp show -g "$RG" -n "$MANAGER_APP"; then
    az containerapp update -g "$RG" -n "$MANAGER_APP" --yaml "${SCRIPT_DIR}/evolution-manager.yaml" -o none
    ok "updated"
  else
    az containerapp create -g "$RG" -n "$MANAGER_APP" --yaml "${SCRIPT_DIR}/evolution-manager.yaml" -o none
    ok "created"
  fi

  manager_facts
  ok "Manager $MANAGER_URL"
}

manager_facts() {
  MANAGER_FQDN="$(az containerapp show -g "$RG" -n "$MANAGER_APP" \
    --query properties.configuration.ingress.fqdn -o tsv)"
  MANAGER_URL="https://${MANAGER_FQDN}"
}

# ------------------------------------------------- phase 6: SERVER_URL -------

phase_6() {
  load_env; preflight; api_facts

  step "patching SERVER_URL=$API_URL"
  az containerapp update -g "$RG" -n "$API_APP" \
    --set-env-vars "SERVER_URL=${API_URL}" -o none
  ok "revision created"
}

# ----------------------------------------------------------------- verify ----

cmd_verify() {
  load_env; preflight; api_facts; manager_facts
  local fails=0

  # Every check below must run even when an earlier one fails, so that the
  # operator sees all 8 results. Two things fight that under `set -e`:
  #   - `((fails++))` evaluates to the OLD value, so the first increment (0)
  #     makes the arithmetic command exit 1 and kills the script. Use an
  #     assignment, which is always exit 0.
  #   - a value capture whose command fails (curl exit 7 on connection refused,
  #     az on a missing resource) propagates that status. Guard each with
  #     `|| true` and let the comparison below report the miss.
  fail() { warn "$*"; fails=$((fails + 1)); }

  step "waiting for API to answer (up to 180s)"
  local i
  for i in $(seq 1 36); do
    if curl -fsS --max-time 5 "$API_URL" >/dev/null 2>&1; then break; fi
    sleep 5
  done

  step "1. API root"
  if curl -fsS --max-time 20 "$API_URL" | jq -e '.version' >/dev/null 2>&1; then
    ok "version $(curl -fsS --max-time 20 "$API_URL" | jq -r .version)"
  else
    fail "no JSON from $API_URL (may still be migrating, or egress to web.whatsapp.com is blocked)"
  fi

  step "2. API key enforced"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$API_URL/instance/fetchInstances" || true)"
  if [[ "$code" == "401" ]]; then ok "401 without key"; else fail "expected 401, got ${code:-<no response>}"; fi

  step "3. API key accepted"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "apikey: $AUTHENTICATION_API_KEY" "$API_URL/instance/fetchInstances" || true)"
  if [[ "$code" == "200" ]]; then ok "200 with key"; else fail "expected 200, got ${code:-<no response>}"; fi

  step "4. CORS preflight from manager origin"
  if curl -s -I --max-time 15 -X OPTIONS "$API_URL/instance/fetchInstances" \
      -H "Origin: $MANAGER_URL" -H "Access-Control-Request-Method: GET" \
      -H "Access-Control-Request-Headers: apikey" | grep -qi 'access-control-allow-origin'; then
    ok "allow-origin present"
  else
    fail "no access-control-allow-origin — check CORS_ORIGIN"
  fi

  step "5. Manager health"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$MANAGER_URL/health" || true)"
  if [[ "$code" == "200" ]]; then ok "200"; else fail "expected 200, got ${code:-<no response>}"; fi

  step "6. Replica pinned to 1"
  local mn mx
  mn="$(az containerapp show -g "$RG" -n "$API_APP" --query properties.template.scale.minReplicas -o tsv || true)"
  mx="$(az containerapp show -g "$RG" -n "$API_APP" --query properties.template.scale.maxReplicas -o tsv || true)"
  if [[ "$mn" == "1" && "$mx" == "1" ]]; then ok "min=1 max=1"; else fail "min=${mn:-?} max=${mx:-?} — must be 1/1"; fi

  step "7. Both containers present"
  local names
  names="$(az containerapp show -g "$RG" -n "$API_APP" \
    --query 'properties.template.containers[].name' -o tsv 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [[ "$names" == *"evolution-api"* && "$names" == *"redis"* ]]; then
    ok "$names"
  else
    fail "unexpected containers: ${names:-<none>}"
  fi

  step "8. Secrets not stored as plaintext env values"
  if az containerapp show -g "$RG" -n "$API_APP" -o json \
      | jq -e '.properties.template.containers[]?.env[]?
               | select(.name=="AUTHENTICATION_API_KEY") | has("secretRef")' >/dev/null 2>&1; then
    ok "AUTHENTICATION_API_KEY uses secretRef"
  else
    fail "AUTHENTICATION_API_KEY is not a secretRef"
  fi

  printf '\n'
  if (( fails == 0 )); then
    ok "all checks passed"
    cmd_urls
  else
    warn "$fails check(s) failed — see EVOLUTION_ACA_DEPLOYMENT_GUIDE.md section 13"
    return 1
  fi
}

# ------------------------------------------------------------------ misc -----

cmd_urls() {
  load_env; api_facts; manager_facts
  printf '\n  Manager UI : %s\n' "$MANAGER_URL"
  printf '  API        : %s\n'   "$API_URL"
  printf '  API key    : %s\n\n' "$AUTHENTICATION_API_KEY"
  printf '  On the manager login screen, OVERWRITE the pre-filled Server URL\n'
  printf '  with the API URL above. The default is the manager'"'"'s own origin\n'
  printf '  and will not work on a split deployment.\n\n'
}

cmd_logs() {
  load_env
  az containerapp logs show -g "$RG" -n "$API_APP" --container evolution-api --tail 100 --follow
}

cmd_destroy() {
  load_env
  printf 'This deletes resource group %s and everything in it.\n' "$RG"
  read -r -p 'Type the resource group name to confirm: ' answer
  [[ "$answer" == "$RG" ]] || die "aborted"
  az group delete --name "$RG" --yes --no-wait
  ok "deletion started (running in background)"
  warn "remove the linked device manually in WhatsApp > Linked Devices"
}

cmd_all() {
  phase_1; phase_2; phase_3; phase_4; phase_5; phase_6
  printf '\n'; step "running verification"
  cmd_verify
}

# ------------------------------------------------------------------ main -----

case "${1:-}" in
  init)    cmd_init ;;
  1)       phase_1 ;;
  2)       phase_2 ;;
  3)       phase_3 ;;
  4)       phase_4 ;;
  5)       phase_5 ;;
  6)       phase_6 ;;
  all)     cmd_all ;;
  verify)  cmd_verify ;;
  urls)    cmd_urls ;;
  logs)    cmd_logs ;;
  destroy) cmd_destroy ;;
  *)
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
