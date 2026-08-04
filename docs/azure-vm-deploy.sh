#!/usr/bin/env bash
#
# Evolution API WhatsApp gateway -> single Azure VM (Southeast Asia, ARM64)
#
# Companion script to azure-vm-setup-guide.md. Read that first. This is the
# low-cost alternative to azure-deploy.sh (Container Apps): it runs the repo's
# docker-compose.yml unmodified on one VM, which costs ~1/5 as much and fixes
# the signal-key durability trap that the Container Apps design can only
# mitigate (guide section 13.1 there / section 5 here).
#
# Usage:
#   ./azure-vm-deploy.sh init      # write .env.vm + .secrets.vm, CHOOSE BACKUP
#   ./azure-vm-deploy.sh 1         # resource group, public IP + DNS label, NSG
#   ./azure-vm-deploy.sh 2         # create the VM (cloud-init brings the stack up)
#   ./azure-vm-deploy.sh 3         # wait for the stack, show container status
#   ./azure-vm-deploy.sh 4         # enable Azure Backup (no-op if declined at init)
#   ./azure-vm-deploy.sh all       # phases 1-4 in order
#   ./azure-vm-deploy.sh render    # render cloud-init only, no Azure calls
#   ./azure-vm-deploy.sh verify    # 11 smoke checks
#   ./azure-vm-deploy.sh urls      # print URLs + manager login instructions
#   ./azure-vm-deploy.sh logs      # tail the API container
#   ./azure-vm-deploy.sh ssh       # open a shell on the VM
#   ./azure-vm-deploy.sh destroy   # delete the whole resource group
#
# Every phase is idempotent: re-running it is safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env.vm"
SECRETS_FILE="${SCRIPT_DIR}/.secrets.vm"
CLOUDINIT_FILE="${SCRIPT_DIR}/cloud-init.rendered.yaml"

# ---------------------------------------------------------------- helpers ----

c_reset=$'\033[0m'; c_blue=$'\033[34m'; c_green=$'\033[32m'
c_yellow=$'\033[33m'; c_red=$'\033[31m'

step()  { printf '%s==>%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s  !%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s ERR%s %s\n' "$c_red"   "$c_reset" "$*" >&2; exit 1; }

need()   { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
exists() { "$@" >/dev/null 2>&1; }

# ------------------------------------------------------------------- init ----

cmd_init() {
  need az; need openssl; need curl

  if [[ -f "$ENV_FILE" ]]; then
    warn "$ENV_FILE already exists — leaving it alone"
  else
    local suffix admin_ip backup_choice dns_label
    suffix="$(openssl rand -hex 3)"

    # SSH is locked to one source address. Detected here so the NSG rule in
    # phase 1 is narrow by default rather than 0.0.0.0/0.
    #
    # Forced to IPv4 (-4) and tried against several endpoints: the public IP is
    # IPv4, so the NSG rule must carry an IPv4 source or it will never match.
    # On a dual-stack client an unforced curl returns the IPv6 address, and
    # api.ipify.org alone is not reliable — it is unreachable over IPv4 from
    # some networks.
    local svc
    admin_ip=""
    for svc in https://ifconfig.me/ip https://icanhazip.com \
               https://checkip.amazonaws.com https://api.ipify.org; do
      admin_ip="$(curl -4 -fsS --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$admin_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
      admin_ip=""
    done
    if [[ -z "$admin_ip" ]]; then
      warn "could not detect your public IPv4; SSH will be left closed"
      warn "set ADMIN_SOURCE_IP in $ENV_FILE and re-run phase 1 to open it"
      admin_ip="none"
    else
      ok "detected public IPv4 $admin_ip (SSH will be limited to it)"
    fi

    # ---- the one interactive decision: Azure Backup ----
    printf '\n%s─── Backup ───%s\n' "$c_blue" "$c_reset"
    printf '  Azure VM Backup costs $10.00/month (Protected Instance) plus a\n'
    printf '  few dollars of recovery-point storage.\n\n'
    printf '  Without it the monthly bill is  ~$39.40\n'
    printf '  With it the monthly bill is     ~$49.40\n\n'
    printf '  Note: VM Backup snapshots the whole disk while Postgres is\n'
    printf '  running, so restores are CRASH-CONSISTENT, not a clean dump.\n'
    printf '  Postgres replays WAL on restore. It is not equivalent to the\n'
    printf '  managed backups that PostgreSQL Flexible Server includes.\n\n'
    read -r -p '  Enable Azure Backup? [y/N] ' backup_choice
    if [[ "${backup_choice,,}" == "y" || "${backup_choice,,}" == "yes" ]]; then
      backup_choice="true"
    else
      backup_choice="false"
    fi
    printf '\n'

    dns_label="evolution-${suffix}"

    cat > "$ENV_FILE" <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). Safe to commit? NO.
export LOCATION="southeastasia"
export RG="evolution-vm-rg"
export SUFFIX="${suffix}"

# ---- VM ----
# B2pls_v2 is ARM64 (Ampere Altra), 2 vCPU / 4 GiB, \$30.95/mo.
# It is the ONLY burstable SKU available in southeastasia on this
# subscription: every x64 _v2 burstable reports NotAvailableForSubscription
# and the old-gen B1ms/B2s are absent from the region entirely. The cheapest
# deployable x64 box, D2als_v7, is \$73.73/mo. See guide section 2.
export VM_NAME="evolution-vm"
export VM_SIZE="Standard_B2pls_v2"
export VM_IMAGE="Canonical:ubuntu-24_04-lts:server-arm64:latest"
export VM_ADMIN_USER="azureuser"
export OS_DISK_GB="64"
export OS_DISK_SKU="StandardSSD_LRS"

# ---- Network ----
export PUBLIC_IP_NAME="evolution-ip"
export DNS_LABEL="${dns_label}"
export NSG_NAME="evolution-nsg"
export VNET_NAME="evolution-vnet"
export SUBNET_NAME="evolution-subnet"
# SSH source allowlist. "none" leaves port 22 closed.
export ADMIN_SOURCE_IP="${admin_ip}"

# ---- Backup (chosen at init) ----
export BACKUP_ENABLED="${backup_choice}"
export BACKUP_VAULT="evolution-vault-${suffix}"
export BACKUP_POLICY="DefaultPolicy"

# ---- Application ----
export APP_DIR="/opt/evolution"
export MANAGER_REPO="https://github.com/limcheekin/evolution-manager-v2.git"
export MANAGER_GIT_REF="main"
# build = compile the manager on the VM from the cloned repo (free).
# acr   = pull a prebuilt arm64 image (needs ACR_* below, costs \$5.07/mo).
export MANAGER_SOURCE="build"
export ACR_NAME=""
export ACR_IMAGE_TAG="v2-arm64"

export TZ_VALUE="Asia/Kuala_Lumpur"
# Optional: ACME registration address for Caddy. Empty is fine.
export ADMIN_EMAIL=""
EOF
    ok "wrote $ENV_FILE"
    [[ "$backup_choice" == "true" ]] && ok "backup: ENABLED (~\$49.40/mo)" \
                                     || ok "backup: disabled (~\$39.40/mo)"
  fi

  if [[ -f "$SECRETS_FILE" ]]; then
    warn "$SECRETS_FILE already exists — keeping existing secrets"
  else
    local pg_pw api_key
    # Alphanumeric only: these values are substituted into cloud-init with sed
    # in render_cloud_init, so a '/' or '&' would corrupt the replacement.
    pg_pw="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | cut -c1-24)Aa1"
    api_key="$(openssl rand -hex 32)"
    umask 077
    cat > "$SECRETS_FILE" <<EOF
export POSTGRES_PASSWORD='${pg_pw}'
export AUTHENTICATION_API_KEY='${api_key}'
EOF
    ok "wrote $SECRETS_FILE (mode 600)"
    warn "back this file up — these values are not recoverable from Azure"
  fi

  printf '\nNext: %s 1\n' "$0"
}

