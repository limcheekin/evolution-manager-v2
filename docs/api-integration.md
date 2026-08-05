# API Integration Guide — The Backend Contract Evolution Manager v2 Speaks

**Audience:** engineers integrating a third-party application with the Evolution API instance behind an Evolution Manager v2 deployment — instance provisioning, sending messages, receiving events.

**Scope and ownership, stated up front:** everything in this document is **Evolution API's** surface, not this repository's. Evolution Manager v2 is a static SPA with no backend of its own; it is a *client* of this API. What follows is the complete set of endpoints, bodies, and conventions **reconstructed from the manager's own call sites** in `src/lib/queries/**` — a verified subset of upstream's API, not the whole of it.

For embedding this app's chat UI in your page, see **[`app-integration.md`](./app-integration.md)**.

**Version basis:** this repo at `package.json` version `2.0.0`, paired with `evoapicloud/evolution-api:v2.3.7` (the tag pinned in `docker-compose.yml`).

Claims traced to a file:line in this repo describe **what the manager sends**. Claims marked `[upstream]` describe how the API is expected to answer — confirm those against <https://doc.evolution-api.com> for your API version. Upstream's authorization rules are upstream's; this repo cannot prove them.

> **Maintainers:** each guide is deliberately self-contained, so five blocks are duplicated verbatim in [`app-integration.md`](./app-integration.md) — the topology table (§2), the `CORS_ORIGIN=*` explanation (§2), the default-`AUTHENTICATION_API_KEY` warning (§7), smoke-test steps 1–2 and 4 (§8), and the provenance paragraph in the appendix (§9). **Change one, change both.**

---

## Table of Contents

