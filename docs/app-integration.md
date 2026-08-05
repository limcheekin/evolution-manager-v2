# App Integration Guide — Embedding Evolution Manager v2

**Audience:** engineers embedding this app's chat UI into a third-party web application.

**Scope:** this document covers the only integration surface **this repository** exposes — the iframe embed at `/manager/embed-chat`. For talking to Evolution API directly (instance CRUD, sending messages, receiving events), see **[`api-integration.md`](./api-integration.md)**.

**Version basis:** this repo at `package.json` version `2.0.0`, paired with `evoapicloud/evolution-api:v2.3.7` (the tag pinned in `docker-compose.yml`).

Every claim about **this app** is traced to a file and line in this repository. Claims about **Evolution API's** own behaviour are marked `[upstream]` and should be confirmed against <https://doc.evolution-api.com> for your API version.

> **Maintainers:** each guide is deliberately self-contained, so five blocks are duplicated verbatim in [`api-integration.md`](./api-integration.md) — the topology table (§2), the `CORS_ORIGIN=*` explanation (§4.2), the default-`AUTHENTICATION_API_KEY` warning (§10), smoke-test steps 1–2 and 4 (§11), and the provenance paragraph in the appendix (§12). **Change one, change both.**

---

## Table of Contents

1. [What you are integrating with](#1-what-you-are-integrating-with)
2. [Deployment topology and origins](#2-deployment-topology-and-origins)
3. [Before you build: known limitations](#3-before-you-build-known-limitations)
4. [Step-by-step: embedding the chat UI](#4-step-by-step-embedding-the-chat-ui)
5. [Selecting a conversation](#5-selecting-a-conversation)
6. [Failure modes](#6-failure-modes)
7. [Browser state the embed writes](#7-browser-state-the-embed-writes)
8. [Deep-linking into the authenticated manager](#8-deep-linking-into-the-authenticated-manager)
9. [Provider requirement: `api`, not `go`](#9-provider-requirement-api-not-go)
10. [Security checklist](#10-security-checklist)
11. [Embed smoke test](#11-embed-smoke-test)
12. [Appendix — verified vs unverified](#12-appendix--verified-vs-unverified)

---

## 1. What you are integrating with

**Evolution Manager v2 is a static single-page application. It has no backend of its own.**

- Build output is static assets served by nginx (`Dockerfile:29-43`).
- Every network call the app makes goes **from the end user's browser directly to Evolution API**, using a base URL read out of `localStorage` (`src/lib/queries/api.ts:11-14`).
- There is no server-side session, no API the manager itself exposes, no server-to-server surface on the manager.
- There are **no build-time or runtime configuration env vars**. The codebase contains zero `VITE_` / `import.meta.env` references — the `VITE_EVOLUTION_API_URL` / `VITE_EVOLUTION_API_KEY` variables mentioned in `README.md` do not exist in the code. Do not plan around them. Configuration is per-browser-profile `localStorage`, written at login (`src/lib/queries/token.ts:31-45`).

So "integrate with the app" means exactly one thing: **mount `/manager/embed-chat` in an iframe.** It is the only route not behind an auth guard (`src/routes/index.tsx:297-305`).

**Pick the right surface before you start:**

| Your requirement | Use |
|---|---|
| Show a WhatsApp conversation inside our app's UI, minimal build effort | this document |
| Send messages from our backend | [`api-integration.md` §4.3](./api-integration.md#43-messaging) |
| React to inbound messages server-side | [`api-integration.md` §5.1](./api-integration.md#51-webhook-recommended-for-server-to-server) |
| Live UI updates in our own frontend | [`api-integration.md` §5.2](./api-integration.md#52-socketio-websocket) |
| Provision / connect / delete instances | [`api-integration.md` §4.2](./api-integration.md#42-instance-lifecycle) |
| Build our own chat UI (full control) | [`api-integration.md`](./api-integration.md) |
| Bounce a user into the full manager UI | not supportable cross-origin — §8 |

If your requirement is "our product needs to send and receive WhatsApp messages", you want `api-integration.md` and can skip the manager entirely. Use the embed only when you specifically want the manager's rendered chat pane inside your page — and read §3 first, because that pane is the part that does not work as shipped.

---

## 2. Deployment topology and origins

The manager and the API are **separate origins** in every deployment in this repo.

`docker-compose.yml`:

| Service | Host port | Role |
|---|---|---|
| `evolution-manager` | `3000` → container `80` | static SPA (nginx) |
| `evolution-api` | `8080` | Evolution API |
| `postgres`, `redis` | not published | internal only |

`docs/azure-vm-setup-guide.md:23-40` (Caddy in front, one hostname, two ports):

```
:443  ──► evolution-api:8080      https://<host>
:8443 ──► evolution-manager:80    https://<host>:8443
```

Two implications you must design around:

1. **Different port = different origin.** `https://host:8443` and `https://host` are cross-origin for CORS, iframe, `localStorage`, and `postMessage`. The API must return CORS headers that permit the manager origin.
2. **The login screen's default is wrong on split deployments.** It pre-fills Server URL with `window.location.origin` (`src/pages/Login/index.tsx:44`), which only happens to be right in the upstream layout where Evolution API serves the manager itself under `/manager`. On a split deployment the operator must overwrite it with the API URL (`docs/azure-setup-guide.md:632-641`).

### Route map

From `src/routes/index.tsx`:

| Path | Guard | Notes |
|---|---|---|
| `/` | none | marketing/landing page (`src/pages/Home.tsx`) |
| `/manager/login` | `PublicRoute` | credential entry |
| `/manager/license/callback` | none | license activation return URL |
| `/manager/` | `ProtectedRoute` | instance list |
| `/manager/instance/:instanceId/<feature>` | `ProtectedRoute` + feature flag | 24 routes: `dashboard`, `chat`, `settings`, `webhook`, `websocket`, `rabbitmq`, `sqs`, `proxy`, `chatwoot`, `typebot`, `openai`, `dify`, `n8n`, `evoai`, `evolutionBot`, `flowise` |
| **`/manager/embed-chat`** | **none** | **third-party embed target** (`:299`) |
| **`/manager/embed-chat/:remoteJid`** | **none** | **embed, conversation pre-selected** (`:303`) |

`ProtectedRoute` authenticates purely on `localStorage` presence: `apiUrl` + `token` + `version` for the `api` provider, `apiUrl` + `token` for `go` (`src/components/providers/protected-route.tsx:13-19`). A third-party page on another origin cannot write those keys — see §8.

---

## 3. Before you build: known limitations

The embed is **not a finished product surface**. Verified from code, before you invest:

| Limitation | Evidence | Consequence |
|---|---|---|
| **Message history does not load.** The message pane (`Messages`) reads the instance from `InstanceContext`, which resolves `instanceId` from the route param `:instanceId` (`src/contexts/InstanceContext.tsx:29-33`). The embed routes have no `:instanceId`, so `useFetchInstance` stays disabled and `instance` is `null`. `useFindMessages` is then called with `instanceName: undefined` and is disabled by its own `enabled: !!instanceName && !!remoteJid` guard (`src/pages/instance/Chat/messages.tsx:306, 420-423`; `src/lib/queries/chat/findMessages.ts:30`). | code-traced | The conversation pane renders empty. No prior messages appear. |
| **Live message append inside the pane is also skipped** — same `instance` null: the socket effect returns early at `if (!instance?.name \|\| !remoteJid) return` (`src/pages/instance/Chat/messages.tsx:445`). | code-traced | Only the outer chat *list* updates in real time (`src/pages/instance/EmbedChatMessage/index.tsx:129-199`). |
| **Sending requires `remoteJid` as a query parameter**, not the path segment. `InputMessage` reads `searchParams.get("remoteJid")` only (`src/pages/instance/EmbedChatMessage/InputMessage/index.tsx:95`) and every send path bails on falsy `remoteJid` (`:262, :287, :339`), while the pane itself follows `routeRemoteJid \|\| searchParams.get(...)` (`src/pages/instance/EmbedChatMessage/index.tsx:53-54`). | code-traced | With the path form alone the composer silently does nothing. Worse, after an in-list chat click the two diverge and messages go to the **wrong contact** — see §5. |
| **The chat list sort dereferences `chat.lastMessage.messageTimestamp`**, a field absent from the `Chat` type (`src/pages/instance/EmbedChatMessage/index.tsx:285, 333`; `src/types/evolution.types.ts:51-60`). | code-traced | If `POST /chat/findChats` omits `lastMessage` for any chat, the sort throws and the list fails to render. |
| **The embed renders two stacked composers, and the upper one is dead.** `EmbedChatMessage` renders `<Messages/>` and then `<InputMessage/>` (`src/pages/instance/EmbedChatMessage/index.tsx:389-401`). `Messages` contains its own unconditional `<Textarea>` + Send button (`src/pages/instance/Chat/messages.tsx:657-679`) wired to a `sendTextMessage` that bails on `!instance?.name \|\| !instance?.token` (`:318`) — and `instance` is null in the embed, per the first row. Its attachment button is gated `{instance && …}` so it does not render at all (`:655`). | code-traced | The user sees two message inputs. The upper one accepts typing and its Send button enables, then does **nothing** — no error, no toast. Only the lower `InputMessage` sends. |
| **No UI language parameter.** i18next reads `localStorage["i18nextLng"]`, defaulting to `en-US` (`src/translate/i18n.ts:24`). | code-traced | Cross-origin you cannot set it. Embed UI text is `en-US`. Available: `en-US`, `pt-BR`, `es-ES`, `fr-FR`. |

**Net:** as shipped, the embed gives you a chat list, per-chat selection, and outbound text/media/audio through its lower composer. It does **not** give you readable conversation history, it shows a second composer that silently does nothing, and its chat pane and working composer can disagree about which contact is selected (§5).

Note the common root cause: **three of these six rows are the same bug.** `InstanceContext` is empty on the embed routes, so everything inside `Messages` — history, live append, its composer, its attachment button — is disabled. Fixing that one thing fixes three rows.

Three patches make the embed production-usable, all small:

1. **`InstanceContext`** — make `EmbedChat` populate it from `useEmbedInstance()`, or pass the instance into `Messages` as a prop instead of pulling it from context. Fixes history, live append, and the dead upper composer at once.
2. **Send target** — give `InputMessage` the same `routeRemoteJid || searchParams.get("remoteJid")` precedence the parent already uses. Fixes the wrong-contact send (§5).
3. **Duplicate composer** — with patch 1 applied you now have two *working* composers; drop one. Either stop rendering `<InputMessage/>` in `EmbedChatMessage`, or split the composer out of `Messages` so the pane is display-only.

Without patch 2, restrict the embed to a single conversation (§5). If you would rather not fork, build your own pane against [`api-integration.md` §4](./api-integration.md#4-endpoint-contract) — the embed's only real advantage is the rendered message bubbles, and those are exactly what does not load.

---

## 4. Step-by-step: embedding the chat UI

### 4.1 Step 1 — Remove the iframe blocker (mandatory, cross-origin)

The shipped nginx config sends `X-Frame-Options: SAMEORIGIN` on every response:

```
# .docker/nginx.conf:22
add_header X-Frame-Options "SAMEORIGIN" always;
```

Every cross-origin iframe of the manager is blocked by the browser, with only a console error. This is the first thing you will hit.

The config that actually ships in the image is `.docker/nginx.conf`, copied to `/etc/nginx/conf.d/` (`Dockerfile:35`). The `.docker/nginx/` subtree (`sites.d/`, `include.d/`, `conf.d/default.conf`) and `.docker/add-env-vars.sh` are **not** copied into the image — only `nginx.conf` and `start.sh` are. Editing `include.d/spa.conf` has no effect; edit `.docker/nginx.conf`.

The `Content-Security-Policy` line (`.docker/nginx.conf:26`) has no `frame-ancestors` directive, so `X-Frame-Options` is the sole blocker. Drop line 22 and extend the existing CSP on line 26 — **one** edit to each, not a second header:

```diff
--- a/.docker/nginx.conf
+++ b/.docker/nginx.conf
@@ -19,10 +19,11 @@
     # Security headers
-    add_header X-Frame-Options "SAMEORIGIN" always;
     add_header X-XSS-Protection "1; mode=block" always;
     add_header X-Content-Type-Options "nosniff" always;
     add_header Referrer-Policy "no-referrer-when-downgrade" always;
-    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
+    # frame-ancestors replaces X-Frame-Options: it takes an origin allowlist,
+    # which XFO has no form for. Keep it on ONE header — see note below.
+    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'; frame-ancestors 'self' https://partner.example.com" always;
```

Notes:
- **Why one line and not two:** nginx `add_header` directives at the same level are **additive**, not overriding. Two `Content-Security-Policy` response headers make the browser enforce the **intersection** of both — more restrictive than either, and your `frame-ancestors` allowlist would be intersected with the original header's implicit `default-src` fallback. Extend the existing header; never add a second one.
- Prefer `frame-ancestors` over simply deleting `X-Frame-Options`: it accepts an allowlist, so you are not trading a same-origin restriction for none at all.
- Rebuild the image after editing; the config is baked in, not mounted.
- Verify: `curl -sI https://<manager-host>/manager/embed-chat | grep -iE 'x-frame|content-security'`.

### 4.2 Step 2 — Allow the API to be called from the manager origin

Inside the iframe, the manager makes XHR calls from the **manager origin** to the **API origin** (`src/contexts/EmbedInstanceContext.tsx:45-49`, `src/lib/queries/api.ts:11-14`). The API must permit that origin.

`CORS_ORIGIN=*` is the setting used throughout this repo's deployment docs and scripts (`docs/azure-deploy.sh:324`, `docs/azure-vm-deploy.sh:427`).

Per `docs/azure-setup-guide.md:706-712`, verified against upstream `evolution-api` at tag `2.3.7`: **do not** set an explicit `CORS_ORIGIN` allowlist. Upstream's origin callback does `ORIGIN.indexOf(requestOrigin)`; `requestOrigin` is `undefined` for non-browser callers, `indexOf(undefined) === -1`, so it calls back with an error and returns **HTTP 500 for every request that carries no `Origin` header** — breaking curl, server-to-server callers, n8n, Postman, and HTTP health probes. `*` combined with credentials is safe here only because `cors@2.8.5` reflects the request origin instead of emitting a literal `*`. It is still open CORS: restrict at your ingress or WAF instead. `[upstream, per repo docs]`

Verify:

```bash
curl -si -X OPTIONS "$API_URL/instance/fetchInstances" \
  -H "Origin: https://partner.example.com" \
  -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: apikey" | grep -i access-control
```

### 4.3 Step 3 — Confirm the API is reachable *from the end user's browser*

Because the manager has no backend, `apiUrl` must resolve and be TLS-valid **on the end user's network**, not just from your servers. A private-network or `localhost` API URL will fail for every external user. Mixed content also applies: an `https://` partner page cannot let the framed manager call an `http://` API.

### 4.4 Step 4 — Provision an instance token

The embed needs an Evolution API key with rights to read the instance and to send. Per-instance tokens come back on `GET /instance/fetchInstances` as `Instance.token` (`src/types/evolution.types.ts:32`), and are set at creation time via `NewInstance.token` (`:22`).

`$AUTHENTICATION_API_KEY` below is the **global** key of your Evolution API deployment — the value set on the `evolution-api` service in `docker-compose.yml` (`.env.example` documents it). You need it only to mint or read back an instance token; it must never appear in the embed URL itself.

```bash
# Create an instance with an explicit token you control
curl -s -X POST "$API_URL/instance/create" \
  -H "apikey: $AUTHENTICATION_API_KEY" \
  -H "content-type: application/json" \
  -d '{"instanceName":"partner-acme","integration":"WHATSAPP-BAILEYS","qrcode":true,"token":"<your-32+-char-secret>"}'

# Or read back the token of an existing instance
curl -s "$API_URL/instance/fetchInstances?instanceName=partner-acme" \
  -H "apikey: $AUTHENTICATION_API_KEY" | jq -r '.[0].token'
```

**Never put `AUTHENTICATION_API_KEY` (the global key) in an embed URL.** It is admin-scoped across all instances (§10).

Whether Evolution API in fact scopes an instance token to that instance only is upstream behaviour — verify it before trusting it for tenant isolation: `[upstream]`

```bash
# Expect a failure / empty result, NOT another tenant's instance
curl -si "$API_URL/instance/fetchInstances?instanceName=some-other-instance" \
  -H "apikey: <instance-token>"
```

### 4.5 Step 5 — Build the embed URL

`EmbedInstanceProvider` requires three query parameters and errors without them (`src/contexts/EmbedInstanceContext.tsx:29-36`):

| Param | Required | Meaning |
|---|---|---|
| `token` | **yes** | Evolution API key sent as the `apikey` header. Also written to `localStorage["instanceToken"]`. |
| `instanceName` | **yes** | Instance name, used as `?instanceName=` on `GET /instance/fetchInstances`. |
| `apiUrl` | **yes** | Evolution API base URL. Trailing slash stripped, then written to `localStorage["apiUrl"]`. |
| `remoteJid` | recommended | WhatsApp JID to open, e.g. `5511999998888@s.whatsapp.net` or `<id>@g.us`. **Required for sending** (§3). |

Missing any of the three required parameters renders the hardcoded Portuguese string `Token, instanceName e apiUrl são obrigatórios` (`:34`) — it is not localized.

Boot sequence on load (`src/contexts/EmbedInstanceContext.tsx:28-66`):

1. Read `token`, `instanceName`, `apiUrl` from the query string.
2. Write `localStorage["apiUrl"]` and `localStorage["instanceToken"]`.
3. `GET {apiUrl}/instance/fetchInstances?instanceName={instanceName}` with header `apikey: {token}`.
4. Expect a **non-empty array**; take element `[0]`. A non-array or empty response yields `Instância não encontrada`; a thrown request yields `Erro ao validar token ou buscar instância`.

**Optional colour parameters** — all 12 are read in `src/contexts/EmbedColorsContext.tsx:41-53`. Any CSS colour string works; each falls back to a theme-dependent default (`:51-135`).

| Param | Applies to |
|---|---|
| `backgroundColor` | container background |
| `textForegroundColor` | primary text |
| `primaryColor` | accents, active chat row, buttons |
| `fromMeBubbleColor` | outbound bubble |
| `fromMeForegroundColor` | outbound bubble text |
| `fromOtherBubbleColor` | inbound bubble |
| `fromOtherForegroundColor` | inbound bubble text |
| `fromMeQuotedBubbleColor` | quoted block, outbound |
| `fromOtherQuotedBubbleColor` | quoted block, inbound |
| `inputBackgroundColor` | composer background |
| `inputTextForegroundColor` | composer text |
| `inputIconsMainColor` | composer icons |

`#` must be percent-encoded as `%23` in a URL. Build the URL with a real encoder:

```js
function buildEmbedUrl({ managerOrigin, apiUrl, instanceName, token, remoteJid, colors = {} }) {
  const url = new URL("/manager/embed-chat", managerOrigin);
  url.searchParams.set("apiUrl", apiUrl);
  url.searchParams.set("instanceName", instanceName);
  url.searchParams.set("token", token);
  if (remoteJid) url.searchParams.set("remoteJid", remoteJid);   // required to send
  for (const [k, v] of Object.entries(colors)) url.searchParams.set(k, v);
  return url.toString();
}
```

### 4.6 Step 6 — Mount the iframe

```html
<iframe
  src="https://manager.example.com:8443/manager/embed-chat?apiUrl=https%3A%2F%2Fapi.example.com&instanceName=partner-acme&token=REDACTED&remoteJid=5511999998888%40s.whatsapp.net&primaryColor=%23e0f0f0"
  style="width:100%;height:720px;border:0"
  referrerpolicy="no-referrer"
  allow="microphone"
  title="WhatsApp chat"></iframe>
```

- **`allow="microphone"` is required for voice notes.** The composer calls `navigator.mediaDevices.getUserMedia` and `MediaRecorder` (`src/pages/instance/EmbedChatMessage/InputMessage/index.tsx:173, 197`); Permissions Policy blocks those in a cross-origin iframe without explicit delegation. Omit it if you do not want voice notes.
- **`referrerpolicy="no-referrer"` reduces token leakage** — it stops your page URL going out, and is good hygiene alongside §10.
- The embed sizes to `h-screen` / `h-full` (`src/pages/instance/EmbedChat/index.tsx:52`), so give the iframe an explicit height; it will not auto-grow.
- **Budget height for two composer rows until patch 3 (§3) is applied.** The right panel is `flex h-full flex-col justify-between` with header, `Messages`, and `InputMessage` as siblings (`src/pages/instance/EmbedChatMessage/index.tsx:375`), and `Messages`' own composer block is `flex-shrink-0` (`src/pages/instance/Chat/messages.tsx:646`). So the header plus **both** composers consume fixed vertical space no matter how short the iframe is — and the one that actually sends is the lower one. At small heights it is the first thing clipped, which presents as "the embed doesn't work".
- Layout is responsive: the chat-list panel is hidden below the `768px` breakpoint (`src/pages/instance/EmbedChatMessage/index.tsx:238`, `md:flex`). Below 768px width, users see only the conversation pane — so pass `remoteJid` on narrow embeds.
- **There is no `postMessage` API.** Nothing in the embed emits or listens for cross-frame messages; navigation is internal (`src/pages/instance/EmbedChatMessage/index.tsx:66-70`). Your page cannot observe or drive the embed after mount. To change conversation, change the iframe `src`.

---

## 5. Selecting a conversation

Two forms exist, and they are **not equivalent**:

| Form | Chat pane renders | Composer can send |
|---|---|---|
| `?remoteJid=<jid>` | yes (`src/pages/instance/EmbedChatMessage/index.tsx:54`) | **yes** |
| `/manager/embed-chat/<jid>` (path only) | yes (same line, route param branch) | **no** — `InputMessage` reads only the query param (`:95`) |

The divergence is exact: `EmbedChatMessage` computes `remoteJid = routeRemoteJid || searchParams.get("remoteJid")` and gates the right panel on that **combined** value (`src/pages/instance/EmbedChatMessage/index.tsx:53-54, 373`) — route param wins. `InputMessage` never looks at the route param at all (`src/pages/instance/EmbedChatMessage/InputMessage/index.tsx:95`).

**Which produces a genuine mis-send hazard, worse than an inert composer.** Clicking a chat in the list navigates to the path form while *preserving existing query params* (`src/pages/instance/EmbedChatMessage/index.tsx:66-70`). So a user who loads `?remoteJid=A` and then clicks chat B lands on `/manager/embed-chat/B?remoteJid=A`: the pane, header, and avatar show **B**, while the composer sends to **A**. Messages go to the wrong contact with no visible cue.

The embed's two navigation affordances behave differently, which is worth knowing before you decide what to hide:

| Affordance | Resulting URL | Safe? |
|---|---|---|
| Clicking an existing chat in the list (`src/pages/instance/EmbedChatMessage/index.tsx:66-70`) | `/manager/embed-chat/<B>?remoteJid=<A>` — path *and* stale query | **No** — pane and composer diverge |
| The **New chat** dialog, which takes a typed JID (`src/pages/instance/EmbedChatMessage/NewChat/index.tsx:23-28`) | `/manager/embed-chat?…&remoteJid=<typed>` — query only, `set()` overwrites any previous value | **Yes** — both read the same value |

So the New-chat dialog is the one in-embed way to switch conversation correctly. If you ship the embed unpatched, hide the chat list and leave the dialog.

**Recommendation:** pass `remoteJid` as a query parameter to make sending work, and then either (a) treat the embed as single-conversation — hide or ignore the chat list, and remount the iframe with a fresh URL to change conversation — or (b) patch `InputMessage` to read the route param with the same `routeRemoteJid || searchParams.get(...)` precedence the parent uses. Do not ship the multi-chat list with a query-param `remoteJid` unpatched.

---

## 6. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Blank iframe, console `Refused to display … in a frame` | `X-Frame-Options: SAMEORIGIN` | §4.1 |
| Red box: `Token, instanceName e apiUrl são obrigatórios` | missing required query param | §4.5 |
| Red box: `Instância não encontrada` | `fetchInstances` returned `[]`/non-array — wrong `instanceName`, or token not scoped to it | §4.4 |
| Red box: `Erro ao validar token ou buscar instância` | request threw: CORS, DNS, TLS, 401, mixed content | §4.2, §4.3 |
| Spinner forever | `apiUrl` unreachable from the browser; request pending until the 30 s axios timeout (`src/lib/queries/api.ts:6`) | §4.3 |
| Chat list empty / blank panel | `POST /chat/findChats` failed (toast `Erro ao buscar chats`, `src/pages/instance/EmbedChatMessage/index.tsx:100`) or threw on the `lastMessage` sort | §3 |
| Two message inputs visible; the upper one does nothing | `Messages` renders its own composer, dead because `InstanceContext` is empty | §3 |
| Lower composer does nothing | `remoteJid` not in the query string | §5 |
| No attachment button in the upper composer | `MediaOptions` is gated on a null `instance` (`src/pages/instance/Chat/messages.tsx:655`) | §3 |
| **Message delivered to the wrong contact** | user clicked a chat in the list; pane follows the route param, composer follows the query param | §5 — do not ship the chat list unpatched |
| Conversation pane empty despite existing history | known limitation | §3 |
| Mic button fails | iframe missing `allow="microphone"`, or the page is not a secure context | §4.6 |

---

## 7. Browser state the embed writes

All on the **manager's** origin. Keys are declared in `src/lib/queries/token.ts:6-18`.

| Key | Written by the embed | Purpose |
|---|---|---|
| `apiUrl` | yes (`src/contexts/EmbedInstanceContext.tsx:42`) | axios `baseURL`, socket.io URL. Trailing slash stripped. |
| `instanceToken` | yes (`:43`) | fallback `apikey` for the per-instance axios client |
| `accessToken` | yes, temporarily — restored on unmount (`src/pages/instance/EmbedChatMessage/index.tsx:123-127, 206-211`) | legacy; read by nothing in this codebase |
| `i18nextLng` | no — read only | UI language, defaults `en-US` (§3) |

**The embed shares this namespace with the logged-in manager.** Loading an embed overwrites `apiUrl` and `instanceToken`. If the same browser profile also has the manager logged in, the embed repoints the manager's `apiUrl`. Documented behaviour, not a defect — but if it matters, serve the embed from a distinct manager origin.

`instanceToken` is written **only** here; the login flow never writes it. Full key inventory and the two-client fallback logic: [`api-integration.md` §3](./api-integration.md#3-authentication-model).

---

## 8. Deep-linking into the authenticated manager

You cannot hand a user a URL that lands them logged-in inside `/manager/**`.

- `ProtectedRoute` gates on `localStorage` keys `apiUrl` + `token` (+ `version` for the `api` provider) on the **manager's origin** (`src/components/providers/protected-route.tsx:13-19`).
- Those keys are only written by the login form (`src/lib/queries/token.ts:31-45`). There is no URL, query-parameter, or `postMessage` path that writes them.
- Same-origin policy stops your page writing them.
- `PublicRoute` redirects an already-authenticated visitor away from `/manager/login` to `/` (`src/components/providers/public-route.tsx:16-18`), so you cannot even reliably land them on the login form.

Options, in order of preference:

1. **Use the embed** (§4) — the supported surface, no manager session needed.
2. **Link to `/manager/login`** and have the operator enter credentials once per browser profile. The URL cannot prefill them.
3. **Build your own UI** on [`api-integration.md`](./api-integration.md).
4. **Patch the manager** to accept credentials from the URL — the same trade-off the embed already makes (secret in a URL, §10) and now for an admin-scoped key. Not recommended.

---

## 9. Provider requirement: `api`, not `go`

The manager can target two backends, selected by `localStorage["provider"]` (`src/lib/queries/token.ts:61-64`), default `"api"`.

**The embed only works against the `api` provider.** Two independent reasons:

- `chat` is unsupported on `go` in the feature matrix (`src/lib/provider/features.ts:5-22`).
- `EmbedInstanceContext` calls the `api`-only path `/instance/fetchInstances` unconditionally (`src/contexts/EmbedInstanceContext.tsx:45`), bypassing provider dispatch entirely.

Full matrix and the `api` ↔ `go` endpoint divergence: [`api-integration.md` §6](./api-integration.md#6-provider-variants-api-vs-go).

---

## 10. Security checklist

Facts to design around, not defects to fix — but do not skip them.

1. **The instance token travels in a URL query string.** It lands in browser history, the `Referer` header, and any proxy or access log between the partner page and the manager. Mitigate: `referrerpolicy="no-referrer"` on the iframe; short-lived, per-instance, rotatable tokens; never the global key; scrub query strings from your own access logs.
2. **`AUTHENTICATION_API_KEY` is admin-scoped.** It authorizes `/instance/create`, `/instance/delete`, and full enumeration. Never expose it to a browser, never put it in an embed URL, never ship it to a partner.
3. **The published image has a publicly known default key.** `AUTHENTICATION_API_KEY` defaults to `429683C4C977415CAAFCCE10F7D57E11`, which is in the public upstream repo. Omit it and your gateway is world-writable (`docs/azure-setup-guide.md:704`; `.env.example` warns about exactly this). Set it explicitly.
4. **The embed writes to the manager origin's `localStorage`,** overwriting `apiUrl` and `instanceToken` (§7). Serve embeds from a separate manager origin if that collision matters.
5. **Relaxing `X-Frame-Options` re-enables clickjacking exposure.** Use CSP `frame-ancestors` with an explicit allowlist rather than removing the header (§4.1).
6. **`CORS_ORIGIN=*` is open CORS.** Required to avoid upstream's 500-on-missing-`Origin` bug (§4.2), so restrict at the ingress/WAF layer instead of at the app.
7. **Instance tokens are readable via `GET /instance/fetchInstances` with the global key** — `Instance.token` is returned in plaintext (`src/types/evolution.types.ts:32`). Treat any global-key leak as a compromise of every instance token.
8. **Verify instance-token scoping yourself** before relying on it for tenant isolation (§4.4). Upstream behaviour, not verifiable from this repo. `[upstream]`
9. **The mis-send hazard in §5 is a security-relevant bug, not only a UX one** — an unpatched multi-chat embed can deliver a message intended for contact B to contact A. Treat it as a data-disclosure path.

API-side items (websocket auth bypass, CSRF/cookie posture): [`api-integration.md` §7](./api-integration.md#7-security-checklist).

---

## 11. Embed smoke test

Run in order. Each step fails loudly on its own before the next depends on it.

```bash
export API_URL="https://api.example.com"
export MANAGER_URL="https://manager.example.com:8443"
export GLOBAL_KEY="…"                 # AUTHENTICATION_API_KEY
export INSTANCE="partner-acme"
```

**1 — API alive and reporting a version** (the login gate, `src/lib/queries/auth/verifyServer.ts:14`)

```bash
curl -s "$API_URL/" | jq '{version, clientName}'      # version must be non-null
```

**2 — Global key enforced**

```bash
curl -so /dev/null -w '%{http_code}\n' "$API_URL/instance/fetchInstances"                            # expect 401
curl -so /dev/null -w '%{http_code}\n' -H "apikey: $GLOBAL_KEY" "$API_URL/instance/fetchInstances"   # expect 200
```

**3 — CORS permits the manager origin**

```bash
curl -si -X OPTIONS "$API_URL/instance/fetchInstances" \
  -H "Origin: $MANAGER_URL" -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: apikey" | grep -i access-control-allow-origin
```

**4 — Instance exists and is connected**

```bash
curl -s "$API_URL/instance/fetchInstances?instanceName=$INSTANCE" \
  -H "apikey: $GLOBAL_KEY" | jq '.[0] | {name, connectionStatus, token}'
# connectionStatus must be "open"; capture token as INSTANCE_TOKEN
export INSTANCE_TOKEN="…"
```

**5 — Instance token can do what the embed needs**

```bash
curl -s "$API_URL/instance/fetchInstances?instanceName=$INSTANCE" -H "apikey: $INSTANCE_TOKEN" | jq 'length'   # expect >= 1
curl -s -X POST "$API_URL/chat/findChats/$INSTANCE" -H "apikey: $INSTANCE_TOKEN" \
  -H "content-type: application/json" -d '{"where":{}}' | jq 'length'
```

**5b — `lastMessage` present on every chat** (§3 crash risk)

```bash
curl -s -X POST "$API_URL/chat/findChats/$INSTANCE" -H "apikey: $INSTANCE_TOKEN" \
  -H "content-type: application/json" -d '{"where":{}}' \
  | jq '[.[] | select(.lastMessage == null or .lastMessage.messageTimestamp == null)] | length'   # expect 0
```

The crash at `EmbedChatMessage:285` is a dereference of `b.lastMessage.messageTimestamp`, so the fatal case is `lastMessage` itself being absent — hence the explicit `.lastMessage == null` arm. A null `messageTimestamp` does not throw, but sorts unpredictably, so it is worth catching too.

**6 — Manager reachable and frameable**

```bash
curl -so /dev/null -w '%{http_code}\n' "$MANAGER_URL/health"                              # expect 200
curl -sI "$MANAGER_URL/manager/embed-chat" | grep -iE 'x-frame-options|content-security'  # no blocking XFO
```

**7 — Outbound send works** (proves the token can do what the composer will do)

```bash
curl -s -X POST "$API_URL/message/sendText/$INSTANCE" \
  -H "apikey: $INSTANCE_TOKEN" -H "content-type: application/json" \
  -d '{"number":"5511999998888@s.whatsapp.net","text":"integration smoke test"}' | jq '.key.id'
```

**8 — Embed loads in a real browser.** Build the URL per §4.5 and open it directly (not framed) first, to isolate embed errors from iframe errors. Expect: chat list populated, chosen conversation pane visible, and the **lower** composer sending. Expect **no** message history, and expect the **upper** composer to do nothing (§3).

**9 — Embed loads framed.** Mount §4.6 on a page on your real origin. Check the console for `Refused to display`, CORS errors, and Permissions Policy warnings.

**10 — Mis-send check** (§5). With a query-param `remoteJid=A`, click chat B in the list, send a message, and confirm which contact received it. If it arrived at A, you are unpatched.

---

## 12. Appendix — verified vs unverified

**Verified by reading this repository** (file:line cited inline throughout):

- Route table, guards, and the two unguarded embed routes.
- Embed query parameters — 3 required, 12 optional colour, plus `remoteJid` — and the boot sequence.
- The `X-Frame-Options` blocker, and which nginx file actually ships in the image.
- Which `localStorage` keys the embed writes, and that `instanceToken` is written nowhere else.
- The six limitations in §3, each traced to specific guards — including the duplicate-composer defect, the pane/composer `remoteJid` divergence, and the wrong-contact send it produces (§5).
- That four of those six rows share one root cause: an empty `InstanceContext` on the embed routes.
- That the New-chat dialog navigates to the safe query-param form while chat-list clicks do not (§5).
- Absence of `VITE_`/`import.meta.env`, of any `postMessage` API, and of any URL language parameter.
- That the embed is `api`-provider only, for two independent reasons (§9).

**Taken from this repo's own deployment docs**, which state they were verified against `evolution-foundation/evolution-api` at tag `2.3.7` and the published `evoapicloud/evolution-api:v2.3.7` image (`docs/azure-setup-guide.md:840`):

- `CORS_ORIGIN=*` and the 500-on-missing-`Origin` failure mode (§4.2).
- The publicly known default `AUTHENTICATION_API_KEY` (§10.3).

Those same docs record that **no runtime testing was performed** (`docs/azure-setup-guide.md:844`).

**Not verified — confirm against your own deployment before relying on it:**

- Whether an instance token is genuinely scoped to its own instance by Evolution API (§4.4). Determines whether the embed is safe for multi-tenant use.
- Every runtime claim in §3 and §5. They are traced from source with cited guards, but were not observed against a live instance.
- Whether `POST /chat/findChats` returns `lastMessage` on every chat for your API version (§11 step 5b).