load_env() {
  [[ -f "$ENV_FILE" ]]     || die "$ENV_FILE not found — run: $0 init"
  [[ -f "$SECRETS_FILE" ]] || die "$SECRETS_FILE not found — run: $0 init"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  : "${LOCATION:?}" "${RG:?}" "${VM_NAME:?}" "${VM_SIZE:?}" "${DNS_LABEL:?}"
  : "${POSTGRES_PASSWORD:?}" "${AUTHENTICATION_API_KEY:?}"

  SITE_HOST="${DNS_LABEL}.${LOCATION}.cloudapp.azure.com"
  API_URL="https://${SITE_HOST}"
  MANAGER_URL="https://${SITE_HOST}:8443"
}

preflight() {
  need az; need jq; need curl; need ssh
  az account show >/dev/null 2>&1 || die "not logged in — run: az login"

  local ver
  ver="$(az version --query '"azure-cli"' -o tsv)"
  step "azure-cli $ver"

  # Providers the VM path needs. The Container Apps script registers a
  # different set; Microsoft.Compute being unregistered makes
  # `az vm list-usage` return an empty array, which looks exactly like zero
  # quota. Register first, diagnose second.
  local ns
  for ns in Microsoft.Compute Microsoft.Network; do
    if [[ "$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null)" != "Registered" ]]; then
      step "registering $ns"
      az provider register --namespace "$ns" --wait
    fi
  done
  if [[ "${BACKUP_ENABLED:-false}" == "true" ]] \
     && [[ "$(az provider show -n Microsoft.RecoveryServices --query registrationState -o tsv 2>/dev/null)" != "Registered" ]]; then
    step "registering Microsoft.RecoveryServices"
    az provider register --namespace Microsoft.RecoveryServices --wait
  fi
}

