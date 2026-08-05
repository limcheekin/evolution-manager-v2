# Evolution API WhatsApp Gateway → single Azure VM (ARM64)

**Low-cost alternative to `azure-setup-guide.md`.** Runs this repo's `docker-compose.yml` on one Azure VM in Southeast Asia for **~$39/month** — about a fifth of the Container Apps design — and resolves the signal-key durability trap that design can only mitigate.

Implemented by `azure-vm-deploy.sh`. Read this first; §5 lists the traps that carry over unchanged from the Container Apps guide, because they are properties of the `evolution-api` image, not of the platform.

---

## 1. What this deploys

| Compose service | Becomes | Notes |
|---|---|---|
| `evolution-api` | container on the VM | unchanged from `docker-compose.yml` |
| `redis` | container on the VM, **named volume + AOF** | see §4 — this is the point |
| `postgres` | container on the VM, named volume | no managed Postgres; saves $23.40/mo |
| `evolution-manager` | container, built on the VM from the repo | no registry needed; saves $5.07/mo |
| — | **`caddy`** added | TLS termination, the one thing ACA gave for free |

Nothing about the compose file is rewritten. `docker-compose.prod.yml`, generated into the VM by cloud-init, is a pure overlay: it adds the environment variables the base file omits, gives Redis durability, and puts Caddy in front.

### Topology

```
Internet
   │
   ├─ :443  ──► caddy ──► evolution-api:8080      https://evolution-<sfx>.southeastasia.cloudapp.azure.com
   ├─ :8443 ──► caddy ──► evolution-manager:80    https://evolution-<sfx>.southeastasia.cloudapp.azure.com:8443
   └─ :80   ──► caddy (ACME HTTP-01 + redirect)
                  │
   Standard_B2pls_v2 (ARM64, 2 vCPU / 4 GiB), 64 GiB StandardSSD
   ├── evolution-api      ──► postgres:5432   (container, volume postgres_data)
   │                      ──► redis:6379      (container, volume redis_data, AOF on)
   └── evolution-manager  (nginx SPA)

   NSG allows 80, 443, 8443 from anywhere and 22 from your IP only.
   Ports 8080 and 3000 stay published on the VM by the base compose file but
   are NOT opened in the NSG, so they are unreachable from the internet.
```

Two ports rather than two hostnames because one public IP gets one Azure DNS label, and serving the SPA under a path prefix would break its asset paths. Caddy reuses the same certificate for both.

---

## 2. Why ARM64 — this is forced, not a preference

`Standard_B2pls_v2` is ARM64 (Ampere Altra). That is not an optimisation; it is the only burstable SKU that can be deployed:

```bash
az vm list-skus -l southeastasia --resource-type virtualMachines -o json \
| jq -r '.[] | select(.name|test("^Standard_B2")) | "\(.name)\t\(if (.restrictions|length)==0 then "AVAILABLE" else "RESTRICTED" end)"'
```

Every x64 `_v2` burstable reports `NotAvailableForSubscription`, and the older `B1ms` / `B2s` are absent from the region list entirely. Only the `p` (ARM) variants come back `AVAILABLE`. The cheapest deployable **x64** box is `Standard_D2als_v7` at **$73.73/mo**, which is worse than the Container Apps floor and defeats the purpose.

ARM64 is fine here, but it constrains images:

- `evoapicloud/evolution-api:v2.3.7` publishes `linux/amd64` **and** `linux/arm64` — verified against the Docker Hub manifest list.
- `postgres:15-alpine`, `redis:7-alpine`, `caddy:2-alpine` are all multi-arch.
- **The manager image is not.** It is built from this repo. Building it on the VM (the default) is native and correct. If you instead pull from ACR, you must build with `az acr build --platform linux/arm64` — an amd64 manager image will not run. Expect that build to take ~7 minutes under QEMU emulation versus ~100 seconds native.

`az vm list-usage` returning an empty array means `Microsoft.Compute` is unregistered, **not** that quota is zero. The script registers it before reading quota.

---

## 3. Cost

Southeast Asia retail rates, verified against both the Azure Retail Prices API and the pricing calculator's own JSON feed.

