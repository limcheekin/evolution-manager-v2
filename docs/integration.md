# Third-Party Integration — Start Here

This guide was split in two, because "integrate with Evolution Manager v2" means two genuinely different jobs with two different owners.

**Evolution Manager v2 is a static single-page application with no backend of its own.** Every call it makes goes from the end user's browser straight to Evolution API. That fact is what splits the work:

| | What it is | Who owns the contract | Read |
|---|---|---|---|
| **A. App integration** | Mount `/manager/embed-chat` in an iframe. The only surface *this repository* exposes to third parties, and the only route not behind an auth guard. | **This repo** | **[`app-integration.md`](./app-integration.md)** |
| **B. API integration** | Provision instances, send messages, read chats, receive events. | **Evolution API (upstream)** — reconstructed here from the manager's own call sites | **[`api-integration.md`](./api-integration.md)** |

## Which one do you need?

- **"Our product needs to send and receive WhatsApp messages."** → **B**. Talk to Evolution API directly; the manager is a browser UI, not a gateway, and does not belong in your request path.
- **"We want the manager's rendered chat pane inside our page."** → **A**. Read its §3 (known limitations) before you commit — message history does not load as shipped, and an unpatched multi-chat embed can send to the wrong contact.
- **"We want to drop a user into the full manager UI, already logged in."** → not supportable cross-origin. See [`app-integration.md` §8](./app-integration.md#8-deep-linking-into-the-authenticated-manager) for why, and the alternatives.
- **Both** → start with B (it is the substrate), then A.

## Maintaining the pair

Each guide is self-contained, so five blocks are duplicated verbatim between them: the deployment topology table, the `CORS_ORIGIN=*` explanation, the default-`AUTHENTICATION_API_KEY` warning, smoke-test steps 1–2 and 4, and the appendix provenance paragraph. **Change one, change both.** Each file repeats this note at the top with its own section numbers.

## Related deployment docs

- [`azure-setup-guide.md`](./azure-setup-guide.md) — Azure Container Apps deployment; source of the upstream-verified `CORS_ORIGIN`, `WEBSOCKET_ENABLED`, and default-API-key findings both guides cite.
- [`azure-vm-setup-guide.md`](./azure-vm-setup-guide.md) — single-VM deployment; source of the two-port topology both guides assume.