check_capacity() {
  # Unrestricted != allocatable. Both the family quota and the regional core
  # quota must have room, or `az vm create` fails late with QuotaExceeded.
  local fam_used fam_lim reg_used reg_lim usage
  usage="$(az vm list-usage -l "$LOCATION" -o json)"
  fam_used="$(jq -r '[.[]|select(.name.value=="standardBpsv2Family")|.currentValue]|first // "0"' <<<"$usage")"
  fam_lim="$(jq -r '[.[]|select(.name.value=="standardBpsv2Family")|.limit]|first // "0"' <<<"$usage")"
  reg_used="$(jq -r '[.[]|select(.name.value=="cores")|.currentValue]|first // "0"' <<<"$usage")"
  reg_lim="$(jq -r '[.[]|select(.name.value=="cores")|.limit]|first // "0"' <<<"$usage")"

  step "quota standardBpsv2Family ${fam_used}/${fam_lim}, regional cores ${reg_used}/${reg_lim}"
  (( fam_lim - fam_used >= 2 )) || die "no standardBpsv2Family headroom for 2 vCPUs — request a quota increase or use Standard_D2als_v7 (\$73.73/mo, x64)"
  (( reg_lim - reg_used >= 2 )) || die "no regional vCPU headroom for 2 vCPUs"
  ok "capacity available"

  # One call only: `az vm list-skus` fetches the whole regional SKU catalogue
  # and takes 1-5 minutes, so it is not something to invoke twice.
  local restr
  restr="$(az vm list-skus -l "$LOCATION" --size "$VM_SIZE" \
            --query "[0].restrictions[].reasonCode" -o tsv 2>/dev/null || true)"
  [[ -z "$restr" ]] || die "$VM_SIZE is restricted in $LOCATION: $restr"
}

# ------------------------------------------------- phase 1: network shell ----

phase_1() {
  load_env; preflight; check_capacity

  step "resource group $RG"
  if exists az group show -n "$RG"; then ok "exists"; else
    az group create -n "$RG" -l "$LOCATION" -o none && ok "created"
  fi

  step "public IP $PUBLIC_IP_NAME (dns: $DNS_LABEL)"
  if exists az network public-ip show -g "$RG" -n "$PUBLIC_IP_NAME"; then
    ok "exists"
  else
    # Standard SKU + static. Basic SKU public IPs are retired.
    # The DNS label is created BEFORE the VM so SERVER_URL is known at
    # cloud-init time — this removes the two-revision dance the Container
    # Apps design needs (its guide section 9).
    az network public-ip create \
      -g "$RG" -n "$PUBLIC_IP_NAME" \
      --sku Standard --allocation-method Static \
      --dns-name "$DNS_LABEL" --version IPv4 -o none
    ok "created"
  fi
  ok "hostname $SITE_HOST"

  step "network security group $NSG_NAME"
  if exists az network nsg show -g "$RG" -n "$NSG_NAME"; then ok "exists"; else
    az network nsg create -g "$RG" -n "$NSG_NAME" -o none && ok "created"
  fi

  # 80 is needed for the ACME HTTP-01 challenge as well as the redirect.
  # 8080 (API) and 3000 (manager) stay published on the VM by the base
  # compose file but are NOT opened here, so they are unreachable from the
  # internet: the NSG is enforced in the Azure fabric, ahead of the VM, so
  # Docker's iptables rules cannot bypass it. Everything public goes through
  # Caddy on 80/443/8443.
  nsg_rule allow-http    100 80   '*'
  nsg_rule allow-https   110 443  '*'
  nsg_rule allow-manager 120 8443 '*'
  if [[ "$ADMIN_SOURCE_IP" == "none" ]]; then
    warn "ADMIN_SOURCE_IP=none — port 22 left closed; set it in $ENV_FILE to use ssh"
  else
    nsg_rule allow-ssh 200 22 "$ADMIN_SOURCE_IP"
  fi

  step "vnet $VNET_NAME"
  if exists az network vnet show -g "$RG" -n "$VNET_NAME"; then ok "exists"; else
    az network vnet create -g "$RG" -n "$VNET_NAME" \
      --address-prefixes 10.20.0.0/16 \
      --subnet-name "$SUBNET_NAME" --subnet-prefixes 10.20.1.0/24 \
      --network-security-group "$NSG_NAME" -o none
    ok "created"
  fi
}

nsg_rule() {
  local name="$1" prio="$2" port="$3" src="$4"
  if exists az network nsg rule show -g "$RG" --nsg-name "$NSG_NAME" -n "$name"; then
    ok "rule $name exists"
  else
    az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" -n "$name" \
      --priority "$prio" --access Allow --protocol Tcp --direction Inbound \
      --source-address-prefixes "$src" --source-port-ranges '*' \
      --destination-address-prefixes '*' --destination-port-ranges "$port" -o none
    ok "rule $name (port $port from $src)"
  fi
}

# ------------------------------------------------------- phase 2: the VM ----