| Component | Monthly |
|---|---|
| `Standard_B2pls_v2`, 730 hr @ $0.0424/hr | $30.95 |
| 64 GiB Standard SSD (E6 LRS) | $4.80 |
| Standard static IPv4 @ $0.005/hr | $3.65 |
| VNet / NIC / NSG | $0.00 |
| **Total, backup declined** | **$39.40** |
| Azure VM Backup (Protected Instance) | +$10.00 |
| **Total, backup enabled** | **$49.40** |

`azure-vm-deploy.sh init` asks which you want and records it in `.env.vm`, so re-running a phase never re-prompts.

Egress is free to 100 GB/month, then $0.06–$0.11/GB. A gateway relaying WhatsApp media could plausibly reach that; it is the one line item above that is not fixed.

A 1-year reservation on the VM brings the compute to $18.25/mo ($219 upfront), i.e. **$26.70/mo** all-in. Only worth it once the deployment is proven.

For reference: Container Apps as specced is **$189.46/mo**, and its cheapest credible configuration is **$71.33/mo**.

### What backup does and does not give you

Azure VM Backup snapshots the whole disk while Postgres is running, so recovery points are **crash-consistent, not a clean logical dump**. Postgres replays WAL on restore and normally comes up fine, but this is not equivalent to PostgreSQL Flexible Server's managed backups. If you decline it, the script prints a free alternative — a nightly `pg_dump` cron to the OS disk, which is a *better* database backup than a disk snapshot, just with no off-box copy.

---

## 4. What this architecture fixes

The Container Apps guide's §13.1 is unavoidable there and gone here.

There, Redis is an ephemeral sidecar with persistence switched off. Baileys **signal keys** — per-contact Signal sessions, pre-keys, `app-state-sync-key`, sender-keys — follow `CACHE_REDIS_ENABLED` and live in that sidecar. Any revision update, image change, platform restart, or Redis OOM destroys them. The session still authenticates from Postgres, so the API reports `state: open` and the phone still shows the device linked, while inbound messages silently fail to decrypt. It reads as a WhatsApp problem.

Here, Redis gets a named volume and AOF:

```yaml
redis:
  command: [redis-server, --appendonly, "yes", --appendfsync, always,
            --save, "900", "1", --maxmemory, 512mb, --maxmemory-policy, noeviction]
  volumes: [redis_data:/data]
```

`appendfsync always`, not the conventional `everysec`. With `everysec`, up to one second of writes can be lost when Redis stops — and here those writes are Signal sessions. Losing one produces `No session found to decrypt message` for the next inbound message from that contact, which cannot be recovered without the sender re-sending. That was observed in practice (§13). A gateway writes a handful of small keys per message, so fsyncing every write costs nothing measurable and makes the guarantee exact rather than "within one second".

`noeviction`, not `volatile-lru`: it is not established that Baileys writes signal keys with a TTL, and `volatile-lru` would evict them under memory pressure. Failing writes loudly beats losing keys quietly.

**Measured, not assumed:** a linked instance survived a full VM restart with all 848 signal-key fields intact and `state: open` — no re-scan needed. Three group messages did fail with `No session found` in the ten minutes afterwards, which is why `appendfsync` is now `always`. Both results in §13.

The Container Apps guide's §13.2 — never scale past one replica, never scale to zero — is structurally satisfied: one container, no scaler, no HTTP-triggered wake-up to get wrong.

---

## 5. Traps that carry over unchanged

These are properties of the `evolution-api` image. The repo's `docker-compose.yml` is a development file and sets **none** of them, which is what `docker-compose.prod.yml` exists to correct. Section numbers refer to `azure-setup-guide.md`.