1. [Scope: what this covers, and what it does not](#1-scope-what-this-covers-and-what-it-does-not)
2. [Base URL, origins, and CORS](#2-base-url-origins-and-cors)
3. [Authentication model](#3-authentication-model)
4. [Endpoint contract](#4-endpoint-contract)
5. [Receiving events](#5-receiving-events)
6. [Provider variants (`api` vs `go`)](#6-provider-variants-api-vs-go)
7. [Security checklist](#7-security-checklist)
8. [Smoke test](#8-smoke-test)
9. [Appendix — verified vs unverified](#9-appendix--verified-vs-unverified)

---

## 1. Scope: what this covers, and what it does not

If your requirement is "our product needs to send and receive WhatsApp messages", **this is the document you want.** Talk to Evolution API directly; you do not need the manager in the request path at all — it is a browser UI, not a gateway.

| Your requirement | Section |
|---|---|
| Provision / connect / delete instances | [§4.2](#42-instance-lifecycle) |
| Send text, media, audio | [§4.3](#43-messaging) |
| Read chats and message history | [§4.4](#44-chats-and-messages) |
| Configure event delivery (webhook / websocket / RabbitMQ / SQS) | [§4.5](#45-event-delivery-configuration) |
| Configure chatbot integrations (OpenAI, Dify, n8n, Typebot, …) | [§4.6](#46-chatbot-integrations) |
| Receive inbound messages server-side | [§5.1](#51-webhook-recommended-for-server-to-server) |
| Receive events in a browser | [§5.2](#52-socketio-websocket) — read the warning first |
| Embed the manager's chat UI | [`app-integration.md`](./app-integration.md) |

**Not covered here:** endpoints the manager never calls. Upstream has more surface than this document — group management, profile updates, label CRUD, presence, and more. Absence from these tables means "the manager does not use it", not "it does not exist".

---

## 2. Base URL, origins, and CORS

All paths in §4 are relative to the API base URL. `{instance}` is the instance **name**; `{id}` is the instance **UUID** — the two are not interchangeable.

The manager and the API are **separate origins** in every deployment in this repo:

| Service | Compose host port | Azure VM layout (`docs/azure-vm-setup-guide.md:23-40`) |
|---|---|---|
| `evolution-api` | `8080` | `:443` behind Caddy → `https://<host>` |
| `evolution-manager` (SPA) | `3000` → container `80` | `:8443` behind Caddy → `https://<host>:8443` |
| `postgres`, `redis` | not published | internal only |

Different port means different origin, so any browser-side caller needs CORS.

**`CORS_ORIGIN` must stay `*`.** Per `docs/azure-setup-guide.md:706-712`, verified against upstream `evolution-api` at tag `2.3.7`: an explicit allowlist returns **HTTP 500 for every request that carries no `Origin` header**. Upstream's origin callback does `ORIGIN.indexOf(requestOrigin)`; `requestOrigin` is `undefined` for non-browser callers, `indexOf(undefined) === -1`, so it calls back with an error. That breaks curl, server-to-server integrations, n8n, Postman, and HTTP health probes — i.e. exactly the callers a backend integration uses. `*` combined with credentials is safe here only because `cors@2.8.5` reflects the request origin instead of emitting a literal `*`. It is still open CORS: restrict at your ingress or WAF instead. `[upstream, per repo docs]`

This repo's own scripts set `CORS_ORIGIN=*` (`docs/azure-deploy.sh:324`, `docs/azure-vm-deploy.sh:427`).

---

## 3. Authentication model

There is one credential type at the HTTP level: the **`apikey` request header**. Two *scopes* of value flow through it.

| Scope | Value | Grants |
|---|---|---|
| **Global** | `AUTHENTICATION_API_KEY` | instance creation, deletion, full enumeration — admin over the whole gateway |
| **Instance** | `Instance.token` for one instance | per-instance operations |

No cookies, no CSRF token, no bearer scheme — a plain header on every request.

### 3.1 The two axios clients (and the trap in them)

`src/lib/queries/api.ts` defines two instances, both taking `baseURL` from `localStorage["apiUrl"]` and both with a 30 s timeout:

| Client | Fallback key source | `localStorage` key | Typical use |
|---|---|---|---|
| `api` | `TOKEN_ID.INSTANCE_TOKEN` (`:17`) | `instanceToken` | per-instance routes |
| `apiGlobal` | `TOKEN_ID.TOKEN` (`:42`) | `token` | global/admin routes |

Both only apply the fallback when the call site did not already set the header: `if (!config.headers.has("apikey"))` (`:16, :41`). Axios header lookup is case-insensitive, so a call site passing `apiKey:` also suppresses the fallback — several files do exactly that (e.g. `src/lib/queries/webhook/fetchWebhook.ts:18`). Harmless over HTTP, where header names are case-insensitive.

**The subtlety integrators get wrong:** `saveToken()` at login writes **only** `token`, never `instanceToken` (`src/lib/queries/token.ts:31-45`). `instanceToken` is written in exactly one place — `EmbedInstanceContext` (`src/contexts/EmbedInstanceContext.tsx:43`), i.e. only in the iframe embed flow.

So `api`'s fallback is **empty in the normal logged-in manager flow**, and that matters for a lot of call sites. Counting them across `src/lib/queries/**`:

| Client | Call sites | Pass `apikey` explicitly | Rely on the interceptor fallback |
|---|---|---|---|
| `api` | 90 | 68 | **22** |
| `apiGlobal` | 17 | 9 | 8 — harmless *in the manager*, because login writes `token`. Irrelevant to you: your client has no fallback. |

The 22 `api` call sites with no explicit header split into two groups:

- **Reached from the embed** — `/chat/findChats`, `/chat/findMessages` (`src/lib/queries/chat/findChat.ts:15`, `src/lib/queries/chat/findChats.ts:14`, `src/lib/queries/chat/findMessages.ts:15`). Here `instanceToken` *is* populated, from the embed URL, so the fallback supplies it and the request is authenticated.
- **Reached from the logged-in manager** — the other 19. `/instance/restart/{instance}` and `/instance/logout/{instance}` (`src/lib/queries/instance/manageInstance.tsx:16, 21`); `DELETE /openai/creds/{credsId}/{instance}` (`src/lib/queries/openai/manageOpenai.tsx:23`); and a ragged subset of the bot grammar — `update` + `delete` for dify, evoai, flowise, n8n; `delete` only for evolutionBot and typebot; `fetch` + `fetchSessions` for dify, evoai, n8n. Here `instanceToken` is empty, so **these requests go out with no `apikey` header at all**.

  The subset is ragged rather than systematic, which is itself the tell: it is an oversight repeated unevenly, not a deliberate contract.

That second group is a manager-side bug, not a contract you can copy. It also means the "Key" column in §4 records **which client the manager used**, i.e. the scope *intended* — not proof that the route was ever exercised with an instance token.

**For your own integration this is moot: always set the `apikey` header explicitly on every request.** Never rely on a fallback, and do not read the manager's omissions as evidence that a route needs no key.

### 3.2 `localStorage` keys (manager-side state, for reference)

From `src/lib/queries/token.ts:6-18`, on the **manager's** origin:

| Key | Written by | Purpose |
|---|---|---|
| `apiUrl` | login (`:33-36`), embed (`src/contexts/EmbedInstanceContext.tsx:42`) | axios `baseURL`, socket.io URL. Trailing slash stripped. |
| `token` | login | global API key → `apiGlobal` |
| `instanceToken` | embed only | instance token → `api` |
| `version` | login, from `GET /` | part of the `api`-provider auth gate |
| `clientName` | login, from `GET /` | display |
| `provider` | login | `"api"` \| `"go"` |
| `facebookAppId`, `facebookConfigId`, `facebookUserToken` | login, from `POST /verify-creds` | Cloud API onboarding |
| `instanceId`, `instanceName` | declared in the enum, not written by `saveToken` | — |
| `accessToken` | embed, temporarily, restored on unmount (`src/pages/instance/EmbedChatMessage/index.tsx:123-127, 206-211`) | legacy; read by nothing in this codebase |
| `i18nextLng` | language toggle | UI language |

### 3.3 Login handshake (what a manager session actually does)

`src/pages/Login/index.tsx:49-124`, `api` provider:

1. `GET {url}/license/status` with `apikey`. If not `active` → `GET /license/register?redirect_uri=…`, save credentials, redirect to `register_url`. Unreachable `/license/*` is caught and skipped, for older API builds without licensing (`:78-82`).
2. `GET {url}/` — must return `version`, else "invalid server" (`src/lib/queries/auth/verifyServer.ts:14`).
3. `POST {url}/verify-creds` with `apikey` — validates the key; harvests Facebook fields (`src/lib/queries/auth/verifyCreds.ts:13`).
4. `saveToken({version, clientName, url, token, provider:"api"})`.

`go` provider: single `GET {url}/server/ok`, expecting `status === "ok"` (`src/lib/queries/auth/verifyGoServer.ts:11-15`).

License endpoints (`src/lib/queries/license/license.ts`): `GET /license/status`, `GET /license/register?redirect_uri=`, `GET /license/activate?code=`, 15 s timeout, `apikey` optional.

You do not need this handshake for a backend integration — go straight to §4 with a key.

---

## 4. Endpoint contract

The complete set of endpoints this repo calls, with the exact path, method, key scope, and body shape the manager sends.

### 4.1 Server / auth

| Method | Path | Key | Source |
|---|---|---|---|
| GET | `/` | none | `src/lib/queries/auth/verifyServer.ts:14` |
| POST | `/verify-creds` | global | `src/lib/queries/auth/verifyCreds.ts:13` |
| GET | `/license/status` | global (optional) | `src/lib/queries/license/license.ts:35` |
| GET | `/license/register?redirect_uri=` | global (optional) | `src/lib/queries/license/license.ts:45` |
| GET | `/license/activate?code=` | global (optional) | `src/lib/queries/license/license.ts:56` |

### 4.2 Instance lifecycle

| Method | Path | Key | Notes |
|---|---|---|---|
| GET | `/instance/fetchInstances` | global | list; `Instance[]` |
| GET | `/instance/fetchInstances?instanceId=` | global | manager takes `[0]` if array (`src/lib/queries/instance/fetchInstance.ts:16-22`) |
| GET | `/instance/fetchInstances?instanceName=` | instance | used by the embed (`src/contexts/EmbedInstanceContext.tsx:45`) |
| POST | `/instance/create` | global | body = `NewInstance` |
| GET | `/instance/connect/{instance}?number=` | instance | returns QR base64 / pairing code |
| POST | `/instance/restart/{instance}` | instance | |
| DELETE | `/instance/logout/{instance}` | instance | unlinks WhatsApp, keeps the instance |
| DELETE | `/instance/delete/{instance}` | global | destroys the instance |
| GET | `/settings/find/{instance}` | instance | returns `Settings` |
| POST | `/settings/set/{instance}` | instance | body = `Settings` |

**A caveat on the "Key" column, here and in §§4.3–4.6.** It records which axios client the manager uses — `api` (instance scope) or `apiGlobal` (global scope) — i.e. *the scope intended*, not proof of what reaches the wire. Per §3.1, 22 of the 90 `api` call sites send no explicit `apikey` and fall back to `localStorage["instanceToken"]`, which only the embed ever writes; `restart` and `logout` are in that group (`src/lib/queries/instance/manageInstance.tsx:16, 21`). Always set the header explicitly in your own client.

```ts
// src/types/evolution.types.ts:17-24
type NewInstance = {
  instanceName: string;
  integration: string;      // e.g. "WHATSAPP-BAILEYS"
  qrcode?: boolean;
  token?: string | null;    // your chosen instance token
  number?: string | null;
  businessId?: string | null;
};

// :1-13
type Settings = {
  rejectCall: boolean;  msgCall?: string;
  groupsIgnore: boolean; alwaysOnline: boolean;
  readMessages: boolean; readStatus: boolean;
  syncFullHistory: boolean;
};

// :26-45 — response shape
type Instance = {
  id: string; name: string; connectionStatus: string;   // "open" | "close" | …
  ownerJid: string; profileName: string; profilePicUrl: string;
  integration: string; number: string; businessId: string;
  token: string;                                        // per-instance API key
  clientName: string; createdAt: string; updatedAt: string;
  Setting: Settings;
  _count?: { Message?: number; Contact?: number; Chat?: number };
};
```

Provisioning an instance with a token you control:

```bash
curl -s -X POST "$API_URL/instance/create" \
  -H "apikey: $AUTHENTICATION_API_KEY" \
  -H "content-type: application/json" \
  -d '{"instanceName":"partner-acme","integration":"WHATSAPP-BAILEYS","qrcode":true,"token":"<your-32+-char-secret>"}'
```

### 4.3 Messaging

| Method | Path | Key | Body |
|---|---|---|---|
| POST | `/message/sendText/{instance}` | instance | `{ number, text, options? }` |
| POST | `/message/sendMedia/{instance}` | instance | **flat**: `{ number, mediatype, mimetype, caption?, media, fileName? }` |
| POST | `/message/sendWhatsAppAudio/{instance}` | instance | `{ number, audioMessage: { audio }, options? }` |

Shape details, all from `src/lib/queries/chat/sendMessage.ts`:

- **Media is flattened before sending.** The internal `SendMedia` type nests under `mediaMessage`, but the request body is flat — `:37-46`, commented *"Send as flat structure as required by the newer API"*. Send flat.
- **Audio is not flattened** — it keeps `audioMessage.audio` (`:63-71`). The asymmetry is real; do not normalize one to the other.
- `media` and `audio` are **base64 payloads with the `data:` URI prefix stripped** (`src/pages/instance/EmbedChatMessage/InputMessage/index.tsx:293-300`).
- `number` accepts a full JID; the manager passes `remoteJid` straight through (`src/pages/instance/EmbedChatMessage/InputMessage/index.tsx:268`).
- `options` differs per endpoint: `{ delay?, presence?, linkPreview? }` for text (`src/types/evolution.types.ts:86-95`), `{ delay?, presence? }` for media and audio (`:96-119`). **The manager never populates it** — `sendText` and `sendMedia` drop it entirely, and `sendAudio` forwards a `data.options` that its only caller never sets (`src/pages/instance/EmbedChatMessage/InputMessage/index.tsx:357-367`). Treat these fields as upstream-documented, not repo-verified. `[upstream]`

```bash
curl -s -X POST "$API_URL/message/sendText/partner-acme" \
  -H "apikey: $INSTANCE_TOKEN" -H "content-type: application/json" \
  -d '{"number":"5511999998888@s.whatsapp.net","text":"hello"}'
```

### 4.4 Chats and messages

| Method | Path | Key | Body | Response handling |
|---|---|---|---|---|
| POST | `/chat/findChats/{instance}` | instance | `{ where: {} }` | array of `Chat` |
| POST | `/chat/findChats/{instance}` | instance | `{ where: { remoteJid } }` | manager takes `[0]` (`src/lib/queries/chat/findChat.ts:18-21`) |
| POST | `/chat/findMessages/{instance}` | instance | `{ where: { key: { remoteJid } } }` | manager reads `data.messages.records`, else the raw body (`src/lib/queries/chat/findMessages.ts:18-21`) |

```ts
// src/types/evolution.types.ts:51-78
type Chat = {
  id: string; pushName: string; remoteJid: string;
  labels: string[] | null; profilePicUrl: string;
  createdAt: string; updatedAt: string; instanceId: string;
};

type Key = { id: string; fromMe: boolean; remoteJid: string; participant?: string };
type Message = {
  id: string; key: Key; pushName: string;
  messageType: string;   // "conversation", "imageMessage", …
  message: any;          // Baileys message content
  messageTimestamp: string; instanceId: string; source: string;
};
```

Two things to handle defensively:

- **`findMessages` returns two shapes** — paginated (`messages.records`) and a bare array. The manager branches on which it got (`src/lib/queries/chat/findMessages.ts:18-21`). Handle both.
- **`lastMessage` is not in the `Chat` type** but the manager's embed sorts on `chat.lastMessage.messageTimestamp` anyway. If your API version omits it, that sort throws. Relevant only to the embed — see [`app-integration.md` §3](./app-integration.md#3-before-you-build-known-limitations).

### 4.5 Event-delivery configuration

| Integration | Find | Set | Set body wrapper |
|---|---|---|---|
| Webhook | GET `/webhook/find/{instance}` | POST `/webhook/set/{instance}` | `{ webhook: {...} }` |
| WebSocket | GET `/websocket/find/{instance}` | POST `/websocket/set/{instance}` | `{ websocket: {...} }` |
| RabbitMQ | GET `/rabbitmq/find/{instance}` | POST `/rabbitmq/set/{instance}` | `{ rabbitmq: {...} }` |
| SQS | GET `/sqs/find/{instance}` | POST `/sqs/set/{instance}` | `{ sqs: {...} }` |
| Proxy | GET `/proxy/find/{instance}` | POST `/proxy/set/{instance}` | bare object |

**Field-name asymmetry on webhook — this will bite you.** Request body uses `base64` / `byEvents`; the response returns `webhookBase64` / `webhookByEvents` (`src/lib/queries/webhook/types.ts:4-7`). Do not round-trip a GET result straight into a POST.

```ts
// request shapes (src/types/evolution.types.ts:335-370)
type Webhook   = { enabled: boolean; url: string; events: string[]; base64: boolean; byEvents: boolean };
type Websocket = { enabled: boolean; events: string[] };
type Rabbitmq  = { enabled: boolean; events: string[] };
type Sqs       = { enabled: boolean; events: string[] };
type Proxy     = { enabled: boolean; host: string; port: string; protocol: string; username?: string; password?: string };
```

Valid `events[]` values: §5.1.

### 4.6 Chatbot integrations

Seven integrations share one URL grammar. `{kind}` ∈ `openai`, `dify`, `n8n`, `evoai`, `evolutionBot`, `flowise`, `typebot`:

| Method | Path | Purpose |
|---|---|---|
| GET | `/{kind}/find/{instance}` | list bots |
| GET | `/{kind}/fetch/{botId}/{instance}` | one bot |
| POST | `/{kind}/create/{instance}` | create |
| PUT | `/{kind}/update/{botId}/{instance}` | update |
| DELETE | `/{kind}/delete/{botId}/{instance}` | delete |
| GET | `/{kind}/fetchSettings/{instance}` | instance-level defaults |
| POST | `/{kind}/settings/{instance}` | set defaults |
| GET | `/{kind}/fetchSessions/{botId}/{instance}` | active sessions |
| POST | `/{kind}/changeStatus/{instance}` | body `{ remoteJid, status }` |

Extras outside the grammar:

| Method | Path | Purpose |
|---|---|---|
| GET | `/openai/creds/{instance}` | list OpenAI credentials |
| POST | `/openai/creds/{instance}` | add credential |
| DELETE | `/openai/creds/{credsId}/{instance}` | remove credential |
| GET | `/openai/getModels/{instance}` | list models |
| GET | `/chatwoot/find/{instance}` · POST `/chatwoot/set/{instance}` | Chatwoot (find/set, not the bot grammar) |

Per-integration config shapes are in `src/types/evolution.types.ts:134-334` and `:393-470`. Common trigger/session fields across all of them: `triggerType`, `triggerOperator`, `triggerValue`, `expire`, `keywordFinish`, `delayMessage`, `unknownMessage`, `listeningFromMe`, `stopBotFromMe`, `keepOpen`, `debounceTime`, `ignoreJids`, `splitMessages`, `timePerChar`.

Session objects returned by `fetchSessions` (`src/types/evolution.types.ts:122-132`): `{ id?, remoteJid, pushName, sessionId, status, awaitUser, createdAt, updatedAt, botId }`.

---

## 5. Receiving events

Two naming conventions coexist. **Getting this wrong is the most common event-integration bug.**

| Where | Convention | Example |
|---|---|---|
| `events[]` in webhook/websocket/rabbitmq/sqs **configuration** | `UPPER_SNAKE_CASE` | `MESSAGES_UPSERT` |
| socket.io **event names on the wire** | `lowercase.dotted` | `messages.upsert` |

### 5.1 Webhook (recommended for server-to-server)

```bash
curl -s -X POST "$API_URL/webhook/set/partner-acme" \
  -H "apikey: <instance-token>" -H "content-type: application/json" \
  -d '{"webhook":{
        "enabled": true,
        "url": "https://partner.example.com/hooks/evolution",
        "events": ["MESSAGES_UPSERT","MESSAGES_UPDATE","SEND_MESSAGE","CONNECTION_UPDATE","QRCODE_UPDATED"],
        "base64": false,
        "byEvents": false
      }}'
```

- `byEvents: true` appends a per-event path segment to your URL `[upstream]` — verify the exact suffix format against your API version before routing on it.
- `base64: true` inlines media as base64 in the payload. Expect large bodies.
- Remember the response field renaming (§4.5).

The 26 valid `events[]` values for the `api` provider (`src/pages/instance/Webhook/index.tsx:36-64`, identical list in `src/pages/instance/Websocket/index.tsx:82-109`, `Rabbitmq/index.tsx`, `Sqs/index.tsx`):

```
APPLICATION_STARTUP   QRCODE_UPDATED        MESSAGES_SET
MESSAGES_UPSERT       MESSAGES_UPDATE       MESSAGES_DELETE
SEND_MESSAGE          CONTACTS_SET          CONTACTS_UPSERT
CONTACTS_UPDATE       PRESENCE_UPDATE       CHATS_SET
CHATS_UPSERT          CHATS_UPDATE          CHATS_DELETE
GROUPS_UPSERT         GROUP_UPDATE          GROUP_PARTICIPANTS_UPDATE
CONNECTION_UPDATE     REMOVE_INSTANCE       LOGOUT_INSTANCE
LABELS_EDIT           LABELS_ASSOCIATION    CALL
TYPEBOT_START         TYPEBOT_CHANGE_STATUS
```

The `go` provider uses a different, shorter vocabulary (`src/pages/instance/Webhook/index.tsx:34`):

```
ALL  MESSAGE  SEND_MESSAGE  READ_RECEIPT  PRESENCE  HISTORY_SYNC
CHAT_PRESENCE  CALL  CONNECTION  QRCODE  LABEL  CONTACT  GROUP  NEWSLETTER
```

### 5.2 socket.io (WebSocket)

**WebSocket delivery is disabled by default upstream, and enabling it safely on a public endpoint is not possible with the current handshake.** Per `docs/azure-setup-guide.md:643`, verified against `evolution-api` 2.3.7: `WEBSOCKET_ENABLED=false` by default, and making it work for a browser also requires `WEBSOCKET_ALLOWED_HOSTS=*`, because the browser cannot attach an `apikey` header to a WebSocket handshake and behind a reverse proxy the socket peer address is never `127.0.0.1`. That combination **disables websocket authentication entirely**, exposing the whole event stream unauthenticated. `[upstream, per repo docs]`

> **Security decision, stated plainly:** on a publicly reachable API, enabling browser WebSockets as described above makes every event for every instance readable by anyone who can reach the port. Prefer webhooks (§5.1) for anything crossing a trust boundary. If you enable it anyway, put the socket endpoint behind network-level restrictions (VPN, mTLS at the proxy, IP allowlist) — the application layer will not be checking.

How the manager connects (`src/services/websocket/socket.ts:21-27`):

```js
io(serverUrl, {                        // serverUrl = localStorage["apiUrl"], root — no namespace
  transports: ["websocket", "polling"],
  autoConnect: false,                  // .connect() called explicitly
  reconnection: true,
  reconnectionAttempts: 5,
  reconnectionDelay: 1000,
  timeout: 20000,
});
```

- **Root connection, no per-instance namespace or path.** Sockets are pooled per URL in a module-level `Map` (`:4, :16-19`).
- **No auth is sent** — no `auth`, no `query`, no `extraHeaders`. Consistent with the warning above.
- Because it is a shared global stream, **every consumer must filter by instance itself.** The manager does exactly this: `if (data.instance !== activeInstance.name) return` (`src/pages/instance/EmbedChatMessage/index.tsx:132`, `src/pages/instance/Chat/index.tsx:64`, `src/pages/instance/Chat/messages.tsx:459`).

Events the manager subscribes to, and the payload shape it relies on:

| Event | Used in | Payload fields read |
|---|---|---|
| `messages.upsert` | Chat, embed | `data.instance`, `data.data.key.remoteJid`, `data.data.key.id`, `data.data.pushName`, `data.data.key.profilePictureUrl` |
| `send.message` | Chat, embed | same |
| `messages.update` | Chat, embed | same envelope |

So the envelope is `{ instance: string, data: <Message-like> }`.

```js
import { io } from "socket.io-client";

const socket = io("https://api.example.com", { transports: ["websocket", "polling"] });
socket.on("messages.upsert", (evt) => {
  if (evt.instance !== "partner-acme") return;     // mandatory: shared global stream
  console.log(evt.data.key.remoteJid, evt.data.message);
});
```

Enable delivery per instance first:

```bash
curl -s -X POST "$API_URL/websocket/set/partner-acme" \
  -H "apikey: <instance-token>" -H "content-type: application/json" \
  -d '{"websocket":{"enabled":true,"events":["MESSAGES_UPSERT","MESSAGES_UPDATE","SEND_MESSAGE","CONNECTION_UPDATE"]}}'
```

### 5.3 RabbitMQ / SQS

Same `{enabled, events[]}` config shape, same `UPPER_SNAKE` vocabulary (§4.5, §5.1). Broker connection details (URI, queue/topic naming, credentials) are Evolution API server-side configuration — nothing in this repo configures or reveals them. `[upstream]`

---

## 6. Provider variants (`api` vs `go`)

The manager can target two different backends. `localStorage["provider"]` selects (`src/lib/queries/token.ts:61-64`), default `"api"`; the selector is present but **hidden** in the login form (`src/pages/Login/index.tsx:154-170`). Everything in §§4–5 above describes the **`api`** provider.

Feature support (`src/lib/provider/features.ts:5-22`) — `ProtectedRoute` redirects to `/manager/` for unsupported features:

| Feature | `api` | `go` |
|---|---|---|
| dashboard, settings, proxy, webhook | ✅ | ✅ |
| chat, websocket, rabbitmq, sqs | ✅ | ❌ |
| openai, dify, typebot, chatwoot, n8n, evoai, evolutionBot, flowise | ✅ | ❌ |

`go` endpoints differ substantially (`src/lib/queries/go/**`) — different paths, a `{data, message}` envelope, and the instance token in `apikey` rather than a path segment:

| Purpose | `api` | `go` |
|---|---|---|
| list instances | GET `/instance/fetchInstances` | GET `/instance/all` → `{data: GoInstance[]}` |
| one instance | GET `/instance/fetchInstances?instanceId=` | GET `/instance/info/{id}` → `{data: GoInstance}` |
| connect | GET `/instance/connect/{name}` | POST `/instance/connect` + GET `/instance/qr` |
| pair by number | GET `/instance/connect/{name}?number=` | POST `/instance/pair` `{subscribe:[], phone:"+…"}` |
| restart | POST `/instance/restart/{name}` | POST `/instance/reconnect` |
| logout | DELETE `/instance/logout/{name}` | DELETE `/instance/logout` |
| delete | DELETE `/instance/delete/{name}` | DELETE `/instance/delete/{id}` |
| settings | GET/POST `/settings/{find,set}/{name}` | GET/PUT `/instance/{id}/advanced-settings` |
| send text | POST `/message/sendText/{name}` | POST `/send/text` `{number, text}` |
| proxy | GET/POST `/proxy/{find,set}/{name}` | POST/DELETE `/instance/proxy/{id}` |
| webhook | GET/POST `/webhook/{find,set}/{name}` | POST `/instance/connect` (webhook is part of the connect payload) |
| health | GET `/` (needs `version`) | GET `/server/ok` (needs `status === "ok"`) |

`go` field names differ too (`snake_case`, booleans instead of status strings) and are normalized by `toInstance()` (`src/lib/queries/go/instance/mapper.ts:29-53`): `connected → connectionStatus: "open"|"close"`, `jid → ownerJid`, `ignoreGroups → groupsIgnore`, `ignoreStatus → readStatus` (negated), and `integration` is hardcoded `"EVOLUTION_GO"`.

**If you target `go`:** the iframe embed will not work at all — see [`app-integration.md` §9](./app-integration.md#9-provider-requirement-api-not-go).

---

## 7. Security checklist

1. **`AUTHENTICATION_API_KEY` is admin-scoped.** It authorizes `/instance/create`, `/instance/delete`, and full enumeration. Never expose it to a browser, never put it in a URL, never ship it to a partner. Use per-instance tokens for anything delegated.
2. **The published image has a publicly known default key.** `AUTHENTICATION_API_KEY` defaults to `429683C4C977415CAAFCCE10F7D57E11`, which is in the public upstream repo. Omit it and your gateway is world-writable (`docs/azure-setup-guide.md:704`; `.env.example` warns about exactly this). Set it explicitly.
3. **Instance tokens are readable via `GET /instance/fetchInstances` with the global key** — `Instance.token` is returned in plaintext (`src/types/evolution.types.ts:32`). Treat any global-key leak as a compromise of every instance token, and rotate all of them.
4. **Enabling browser WebSockets disables websocket auth entirely** (§5.2). Webhooks for anything crossing a trust boundary; network-level restrictions if you enable sockets anyway.
5. **`CORS_ORIGIN=*` is open CORS.** Required to avoid upstream's 500-on-missing-`Origin` bug (§2), so restrict at the ingress/WAF layer instead of at the app.
6. **Verify instance-token scoping yourself** before relying on it for tenant isolation. Upstream behaviour, not verifiable from this repo: `[upstream]`

   ```bash
   # Expect a failure / empty result, NOT another tenant's instance
   curl -si "$API_URL/instance/fetchInstances?instanceName=some-other-instance" \
     -H "apikey: <instance-token>"
   ```
7. **No cookies, no CSRF token** — auth is a header on every request. Standard bearer-token hygiene applies: TLS everywhere, no tokens in query strings, no tokens in logs.
8. **Webhook endpoints you expose are unauthenticated by default.** Nothing in the `Webhook` config shape (§4.5) carries a secret or signature field, so your receiver cannot verify the sender from the payload alone. Protect it with a hard-to-guess path, an IP allowlist, or mTLS at your ingress.
9. **Postgres and Redis must stay unpublished.** `docker-compose.yml` deliberately does not publish either — Postgres because only `evolution-api` needs it over the internal bridge (`docker-compose.yml:55-57`), Redis because **no auth is configured**, so an exposed port is an unauthenticated Redis holding instance/session state (`docker-compose.yml:64-66`).

Embed-specific items (token in URL, iframe headers, `localStorage` collisions): [`app-integration.md` §10](./app-integration.md#10-security-checklist).

---

## 8. Smoke test

Run in order. Each step fails loudly on its own before the next depends on it.

```bash
export API_URL="https://api.example.com"
export GLOBAL_KEY="…"                 # AUTHENTICATION_API_KEY
export INSTANCE="partner-acme"
```

**1 — API alive and reporting a version**

```bash
curl -s "$API_URL/" | jq '{version, clientName}'      # version must be non-null
```

**2 — Global key enforced**

```bash
curl -so /dev/null -w '%{http_code}\n' "$API_URL/instance/fetchInstances"                            # expect 401
curl -so /dev/null -w '%{http_code}\n' -H "apikey: $GLOBAL_KEY" "$API_URL/instance/fetchInstances"   # expect 200
```

**3 — Non-browser callers are not 500ing** (the `CORS_ORIGIN` trap, §2)

```bash
# No Origin header at all — must NOT be 500
curl -so /dev/null -w '%{http_code}\n' -H "apikey: $GLOBAL_KEY" "$API_URL/instance/fetchInstances"
# With an Origin — allow-origin must come back
curl -si -X OPTIONS "$API_URL/instance/fetchInstances" \
  -H "Origin: https://partner.example.com" -H "Access-Control-Request-Method: GET" \
  -H "Access-Control-Request-Headers: apikey" | grep -i access-control-allow-origin
```

**4 — Instance exists and is connected**

```bash
curl -s "$API_URL/instance/fetchInstances?instanceName=$INSTANCE" \
  -H "apikey: $GLOBAL_KEY" | jq '.[0] | {name, connectionStatus, token}'
# connectionStatus must be "open"; capture token as INSTANCE_TOKEN
export INSTANCE_TOKEN="…"
```

**5 — Instance token works on per-instance routes**

```bash
curl -s "$API_URL/settings/find/$INSTANCE" -H "apikey: $INSTANCE_TOKEN" | jq
curl -s -X POST "$API_URL/chat/findChats/$INSTANCE" -H "apikey: $INSTANCE_TOKEN" \
  -H "content-type: application/json" -d '{"where":{}}' | jq 'length'
```

**6 — Instance token is scoped** (§7.6 — expect failure or empty, not another instance)

```bash
curl -si "$API_URL/instance/fetchInstances?instanceName=some-other-instance" \
  -H "apikey: $INSTANCE_TOKEN" | head -1
```

**7 — Outbound send works**

```bash
curl -s -X POST "$API_URL/message/sendText/$INSTANCE" \
  -H "apikey: $INSTANCE_TOKEN" -H "content-type: application/json" \
  -d '{"number":"5511999998888@s.whatsapp.net","text":"integration smoke test"}' | jq '.key.id'
```

**8 — Message history readable, both response shapes handled**

```bash
curl -s -X POST "$API_URL/chat/findMessages/$INSTANCE" -H "apikey: $INSTANCE_TOKEN" \
  -H "content-type: application/json" \
  -d '{"where":{"key":{"remoteJid":"5511999998888@s.whatsapp.net"}}}' \
  | jq 'if type == "array" then "bare array" else (.messages.records | length | tostring) + " records" end'
```

**9 — Webhook configured and round-trip understood**

```bash
curl -s -X POST "$API_URL/webhook/set/$INSTANCE" \
  -H "apikey: $INSTANCE_TOKEN" -H "content-type: application/json" \
  -d '{"webhook":{"enabled":true,"url":"https://partner.example.com/hooks/evolution",
       "events":["MESSAGES_UPSERT","SEND_MESSAGE","CONNECTION_UPDATE"],"base64":false,"byEvents":false}}'

curl -s "$API_URL/webhook/find/$INSTANCE" -H "apikey: $INSTANCE_TOKEN" | jq
# note: response uses webhookBase64 / webhookByEvents (§4.5) — do not POST this object back verbatim
```

**10 — Webhook actually fires.** Send yourself a WhatsApp message on the connected number and confirm a `MESSAGES_UPSERT` POST arrives at your receiver. This is the only step that proves end-to-end inbound delivery.

---

## 9. Appendix — verified vs unverified

**Verified by reading this repository** (file:line cited inline throughout):

- Every Evolution API path, method, body wrapper, and key scope the manager sends (§4) — extracted exhaustively from `src/lib/queries/**`.
- The `api` / `apiGlobal` split, the `localStorage` key inventory, and which code writes each key.
- The call-site audit behind §3.1: 22 of 90 `api` calls and 8 of 17 `apiGlobal` calls send no explicit `apikey`, so the "Key" column in §4 is intent, not observed wire behaviour. Counted mechanically across `src/lib/queries/**`.
- That `options` is never populated on any send path, so its field lists in §4.3 come from the local TypeScript types rather than from observed requests.
- The webhook request/response field renaming; the media-flat / audio-nested asymmetry.
- The two response shapes `findMessages` returns.
- The 26-value `api` and 14-value `go` event vocabularies; the `UPPER_SNAKE` vs `lowercase.dotted` split.
- socket.io connection options: root URL, no namespace, no auth sent, pooled per URL, consumers filter by `data.instance`.
- Provider feature matrix and the `api` ↔ `go` endpoint divergence.
- Absence of any signature/secret field in the webhook config shape (§7.8).

**Taken from this repo's own deployment docs**, which state they were verified against `evolution-foundation/evolution-api` at tag `2.3.7` and the published `evoapicloud/evolution-api:v2.3.7` image (`docs/azure-setup-guide.md:840`):

- `CORS_ORIGIN=*` and the 500-on-missing-`Origin` failure mode (§2).
- `WEBSOCKET_ENABLED=false` default and the `WEBSOCKET_ALLOWED_HOSTS=*` auth-bypass consequence (§5.2).
- The publicly known default `AUTHENTICATION_API_KEY` (§7.2).

Those same docs record that **no runtime testing was performed** (`docs/azure-setup-guide.md:844`).

**Not verified — confirm against your own deployment before relying on it:**

- Whether an instance token is genuinely scoped to its own instance (§7.6). Decides whether per-instance tokens are a real tenant boundary.
- Whether upstream accepts the global key on per-instance routes.
- The exact URL suffix `byEvents: true` appends (§5.1).
- RabbitMQ / SQS broker topology, queue naming, and credentials (§5.3).
- Rate limits, pagination parameters, and error-body shapes on any endpoint in §4 — the manager surfaces only HTTP status (4xx are not retried; 3 failures raise a generic toast: `src/lib/queries/react-query.ts:11-33`).
- Endpoints upstream exposes but the manager never calls — absent from §4 by construction, not by evidence they do not exist.