render_cloud_init() {
  # Written with a QUOTED heredoc so nothing expands here, then filled in with
  # sed. The substituted values are alphanumeric by construction (see
  # cmd_init), so they cannot contain sed metacharacters.
  # The override block for evolution-manager, indentation included: it is
  # spliced in as whole lines, so the replacement must carry the exact indent
  # the embedded compose file needs (service keys at 8, their children at 10).
  local manager_override="" acr_login=""
  if [[ "$MANAGER_SOURCE" == "acr" ]]; then
    [[ -n "$ACR_NAME" ]] || die "MANAGER_SOURCE=acr but ACR_NAME is empty"
    local acr_server acr_user acr_pw
    acr_server="$(az acr show -n "$ACR_NAME" --query loginServer -o tsv)"
    acr_user="$(az acr credential show -n "$ACR_NAME" --query username -o tsv)"
    acr_pw="$(az acr credential show -n "$ACR_NAME" --query 'passwords[0].value' -o tsv)"
    # Override `build:` with a prebuilt arm64 image. Must be an arm64 build:
    # the amd64 manager image will not run on B2pls_v2.
    manager_override=$'        evolution-manager:\n          image: '"${acr_server}/evolution-manager:${ACR_IMAGE_TAG}"$'\n          pull_policy: always'
    acr_login="docker login ${acr_server} -u '${acr_user}' -p '${acr_pw}'"
  fi
  # In build mode the base compose file's own `build: .` is what we want, so
  # the override contributes no evolution-manager block at all.

  cat > "$CLOUDINIT_FILE" <<'CLOUDINIT'
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
  - git
  - jq

write_files:
  # Vite/tsc peak memory can exceed what 4 GiB leaves free once Postgres and
  # Redis are up. Swap makes the on-VM manager build survive; it is cheap
  # insurance on a $4.80 disk.
  - path: /etc/systemd/system/evolution-swap.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Create and enable a 2G swapfile
      ConditionPathExists=!/swapfile
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/bash -c 'fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo "/swapfile none swap sw 0 0" >> /etc/fstab'
      [Install]
      WantedBy=multi-user.target

  - path: @@APP_DIR@@/Caddyfile
    permissions: '0644'
    content: |
@@CADDY_GLOBAL@@
      # Evolution API at the root of the host. SERVER_URL points here, so
      # webhook payloads and any Chatwoot/Meta callbacks carry a URL that
      # actually resolves.
      @@SITE_HOST@@ {
        encode gzip
        reverse_proxy evolution-api:8080 {
          # Baileys keeps a long-lived upstream socket; do not let Caddy time
          # out an in-flight QR fetch or instance create.
          transport http {
            read_timeout 300s
            write_timeout 300s
          }
        }
      }

      # Evolution Manager on a second port. One public IP means one DNS label,
      # and serving the SPA under a path prefix would break its asset paths,
      # so the admin console gets :8443 instead. Caddy reuses the same
      # certificate for both.
      @@SITE_HOST@@:8443 {
        encode gzip
        reverse_proxy evolution-manager:80
      }

  - path: @@APP_DIR@@/docker-compose.prod.yml
    permissions: '0644'
    content: |
      # Production overlay for the repo's docker-compose.yml.
      #
      # docker compose merges `environment` per key with the override winning,
      # so this file only needs to add what the base file omits. The base file
      # is a development compose file and sets NONE of the variables below;
      # every one of them is load-bearing. Cross-references are to the
      # Container Apps guide (docs/azure-setup-guide.md) section 13, whose
      # traps are properties of the evolution-api image and therefore apply
      # here identically.
      services:
        evolution-api:
          environment:
            # 13.5 - gates useMultiFileAuthStatePrisma in defineAuthState().
            # The code default is false, and with Redis-save also off the
            # function returns undefined and instances cannot persist
            # credentials at all. The baked .env.example says true; do not
            # rely on which one wins.
            - DATABASE_SAVE_DATA_INSTANCE=true
            # 13.1 - credentials to Postgres. Signal keys still follow
            # CACHE_REDIS_ENABLED (true, from the base file) and live in
            # Redis, which is why Redis gets a named volume and AOF below.
            - CACHE_REDIS_SAVE_INSTANCES=false
            # 13.4 - an explicit allowlist returns HTTP 500 for every request
            # with no Origin header, because ORIGIN.indexOf(undefined) is -1.
            # That breaks curl, server-to-server callers, and health probes.
            - CORS_ORIGIN=*
            # 13.7 - telemetry is opt-OUT; it posts every request path to
            # log.evolution-api.com unless this is the literal string false.
            - TELEMETRY_ENABLED=false
            # 13.8 - image defaults: TZ=America/Sao_Paulo, LOG_COLOR=true.
            - LOG_COLOR=false
            - LOG_LEVEL=ERROR,WARN,INFO
            - TZ=@@TZ_VALUE@@
            - SERVER_TYPE=http
            # Known up front here, unlike on Container Apps, because the DNS
            # label exists before the VM does.
            - SERVER_URL=https://@@SITE_HOST@@
            - DATABASE_CONNECTION_CLIENT_NAME=evolution_azure_vm
            # 13.6 - PROVIDER_ENABLED is deliberately absent. It is a client
            # for a separate remote microservice, not local file storage, and
            # if enabled without that service the app self-terminates with
            # kill -9 in onModuleInit().
          depends_on:
            - postgres
            - redis

        # THE REASON THIS ARCHITECTURE EXISTS.
        #
        # On Container Apps, Redis is an ephemeral sidecar with persistence
        # switched off, so Baileys signal keys - per-contact Signal sessions,
        # pre-keys, app-state-sync-key, sender-keys - are destroyed by any
        # revision update or restart. The session still authenticates from
        # Postgres, so the API reports state: open and the phone still shows
        # the device linked, while inbound messages silently fail to decrypt.
        # Here the keys are on a named volume with AOF enabled and survive
        # reboots.
        #
        # maxmemory-policy is noeviction, not volatile-lru: it is not
        # established that Baileys writes signal keys with a TTL, and
        # volatile-lru would evict them under pressure. Failing writes loudly
        # is better than losing keys quietly.
        redis:
          command:
            - redis-server
            - --appendonly
            - "yes"
            - --appendfsync
            - everysec
            - --save
            - "900"
            - "1"
            - --maxmemory
            - 512mb
            - --maxmemory-policy
            - noeviction
          volumes:
            - redis_data:/data

@@MANAGER_OVERRIDE@@
        caddy:
          image: caddy:2-alpine
          container_name: evolution-caddy
          restart: unless-stopped
          ports:
            - "80:80"
            - "443:443"
            - "8443:8443"
          volumes:
            - ./Caddyfile:/etc/caddy/Caddyfile:ro
            - caddy_data:/data
            - caddy_config:/config
          networks:
            - evolution-network
          depends_on:
            - evolution-api
            - evolution-manager

      volumes:
        redis_data:
        caddy_data:
        caddy_config:

  - path: /usr/local/bin/evolution-up
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      # Bring the stack up. Safe to re-run; used by cloud-init and by hand.
      set -euo pipefail
      cd @@APP_DIR@@
      exec docker compose -f docker-compose.yml -f docker-compose.prod.yml "${@:-up -d}"

runcmd:
  - systemctl enable --now evolution-swap.service
  - systemctl enable --now docker
  - git clone --depth 1 --branch @@GIT_REF@@ @@REPO_URL@@ /tmp/evolution-src
  - cp -r /tmp/evolution-src/. @@APP_DIR@@/
  - rm -rf /tmp/evolution-src
  # The base compose file reads both of these with the ${VAR:?} form and will
  # refuse to start if either is missing.
  - install -m 600 /dev/null @@APP_DIR@@/.env
  - printf 'POSTGRES_PASSWORD=%s\nAUTHENTICATION_API_KEY=%s\n' '@@PG_PASSWORD@@' '@@API_KEY@@' > @@APP_DIR@@/.env
  - @@ACR_LOGIN@@
  - cd @@APP_DIR@@ && docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
  - touch /var/lib/cloud/evolution-stack-started
CLOUDINIT

  # mkdir for APP_DIR has to happen before write_files, which cloud-init does
  # not guarantee, so create it up front via a bootcmd inserted here.
  sed -i "1a bootcmd:\n  - mkdir -p ${APP_DIR}" "$CLOUDINIT_FILE"

  # Caddy's global options block exists only to carry the ACME contact address.
  # An empty `email` directive is a hard config error ("wrong argument count"),
  # which crash-loops Caddy and leaves the whole site without TLS, so when no
  # address is configured the block is omitted entirely rather than emitted
  # empty. ACME still works without a contact address.
  local caddy_global=""
  if [[ -n "${ADMIN_EMAIL// /}" ]]; then
    caddy_global=$'      {\n        email '"${ADMIN_EMAIL}"$'\n      }\n'
  fi
  awk -v repl="$caddy_global" \
    '{ if ($0 ~ /@@CADDY_GLOBAL@@/) { if (repl != "") print repl } else print }' \
    "$CLOUDINIT_FILE" > "${CLOUDINIT_FILE}.tmp" && mv "${CLOUDINIT_FILE}.tmp" "$CLOUDINIT_FILE"

  sed -i \
    -e "s|@@APP_DIR@@|${APP_DIR}|g" \
    -e "s|@@SITE_HOST@@|${SITE_HOST}|g" \
    -e "s|@@TZ_VALUE@@|${TZ_VALUE}|g" \
    -e "s|@@REPO_URL@@|${MANAGER_REPO}|g" \
    -e "s|@@GIT_REF@@|${MANAGER_GIT_REF}|g" \
    -e "s|@@PG_PASSWORD@@|${POSTGRES_PASSWORD}|g" \
    -e "s|@@API_KEY@@|${AUTHENTICATION_API_KEY}|g" \
    "$CLOUDINIT_FILE"

  # The docker-login step only exists in ACR mode. Substituting a no-op like
  # `true` here would be a bare YAML boolean, and cloud-init's shellify() raises
  # TypeError on a non-string runcmd entry — which aborts the ENTIRE runcmd
  # module, not just that line. Delete the line instead.
  if [[ -n "$acr_login" ]]; then
    sed -i "s|@@ACR_LOGIN@@|${acr_login}|g" "$CLOUDINIT_FILE"
  else
    sed -i '/@@ACR_LOGIN@@/d' "$CLOUDINIT_FILE"
  fi

  # Guard against the same class of bug returning: any runcmd/bootcmd entry that
  # YAML would type as a boolean or null rather than a string.
  if grep -nE '^[[:space:]]*-[[:space:]]*(true|false|True|False|TRUE|FALSE|yes|no|on|off|null|~)[[:space:]]*$' "$CLOUDINIT_FILE"; then
    die "rendered cloud-init contains a bare YAML boolean/null list item (shown above); cloud-init would fail to shellify runcmd"
  fi

  # The manager override is multi-line and indentation-sensitive, so it is
  # spliced in with awk (sed would mangle the embedded newlines). An empty
  # replacement drops the placeholder line entirely rather than leaving a
  # stray blank inside the block scalar.
  awk -v repl="$manager_override" \
    '{ if ($0 ~ /@@MANAGER_OVERRIDE@@/) { if (repl != "") print repl } else print }' \
    "$CLOUDINIT_FILE" > "${CLOUDINIT_FILE}.tmp" && mv "${CLOUDINIT_FILE}.tmp" "$CLOUDINIT_FILE"

  chmod 600 "$CLOUDINIT_FILE"
}