| § | Trap | Handled by |
|---|---|---|
| 13.3 | Image does `COPY ./.env.example ./.env`, so anything you omit falls back to a **publicly known** value — `AUTHENTICATION_API_KEY` defaults to `429683C4C977415CAAFCCE10F7D57E11` | base compose sets it; `init` generates 32 random bytes |
| 13.4 | An explicit `CORS_ORIGIN` allowlist returns **HTTP 500 for every request with no `Origin` header**, because `ORIGIN.indexOf(undefined)` is `-1`. Breaks curl, server-to-server callers, health checks | `CORS_ORIGIN=*` |
| 13.5 | `DATABASE_SAVE_DATA_INSTANCE` gates `useMultiFileAuthStatePrisma`. Code default is `false`; false + Redis-save off means `defineAuthState()` returns `undefined` and credentials cannot persist at all | set `true` explicitly |
| 13.6 | `PROVIDER_ENABLED` is a client for a **separate remote microservice**, not local storage. Enabled without it, `onModuleInit()` self-terminates with `kill -9` | left unset, deliberately |
| 13.7 | Telemetry is opt-**out**; posts every request path to `log.evolution-api.com` | `TELEMETRY_ENABLED=false` |
| 13.8 | `TZ` defaults to `America/Sao_Paulo`; `LOG_COLOR=true` pollutes logs; the Prisma schema reads `DATABASE_CONNECTION_URI`, **not** `DATABASE_URL` | `TZ`, `LOG_COLOR=false`, only the correct variable set |

Two more inherited behaviours:

- **No `/health` endpoint exists.** `GET /` works without a key but calls `fetchLatestWaWebVersion()`, an **untimed** `axios.get` to `web.whatsapp.com`. If it hangs rather than returning, egress is blocked — the app is fine. Caddy's upstream timeouts are set to 300s so a slow `GET /` cannot be cut off mid-request.
- **Migrations run at startup.** The entrypoint is `deploy_database.sh && npm run start:prod`, so `prisma migrate deploy` must succeed before Node starts. No separate migration step is needed, and a migration failure is correctly a startup failure.

`SERVER_URL` is knowable up front here, unlike on Container Apps: the DNS label is created in phase 1, before the VM exists. The two-revision dance of that guide's §9 disappears.

