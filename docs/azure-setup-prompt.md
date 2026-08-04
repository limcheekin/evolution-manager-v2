Read docs/azure-setup-guide.md in full before doing anything. It is the
authoritative spec for this task and docs/azure-deploy.sh implements it. Don't improvise
around either: section 13 documents traps where a plausible-looking change produces a
deployment that reports healthy while silently dropping WhatsApp messages.

Goal: deploy this repo's docker-compose.yml stack to Azure Container Apps in
southeastasia with Azure Database for PostgreSQL Flexible Server, following that guide.

Before touching Azure:
1. Add .env.deploy, .secrets.deploy, evolution-api.yaml and evolution-manager.yaml to
   .gitignore. The two YAML files get rendered with the Postgres password and the
   Evolution API key in plaintext. Confirm `git status` is clean of them afterwards.
2. Run the section 2 preflight checks. Stop and tell me if az CLI is older than 2.80.0,
   if I'm not logged in, or if southeastasia is absent from the Microsoft.App
   managedEnvironments region list. Don't work around any of those.

Then, pausing at each gate:
3. `bash docs/azure-deploy.sh init`. Show me the generated POSTGRES_PASSWORD and
   AUTHENTICATION_API_KEY and wait for me to confirm I've saved them before continuing.
   They aren't recoverable from Azure afterwards.
4. Run phases one at a time — `bash docs/azure-deploy.sh 1` through `6` — not `all`. After
   each phase run that phase's verification commands from the guide and report the
   result. If a check fails, stop and diagnose rather than continuing. Note that phase
   2 creates a billable PostgreSQL server.
5. `bash docs/azure-deploy.sh verify` and report all 8 checks individually.
6. Print the URLs plus the manager login instructions from section 11.

Constraints:
- Never change the API app's minReplicas/maxReplicas from 1/1 (guide 13.2).
- If you change any container's cpu/memory, the sum across both containers must still
  equal a legal Consumption-plan pair (guide 7.2).
- Don't set an explicit CORS_ORIGIN allowlist (guide 13.4).
- Don't run the section 14 Azure Files migration unless I ask.
- Don't commit or push anything.

For phase 8, generate qr.png and hand it to me — I'll scan it.