phase_2() {
  load_env; preflight

  step "rendering cloud-init"
  render_cloud_init
  ok "wrote $CLOUDINIT_FILE (mode 600 — contains both secrets)"

  step "virtual machine $VM_NAME ($VM_SIZE, ARM64)"
  if exists az vm show -g "$RG" -n "$VM_NAME"; then
    warn "exists — not recreating. To re-apply the stack config: $0 ssh, then evolution-up"
  else
    az vm create \
      --resource-group "$RG" \
      --name "$VM_NAME" \
      --location "$LOCATION" \
      --size "$VM_SIZE" \
      --image "$VM_IMAGE" \
      --admin-username "$VM_ADMIN_USER" \
      --generate-ssh-keys \
      --os-disk-size-gb "$OS_DISK_GB" \
      --storage-sku "$OS_DISK_SKU" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME" \
      --public-ip-address "$PUBLIC_IP_NAME" \
      `# "" means "no NIC-level NSG" (documented for --nsg). The NSG is on the` \
      `# subnet instead. A NIC-level NSG would override it and, with its` \
      `# SSH-only defaults, would block Caddy on 80/443/8443. Note: under` \
      `# PowerShell this argument needs '""' rather than "".` \
      --nsg "" \
      --custom-data "$CLOUDINIT_FILE" \
      --output none
    ok "created"
  fi

  local ip
  ip="$(az network public-ip show -g "$RG" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv)"
  ok "public IP $ip -> $SITE_HOST"
  warn "cloud-init installs Docker, clones the repo and builds the manager;"
  warn "first boot takes 5-12 minutes on 2 ARM vCPUs. Run '$0 3' to wait."
}