**`SERVER_TYPE` must stay `http`, and the `manager` field will read `http://`.** Confirmed on a live deployment: `GET /` returns `"manager": "http://<host>/manager"` even though `SERVER_URL` is `https://<host>` inside the container. That field is built from `SERVER_TYPE` plus the `Host` header, not from `SERVER_URL`. Do not "fix" it by setting `SERVER_TYPE=https` — that makes the app terminate TLS itself and expect certificate files, which breaks the Caddy setup. Webhook payloads and Chatwoot/Meta callbacks use `SERVER_URL` and correctly carry `https://`. The discrepancy is cosmetic. (Note that the Container Apps guide's §7.4 sample output shows `https://` for this field; expect `http://` behind any TLS-terminating proxy.)

---

## 6. Prerequisites

```bash
az version          # 2.80.0+
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

Local tools: `bash`, `az`, `jq`, `curl`, `openssl`, `ssh`. The script registers `Microsoft.Compute`, `Microsoft.Network`, and — only if you enable backup — `Microsoft.RecoveryServices`.

---

## 7. Deploy

```bash
bash docs/azure-vm-deploy.sh init     # writes .env.vm + .secrets.vm, ASKS ABOUT BACKUP
bash docs/azure-vm-deploy.sh 1        # resource group, static IP + DNS label, NSG, vnet
bash docs/azure-vm-deploy.sh 2        # create the VM; cloud-init brings the stack up
bash docs/azure-vm-deploy.sh 3        # wait for cloud-init, then for TLS + the API
bash docs/azure-vm-deploy.sh 4        # enable backup (no-op if declined at init)
bash docs/azure-vm-deploy.sh verify   # 11 checks
```

`init` prints the generated `POSTGRES_PASSWORD` and `AUTHENTICATION_API_KEY` into `.secrets.deploy`-style files at mode 600. **Back them up outside the repo** — they are gitignored and not recoverable from Azure.

`render` regenerates `cloud-init.rendered.yaml` without calling Azure, so you can read exactly what the VM will be given before creating it. That file contains both secrets in plaintext and is gitignored.

First boot takes **5–12 minutes** on 2 ARM vCPUs: cloud-init installs Docker, adds a 2 GiB swapfile, clones the repo, and builds the manager. The swapfile matters — `tsc -b && vite build` can exceed what 4 GiB leaves free once Postgres and Redis are up.

Then Caddy needs another minute or two to obtain a certificate from Let's Encrypt over HTTP-01, which is why phase 3 waits for the API separately from waiting for cloud-init.

### Secrets on the VM

Both secrets reach the VM through cloud-init user-data and are written to `/opt/evolution/.env` at mode 600, root-owned. `az vm show` does not return `customData`, but the payload persists on disk at `/var/lib/cloud/instance/user-data.txt`, readable by root. Anyone with root on the box has them either way. Key Vault + a managed identity is the hardening path if that matters.

---

## 8. Verification

`verify` runs 11 checks and reports all of them even when some fail:

| # | Check | Expected |
|---|---|---|
| 1 | VM power state | `VM running` |
| 2 | five containers | api, manager, postgres, redis, caddy all `running` |
| 3 | API root over TLS | JSON with `version: 2.3.7` |
| 4 | API key enforced | `401` without a key |
| 5 | API key accepted | `200` with the key |
| 6 | CORS preflight from the manager origin | `access-control-allow-origin` present |
| 7 | manager on :8443 | `200` on `/health` |
| 8 | `SERVER_URL` | `.manager` contains this host, not localhost |

| 9 | **Redis AOF** | `appendonly yes` — the §4 fix |
| 10 | NSG exposure | 5432, 6379, 8080, 3000 **not** open |
| 10b | no NIC-level NSG | NIC has none; the subnet NSG governs |
| 11 | backup | protected, or explicitly disabled by choice |

Check 10b exists because the two NSG layers fail asymmetrically. The NSG is attached to the subnet and `az vm create --nsg ""` means "none" at the NIC. If a NIC-level NSG ever did appear, its defaults allow SSH only, so Caddy's 80/443/8443 would be blocked *at the NIC* while check 10 — which reads the subnet's rules — still passed. Checks 3 through 7 would then fail with nothing pointing at the cause.

Checks 2 and 9, plus phase 3's readiness loop and `logs`, go through `az vm run-command` rather than SSH, so they work with port 22 closed. `vm_run` extracts the script's output from the `[stdout]`/`[stderr]` framing that command returns; if that framing ever changes it falls back to printing the raw message, so a parsing problem cannot masquerade as "no containers running".

---

## 9. Link a WhatsApp number

```bash
bash docs/azure-vm-deploy.sh qr            # instance "primary"
bash docs/azure-vm-deploy.sh qr myinstance # or a name of your own
```

Writes `docs/qr.png`. Scan from WhatsApp → **Linked Devices → Link a Device**. QR codes expire in well under a minute; re-run the command rather than reusing a stale PNG.

### Manager UI

Open the `:8443` URL. **The pre-filled Server URL is wrong** — the SPA defaults that field to `window.location.origin`, which here is the manager on `:8443`, not the API. Overwrite it:

| Field | Value |
|---|---|
| Server URL | `https://evolution-<sfx>.southeastasia.cloudapp.azure.com` (no port) |
| API Key | your `AUTHENTICATION_API_KEY` |

Stored in `localStorage` under `apiUrl`. Per-browser-profile, lost on logout or on clearing site data. No env var or build arg can preconfigure it — the image contains no `VITE_`/`import.meta.env` references at all, despite what its README claims.

**Live chat updates will not work.** Websockets are off by default, and enabling them for the manager would also require `WEBSOCKET_ALLOWED_HOSTS=*`, which disables websocket authentication entirely and would expose the whole event stream unauthenticated on a public endpoint. Leave it off; use webhooks. Instance CRUD and QR display go over REST and work fine.

---

## 10. Honest trade-offs versus Container Apps

**You give up:**

- **Managed TLS.** Caddy replaces it. Automatic and reliable, but it is now a container you own, and a cert renewal failure is yours to notice.
- **Revision rollback.** No `az containerapp revision` equivalent. Rolling back means rebuilding or restoring a backup.
- **Auto-heal on host failure.** `restart: unless-stopped` covers process crashes; a dead host does not self-replace.
- **Managed Postgres.** Patching, tuning, and backups become yours. This is the largest real cost of the switch, and it is not reflected in the $39.40.
- **OS patching.** Ubuntu unattended-upgrades handles security updates; kernel reboots are yours to schedule.
- **A separate failure domain per component.** One box, one blast radius.

**You get:** ~$150/month back, signal-key durability that the ACA design cannot provide without §14's Azure Files workaround, 4 GiB for the API instead of the 1.0 GiB the ACA floor allows, and a deployment that matches the compose file this repo actually ships.

**Choose Container Apps if** uptime SLAs, revision rollback, or not owning a database matter more than $150/month. **Choose this if** it is a single-tenant gateway and the $50 budget is real.

---

## 11. Operations

```bash
bash docs/azure-vm-deploy.sh urls    # URLs, IP, API key, manager login instructions
bash docs/azure-vm-deploy.sh logs    # tail evolution-api and caddy
bash docs/azure-vm-deploy.sh ssh     # shell on the VM (needs ADMIN_SOURCE_IP set)
```

On the VM, `evolution-up` wraps the two-file compose invocation:

```bash
sudo evolution-up                       # up -d
sudo evolution-up ps
sudo evolution-up logs -f evolution-api
sudo evolution-up up -d --build         # after a git pull
```

Your public IP changing locks you out of SSH. Update `ADMIN_SOURCE_IP` in `.env.vm` and re-run phase 1 — `nsg_rule()` compares the rule's source against the wanted value and updates it in place, so re-running actually heals the drift. `az vm run-command` (used by `logs` and `verify`) works regardless, because it goes through the Azure control plane rather than port 22.

### Rebuilding the VM without re-linking WhatsApp

Prefer this over patching a running box by hand. Applying config changes in place leaves the compose files and the running containers disagreeing — `restart: unless-stopped` does `docker start`, which reuses each container's *creation-time* command, so a `CONFIG SET` or a hand-edited file is not what comes back after a reboot. Rebuilding makes the script the single source of truth. `evolution-stack.service` now reconciles on every boot, but a rebuild is still the honest way to apply anything structural.

All durable state lives in three Docker volumes. Move those and the session survives onto a completely different VM — no QR re-scan.

| Volume | Holds | Why it matters |
|---|---|---|
| `evolution_postgres_data` | credentials (`Session`), instances, message history | without it the instance is gone |
| `evolution_redis_data` | Baileys signal keys (AOF) | without it inbound messages fail to decrypt |
| `evolution_caddy_data` | the issued TLS certificate | avoids a re-issue and Let's Encrypt rate limits |

Keep `.env.vm` and `.secrets.vm` unchanged — the restored Postgres cluster still expects the *old* `POSTGRES_PASSWORD`, and reusing the same `DNS_LABEL` keeps both the hostname and the restored certificate valid.

```bash
IP=$(az network public-ip show -g evolution-vm-rg -n evolution-ip --query ipAddress -o tsv)

# 1. On the old VM: stop cleanly so Postgres is consistent, then archive.
ssh azureuser@$IP "sudo /usr/local/bin/evolution-up stop"
ssh azureuser@$IP "sudo tar czf /tmp/evo-data.tgz -C /var/lib/docker/volumes \
  evolution_postgres_data evolution_redis_data evolution_caddy_data && sudo chmod 644 /tmp/evo-data.tgz"
scp azureuser@$IP:/tmp/evo-data.tgz .
ssh azureuser@$IP "sha256sum /tmp/evo-data.tgz"; sha256sum evo-data.tgz   # must match

# 2. Delete only the VM, NIC and OS disk. Keep the public IP, NSG and vnet so
#    the hostname -- and therefore the restored certificate -- stay valid.
disk=$(az vm show -g evolution-vm-rg -n evolution-vm --query 'storageProfile.osDisk.name' -o tsv)
az vm delete -g evolution-vm-rg -n evolution-vm --yes
az network nic delete -g evolution-vm-rg -n evolution-vmVMNic
az disk delete -g evolution-vm-rg -n "$disk" --yes

# 3. Rebuild from the script and let cloud-init finish.
bash docs/azure-vm-deploy.sh 2
bash docs/azure-vm-deploy.sh 3

# 4. Restore over the fresh, empty volumes.
ssh-keygen -R $IP                      # the rebuilt VM has a new host key
scp evo-data.tgz azureuser@$IP:/tmp/
ssh azureuser@$IP "sudo /usr/local/bin/evolution-up stop"
ssh azureuser@$IP "sudo rm -rf /var/lib/docker/volumes/evolution_{postgres,redis,caddy}_data \
  && sudo tar xzf /tmp/evo-data.tgz -C /var/lib/docker/volumes"
ssh azureuser@$IP "sudo /usr/local/bin/evolution-up"

# 5. Confirm the migration was exact, then verify.
bash docs/azure-vm-deploy.sh verify
```

Compare row counts and `hlen` on the signal-key hash before and after; they should be identical, and `connectionState` should return `open` with no QR. Measured on a real rebuild: 1491 messages, 1 `Session`, 1 `Instance` and 880 signal-key fields all carried over unchanged, `state: open`, certificate reused (`ssl_verify_result=0`).

The archive contains your WhatsApp credentials and signal keys in cleartext. Delete both copies afterwards.

---

## 12. Teardown

```bash
bash docs/azure-vm-deploy.sh destroy
```

Prompts for the resource group name, then deletes everything. If backup was enabled, the Recovery Services vault may hold recovery points that block group deletion until soft-delete is disabled and the backup item is removed:

```bash
az backup protection disable -g evolution-vm-rg --vault-name <vault> \
  -c <vm> -i <vm> --delete-backup-data true --yes
```

The linked WhatsApp device stays registered on the phone until you remove it in **WhatsApp → Linked Devices**.

---

## 13. Verification notes

Checked rather than recalled:

- SKU restrictions, ARM64-only burstable availability, and quota: `az vm list-skus` / `az vm list-usage` against this subscription in `southeastasia`.
- `Canonical:ubuntu-24_04-lts:server-arm64:latest` resolves (Gen2).
- `evoapicloud/evolution-api:v2.3.7` publishes `linux/amd64` and `linux/arm64`: Docker Hub manifest list.
- The manager builds for `linux/arm64`: `az acr build --platform linux/arm64` succeeded, 433s.
- All prices: Azure Retail Prices API cross-checked against `azure.microsoft.com/api/v3/pricing/*/calculator/`, the calculator's own data source.
- The generated overlay merges as intended: `docker compose config` over `docker-compose.yml` + `docker-compose.prod.yml`, confirming env precedence, Redis AOF, and all five volumes.

- `az vm create --nsg ""` is the documented way to request no NIC-level NSG (`az vm create --help`: *specify `""` for none*). Under PowerShell that argument needs `'""'`; the script is bash.

**Confirmed on a live deployment** (`Standard_B2pls_v2`, southeastasia, 2026-08-04) — all 12 `verify` checks passed:

- ARM64 capacity was allocatable at `create` time
- all four upstream images pulled for arm64, including `evolution-api:v2.3.7` (1.75 GB)
- the on-VM `npm ci` + `tsc -b && vite build` completed; 2 GiB swap was enabled and barely touched (~3.0 GiB of 3.9 GiB still available with all five containers up)
- Let's Encrypt issued a certificate for the `*.cloudapp.azure.com` FQDN over HTTP-01
- five containers running; API returns `version: 2.3.7`; key enforced (401/200); CORS allow-origin present; manager 200 on `:8443`; Redis `appendonly yes`
- the NIC carries no NSG, so subnet rules govern
- egress to `web.whatsapp.com` works — `GET /` populates `whatsappWebVersion`
- `az vm run-command` does return the `[stdout]`/`[stderr]` framing `vm_run` parses

### The reboot test — §4's durability claim, measured

A linked instance with real traffic was carried through a full `az vm restart`. Nothing was re-scanned or re-linked.

| Metric | Before | After |
|---|---|---|
| signal-key hash fields | 848 | **848** |
| breakdown | 802 `pre-key`, 14 `lid-mapping`, 13 `session`, 12 `sender-key`, 3 `tctoken` | unchanged |
| `Message` rows | 1470 | 1470 |
| `Session` (credentials) | 1 | 1 |
| `connectionState` | `open` | **`open`** |
| `Bad MAC` errors | 0 | **0** |
| `failed to decrypt` | 0 | **3** — see below |
| TLS | valid | **valid, cert reused from `caddy_data` — no re-issue** |
| swapfile | 2 GiB | 2 GiB (fstab entry held) |

All five containers returned unattended within ~20 s of boot via `restart: unless-stopped`, and the API logged `Auto-connecting instance … (status: open)` — credentials recovered from Postgres, signal keys from the Redis AOF. Redis reported `aof_enabled:1`, `aof_last_write_status:ok`, `loading:0`.

This is the case that breaks the Container Apps design: there the same restart destroys the ephemeral sidecar's signal keys while the session still reports `open` and the phone still shows the device linked, so inbound messages stop decrypting with no visible cause. Here the session and its keys survive.

#### The three failures, stated plainly

In the ten minutes after that reboot, three inbound messages did fail:

```
01:48:59Z  boot
01:54:03Z  failed to decrypt   No session found to decrypt message
01:56:08Z  failed to decrypt   No session found to decrypt message
01:58:28Z  failed to decrypt   No session found to decrypt message
```

All three were in one group, from three different participants. In the same window 15 group messages arrived and 12 decrypted; that group has 34 messages decrypted in total. `Bad MAC` and `waiting for this message` stayed at 0, `Stream Errored` at 0, no logout, and sender-key material *grew* (12 → 20 fields), so keys were being written and persisted normally.

**This is not §13.1's failure mode**, which is `Bad MAC` across all inbound traffic while `state` reads `open`. `No session found` means the 1:1 Signal session with that specific participant was absent, so their sender-key distribution message could not be opened.

**The cause was not conclusively established.** Two candidate explanations:

1. `appendfsync everysec` (the setting at the time) can lose up to one second of writes when Redis stops. `bgrewriteaof` was run immediately before a graceful restart, so the window was small but non-zero, and a Signal session written in that final second would produce exactly this error.
2. Ordinary WhatsApp behaviour for group participants with whom no direct session exists — this happens without any reboot.

Candidate 1 has been eliminated going forward by switching to `appendfsync always` (§4). If `No session found` appears again **without** a restart, the cause is candidate 2 and nothing is wrong. If it only ever follows restarts, the fsync change addresses it. Watch with `azure-vm-deploy.sh logs`.

Either way the practical impact is bounded: individual messages from participants whose session is missing are unreadable until the sender re-sends. It is not session loss and does not require re-linking.

### The from-scratch rebuild

The whole stack was then rebuilt from this script onto a new VM, with the session migrated per §11 rather than re-linked. This deployment is therefore exactly what the script produces from a clean slate, with no accumulated hand-patches.

Confirmed on the rebuilt VM:

- `appendfsync always` is **baked into the container command**, not merely set at runtime — `Config.Cmd` shows it. On the previous VM the baked command still read `everysec`, so a reboot would have silently reverted the change while `config get` had reported `always` beforehand.
- `evolution-stack.service` is `enabled`, so compose config is reconciled on every boot.
- `evolution-up` with no arguments works.
- Migration was exact: 1491 messages, 1 `Session`, 1 `Instance`, 880 signal-key fields, `state: open`, certificate reused with no ACME re-issue. Archive checksum matched at all three hops.
- All 12 `verify` checks pass, and **zero** `Bad MAC` / `failed to decrypt` / `waiting for this message` — against 3 on the `everysec` deployment.

That last comparison is suggestive, not conclusive: different traffic over a shorter window. But it is consistent with the fsync window having caused the three failures rather than ordinary group behaviour. If `No session found` never reappears under `always`, that is the answer.

One `conflict`/`device_removed` event does appear in that deployment's log, timestamped ~16 hours *before* the reboot, during the initial linking window — consistent with a superseded first link. `Stream Errored` count was 0 and the session stayed continuously `open` through it. Worth knowing the signature: `device_removed` recurring **together with** `Stream Errored (conflict)` is the §13.2 tell that two things are presenting the same WhatsApp identity, which this single-container design should never produce on its own.

**Still not verified:**

- egress volume, and therefore whether the 100 GB/month free allowance holds
- a restore from any backup (backup was declined on this deployment)
- certificate renewal at ~60 days — though the reboot showed `caddy_data` persists, which is the mechanism renewal depends on