# --------------------------------------------------- phase 3: wait + show ----

phase_3() {
  load_env; preflight

  step "waiting for cloud-init to finish (up to 15 min)"
  local i done_marker=""
  for i in $(seq 1 90); do
    done_marker="$(vm_run "test -f /var/lib/cloud/evolution-stack-started && echo READY || true" 2>/dev/null | grep -o READY || true)"
    [[ "$done_marker" == "READY" ]] && break
    sleep 10
  done
  [[ "$done_marker" == "READY" ]] || warn "marker not present yet — checking containers anyway"

  step "container status"
  vm_run "cd ${APP_DIR} && docker compose -f docker-compose.yml -f docker-compose.prod.yml ps --format '{{.Service}} {{.State}} {{.Status}}'" || true

  step "waiting for TLS certificate + API (up to 5 min)"
  for i in $(seq 1 30); do
    if curl -fsS --max-time 8 "$API_URL" >/dev/null 2>&1; then ok "API answering on $API_URL"; return 0; fi
    sleep 10
  done
  warn "API not answering yet. Check: $0 logs"
}

vm_run() {
  # Run a command on the VM. Uses `az vm run-command`, so it works even when
  # port 22 is closed by the NSG.
  #
  # The message comes back as a single field wrapping the script's output in
  # [stdout]/[stderr] delimiters. If that framing ever changes, the extraction
  # below yields nothing — and callers (phase 3's readiness loop, verify checks
  # 2 and 9) would then report a healthy VM as broken. So fall back to the raw
  # message rather than returning empty: a parsing problem should look like a
  # parsing problem, not a deployment failure.
  local raw extracted
  raw="$(az vm run-command invoke -g "$RG" -n "$VM_NAME" \
          --command-id RunShellScript --scripts "$1" \
          --query 'value[0].message' -o tsv 2>/dev/null || true)"
  extracted="$(sed -n '/\[stdout\]/,/\[stderr\]/p' <<<"$raw" | sed '1d;$d')"
  if [[ -n "${extracted//[[:space:]]/}" ]]; then
    printf '%s\n' "$extracted"
  else
    printf '%s\n' "$raw"
  fi
}

# ------------------------------------------------------- phase 4: backup ----

phase_4() {
  load_env; preflight

  if [[ "$BACKUP_ENABLED" != "true" ]]; then
    warn "backup declined at init (BACKUP_ENABLED=false) — skipping"
    warn "to enable later: set BACKUP_ENABLED=true in $ENV_FILE and re-run '$0 4'"
    printf '\n  Free alternative, no Recovery Services vault:\n'
    printf '    %s ssh\n' "$0"
    printf '    # then add a nightly logical dump to the OS disk:\n'
    printf "    echo '0 3 * * * cd %s && docker compose exec -T postgres pg_dump -U postgres evolution | gzip > /var/backups/evolution-\$(date +%%F).sql.gz' | sudo crontab -\n\n" "$APP_DIR"
    return 0
  fi

  step "recovery services vault $BACKUP_VAULT"
  if exists az backup vault show -g "$RG" -n "$BACKUP_VAULT"; then ok "exists"; else
    az backup vault create -g "$RG" -n "$BACKUP_VAULT" -l "$LOCATION" -o none && ok "created"
  fi

  step "enabling protection for $VM_NAME"
  if az backup item list -g "$RG" --vault-name "$BACKUP_VAULT" \
       --query "[?properties.friendlyName=='${VM_NAME}']" -o tsv 2>/dev/null | grep -q .; then
    ok "already protected"
  else
    az backup protection enable-for-vm \
      -g "$RG" --vault-name "$BACKUP_VAULT" \
      --vm "$VM_NAME" --policy-name "$BACKUP_POLICY" -o none
    ok "protected with $BACKUP_POLICY"
  fi
  warn "disk-level snapshots are crash-consistent; Postgres replays WAL on restore"
}

# ----------------------------------------------------------------- verify ----

cmd_verify() {
  load_env; preflight
  local fails=0
  # Same discipline as azure-deploy.sh: assignment not ((fails++)), which
  # would exit 1 on the first increment under `set -e`, and `|| true` on every
  # capture so one dead check cannot hide the other nine.
  fail() { warn "$*"; fails=$((fails + 1)); }
  local code

  step "1. VM running"
  local power
  power="$(az vm get-instance-view -g "$RG" -n "$VM_NAME" \
            --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv 2>/dev/null || true)"
  [[ "$power" == "VM running" ]] && ok "$power" || fail "power state: ${power:-unknown}"

  step "2. all five containers up"
  local ps_out
  ps_out="$(vm_run "cd ${APP_DIR} && docker compose -f docker-compose.yml -f docker-compose.prod.yml ps --format '{{.Service}}={{.State}}'" 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
  local svc missing=""
  for svc in evolution-api evolution-manager postgres redis caddy; do
    grep -q "${svc}=running" <<<"$ps_out" || missing="$missing $svc"
  done
  [[ -z "$missing" ]] && ok "api, manager, postgres, redis, caddy" || fail "not running:$missing (got: ${ps_out:-none})"

  step "3. API root over TLS"
  local ver
  ver="$(curl -fsS --max-time 20 "$API_URL" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
  [[ -n "$ver" ]] && ok "version $ver" || fail "no JSON from $API_URL (TLS still issuing, or migrations running)"

  step "4. API key enforced"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$API_URL/instance/fetchInstances" || true)"
  [[ "$code" == "401" ]] && ok "401 without key" || fail "expected 401, got ${code:-<no response>}"

  step "5. API key accepted"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "apikey: $AUTHENTICATION_API_KEY" "$API_URL/instance/fetchInstances" || true)"
  [[ "$code" == "200" ]] && ok "200 with key" || fail "expected 200, got ${code:-<no response>}"

  step "6. CORS preflight from manager origin"
  if curl -s -I --max-time 15 -X OPTIONS "$API_URL/instance/fetchInstances" \
      -H "Origin: $MANAGER_URL" -H "Access-Control-Request-Method: GET" \
      -H "Access-Control-Request-Headers: apikey" 2>/dev/null | grep -qi 'access-control-allow-origin'; then
    ok "allow-origin present"
  else
    fail "no access-control-allow-origin — CORS_ORIGIN must stay '*'"
  fi

  step "7. Manager reachable on :8443"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$MANAGER_URL/health" || true)"
  [[ "$code" == "200" ]] && ok "200" || fail "expected 200, got ${code:-<no response>}"

  step "8. SERVER_URL resolves to this host"
  local mgr
  mgr="$(curl -fsS --max-time 20 "$API_URL" 2>/dev/null | jq -r '.manager // empty' 2>/dev/null || true)"
  grep -q "$SITE_HOST" <<<"${mgr:-}" && ok "$mgr" || fail "manager URL is '${mgr:-empty}', expected to contain $SITE_HOST"

  step "9. Redis persistence on (the section 13.1 fix)"
  local aof
  aof="$(vm_run "cd ${APP_DIR} && docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T redis redis-cli config get appendonly" 2>/dev/null | tr -d '\r' | tr '\n' ' ' || true)"
  grep -q 'yes' <<<"$aof" && ok "appendonly yes" || fail "AOF not enabled — signal keys are not durable (got: ${aof:-none})"

  step "10. database and cache not exposed to the internet"
  local open
  open="$(az network nsg rule list -g "$RG" --nsg-name "$NSG_NAME" \
           --query "[?access=='Allow'].destinationPortRange" -o tsv 2>/dev/null | tr '\n' ' ' || true)"
  if grep -qE '5432|6379|8080|3000|\*' <<<"$open"; then
    fail "NSG allows $open — 5432/6379/8080/3000 must not be open"
  else
    ok "only $open open"
  fi

  step "10b. no second NSG on the NIC"
  # The NSG is attached to the SUBNET; `az vm create --nsg ""` means "none"
  # (documented). If a NIC-level NSG ever appears anyway, its default rules
  # allow SSH only, so Caddy's 80/443/8443 would be blocked at the NIC while
  # check 10 above still passes — checks 3 through 7 would fail with no
  # indication of why. Assert it directly.
  # Resolved by name rather than with --ids: under Git Bash / MSYS, an argument
  # beginning with '/' is rewritten into a Windows path, so
  # `--ids /subscriptions/...` arrives as `C:/Program Files/Git/subscriptions/...`
  # and az rejects it as an invalid resource ID.
  local nic_id nic_name nic_nsg
  nic_id="$(az vm show -g "$RG" -n "$VM_NAME" \
             --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>/dev/null || true)"
  nic_name="${nic_id##*/}"
  if [[ -z "$nic_name" ]]; then
    fail "could not resolve the VM's NIC"
  else
    nic_nsg="$(az network nic show -g "$RG" -n "$nic_name" \
                --query 'networkSecurityGroup.id' -o tsv 2>/dev/null || true)"
    [[ -z "$nic_nsg" || "$nic_nsg" == "None" ]] \
      && ok "NIC $nic_name has no NSG; subnet NSG governs" \
      || fail "a NIC-level NSG exists (${nic_nsg##*/}) and will override the subnet rules"
  fi

  step "11. backup"
  if [[ "$BACKUP_ENABLED" == "true" ]]; then
    if az backup item list -g "$RG" --vault-name "$BACKUP_VAULT" \
         --query "[?properties.friendlyName=='${VM_NAME}'].properties.protectionState" -o tsv 2>/dev/null | grep -qi 'protected'; then
      ok "protected in $BACKUP_VAULT"
    else
      fail "BACKUP_ENABLED=true but the VM is not protected — run '$0 4'"
    fi
  else
    ok "disabled by choice at init (~\$39.40/mo)"
  fi

  printf '\n'
  if (( fails == 0 )); then
    ok "all checks passed"
    cmd_urls
  else
    warn "$fails check(s) failed"
    return 1
  fi
}

# ------------------------------------------------------------------ misc -----

cmd_urls() {
  load_env
  local ip
  ip="$(az network public-ip show -g "$RG" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv 2>/dev/null || echo '?')"
  printf '\n  API        : %s\n'   "$API_URL"
  printf '  Manager UI : %s\n'     "$MANAGER_URL"
  printf '  Public IP  : %s\n'     "$ip"
  printf '  API key    : %s\n\n'   "$AUTHENTICATION_API_KEY"
  printf '  On the manager login screen, OVERWRITE the pre-filled Server URL\n'
  printf '  with the API URL above. The SPA defaults that field to its own\n'
  printf '  origin, which is the :8443 manager, not the API. The value lives in\n'
  printf '  localStorage under the key apiUrl; it is per-browser-profile and is\n'
  printf '  lost on logout or on clearing site data. No env var or build arg\n'
  printf '  can preconfigure it.\n\n'
  printf '  Live chat updates will not work: WEBSOCKET_ENABLED is false by\n'
  printf '  default and turning it on for the manager would also require\n'
  printf '  WEBSOCKET_ALLOWED_HOSTS=*, which disables websocket auth entirely.\n'
  printf '  Instance CRUD and QR display go over REST and work fine.\n\n'
}

cmd_logs() {
  load_env
  vm_run "cd ${APP_DIR} && docker compose -f docker-compose.yml -f docker-compose.prod.yml logs --tail 120 evolution-api caddy"
}

cmd_ssh() {
  load_env
  [[ "$ADMIN_SOURCE_IP" != "none" ]] || die "port 22 is closed; set ADMIN_SOURCE_IP in $ENV_FILE and re-run '$0 1'"
  local ip
  ip="$(az network public-ip show -g "$RG" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv)"
  exec ssh "${VM_ADMIN_USER}@${ip}"
}

cmd_qr() {
  # Phase 8 equivalent: create an instance and write the QR to a PNG.
  load_env
  local name="${2:-primary}" out="${SCRIPT_DIR}/qr.png"
  step "creating instance '$name' (ignored if it already exists)"
  curl -s -X POST "$API_URL/instance/create" \
    -H "apikey: $AUTHENTICATION_API_KEY" -H 'Content-Type: application/json' \
    -d "{\"instanceName\":\"${name}\",\"integration\":\"WHATSAPP-BAILEYS\",\"qrcode\":true}" \
    | jq -r '.instance.instanceName // .response.message // .message // "already exists"'

  step "fetching QR"
  curl -fsS "$API_URL/instance/connect/${name}" -H "apikey: $AUTHENTICATION_API_KEY" \
    | jq -r '.base64 // empty' | sed 's|^data:image/png;base64,||' | base64 -d > "$out"
  [[ -s "$out" ]] || die "no QR returned — the instance may already be connected"
  ok "wrote $out"
  warn "QR codes expire in well under a minute — re-run '$0 qr' if the scan fails"
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
  phase_1; phase_2; phase_3; phase_4
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
  all)     cmd_all ;;
  render)  load_env; render_cloud_init; ok "rendered $CLOUDINIT_FILE (no Azure calls made)" ;;
  verify)  cmd_verify ;;
  urls)    cmd_urls ;;
  logs)    cmd_logs ;;
  ssh)     cmd_ssh ;;
  qr)      cmd_qr "$@" ;;
  destroy) cmd_destroy ;;
  *)
    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac
