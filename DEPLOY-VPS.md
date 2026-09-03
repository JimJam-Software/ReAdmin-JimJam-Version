# Deploying ReAdmin to a single VPS

A self-contained deployment: three application processes plus MongoDB, Redis and
S3-compatible storage, all on one machine, behind Caddy for TLS. Written for an
OVHcloud VPS running Ubuntu 24.04, but nothing here is OVH-specific — it works
on any Debian/Ubuntu box with Docker.

The alternative is [README §5](README.md#5-deploying-to-digitalocean-app-platform),
which splits the same three processes across DigitalOcean App Platform
components with managed databases. Use that if you would rather pay for managed
Mongo and Valkey than operate them; use this if you want one flat monthly bill.

Budget two to three hours. Most of it is Roblox and Discord app setup
([README §2](README.md#2-required-services)), not this document.

---

## The short version

Everything below is automated by [install.sh](install.sh). On a fresh
Ubuntu/Debian box:

```bash
git clone https://github.com/JimJam-Software/ReAdmin-JimJam-Version.git /opt/readmin
cd /opt/readmin
sudo ./install.sh
```

It checks DNS, adds swap if the box is short on RAM, configures ufw, installs
Docker, generates every secret, prompts for the credentials it cannot generate,
writes `.env`, then builds and starts the stack. It is safe to re-run — an
existing `.env` is backed up rather than overwritten, and each step checks
whether it has already been done.

Useful flags: `--no-build` (write `.env` and stop), `--skip-firewall`,
`--skip-swap`, `--yes`.

Two things it cannot do for you: **create the DNS records** (step 1 — do this
first and let it propagate) and **republish the Roblox modules** (step 12).

The rest of this document is the same process by hand, and explains why each
step is what it is. Read it if the installer fails, or if you would rather not
run a script as root without knowing what it does.

---

## What you need first

- A VPS with **at least 4 GB RAM**. `next build` on this dependency tree will
  not complete in 2 GB. See [step 2](#2-swap) if you are at 4 GB.
- A domain, with DNS you can edit.
- Every credential from [README §2](README.md#2-required-services). Have them
  in hand before you start — the build fails without the complete set.

---

## 1. DNS

Three A records pointing at the VPS's IPv4 address:

| Record | Serves |
| --- | --- |
| `panel.jimadmin.costallogic.co` | the Next.js UI |
| `api.jimadmin.costallogic.co` | the Fastify API and the in-game REST surface |
| `cdn.jimadmin.costallogic.co` | object storage |

The panel and API **must** be separate hostnames — the panel calls the API
cross-origin, and the CORS allowlist is keyed on the panel's origin.

Let these propagate before step 7. Caddy requests certificates on first boot,
and Let's Encrypt will rate-limit you for repeated failures against a name that
does not yet resolve.

While you are in the OVH panel, set reverse DNS on the IP to your panel
hostname. Not required, but it helps if you ever send mail from the box.

## 2. Swap

Skip if you have 8 GB or more. At 4 GB, the Next build needs headroom:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

The build will be slow. Runtime is comfortable once it is built.

## 3. Network firewall (ufw)

Only Caddy is exposed. The datastores talk over the internal Docker network and
publish no host ports.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

> Docker publishes ports by writing iptables rules that bypass ufw. This stack
> only publishes 80 and 443, so the two agree — but if you ever add a `ports:`
> entry to another service, it will be internet-facing regardless of what ufw
> says. Use `expose:` instead.

## 4. Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
```

Log out and back in for the group change to apply.

## 5. Clone and configure

```bash
git clone https://github.com/JimJam-Software/ReAdmin-JimJam-Version.git /opt/readmin
cd /opt/readmin
cp .env.example .env
```

Fill in `.env` completely. It is gitignored; keep it off the repo. Generate the
secrets with:

```bash
openssl rand -hex 24   # MONGO_ROOT_PASSWORD (also paste into MONGODB_URI)
openssl rand -hex 16   # CRYPTO_KEY — exactly 32 chars, see below
openssl rand -hex 32   # JSON_WEB_TOKEN_SECRET
openssl rand -hex 20   # CDN_SECRET_ACCESS_KEY
```

`CRYPTO_KEY` must be **exactly 32 characters** — it is used verbatim as an
AES-256-CBC key, so `rand -hex 16` (32 hex chars) is the right call. Changing it
later invalidates every stored OAuth token.

## 6. Fork-specific values

**These are already done on this branch** for `jimadmin.costallogic.co`:

| File | Set to |
| --- | --- |
| [src/utils/trpc.ts](src/utils/trpc.ts) | `panel.jimadmin.costallogic.co` / `api.jimadmin.costallogic.co` |
| [src/fastifyAPI/index.ts](src/fastifyAPI/index.ts) | CORS allows `https://panel.jimadmin.costallogic.co` |
| [next.config.js](next.config.js) | CSP allows all three hostnames |
| the four Roblox authorize URLs | now read `NEXT_PUBLIC_ROBLOX_CLIENT_ID` |

The Roblox client ID is no longer hardcoded in four files — set
`NEXT_PUBLIC_ROBLOX_CLIENT_ID` in `.env` (same value as `ROBLOX_CLIENT_ID`).
It is a required variable, so the build fails loudly if you forget it rather
than shipping a login button that cannot work.

Because these literals and every `NEXT_PUBLIC_*` value are compiled into the
client bundle, changing any of them needs a **rebuild**, not just a restart.

> **Still pointing at the hosted service:** roughly 70 asset URLs across `src/`
> (default avatars, logos, the upsale screenshots) are hardcoded to
> `cdn.readmin.app` and `readmin.app`, and both are still allowed in the CSP so
> they keep loading. That is `readmin.app`'s own infrastructure and it is being
> shut down — those images will break when it goes. Re-host them in your own
> bucket and drop both hosts from the CSP when you get a chance. Nothing else
> depends on them.

## 7. Build and start

```bash
docker compose build
docker compose up -d
```

The build mounts your `.env` as a BuildKit secret so `next build` can read it
without baking secrets into an image layer — `next.config.js` validates the
whole schema at build time, which is why it needs to be there at all.

Watch the first boot:

```bash
docker compose logs -f caddy panel api sync
```

Caddy issuing certificates is the slowest part. `minio-init` creates the bucket
and exits — a stopped `minio-init` is success, not a failure.

## 8. Verify

```bash
curl https://panel.jimadmin.costallogic.co/api/health   # {"success":true,"status":"ok"}
curl https://api.jimadmin.costallogic.co/               # {"success":true,"message":"ReAdmin API"}
```

Then work [README §7](README.md#7-post-deploy-checklist) — eleven checks that
prove the Roblox, Discord and storage paths actually function.

## 9. Backups

**Do this before you have data worth losing.** There are no managed snapshots
here; a nightly dump to off-box storage is the whole backup story.

```bash
sudo tee /etc/cron.daily/readmin-backup >/dev/null <<'EOF'
#!/bin/sh
set -eu
cd /opt/readmin
STAMP=$(date +%F)
docker compose exec -T mongo mongodump \
  --username "$MONGO_ROOT_USER" --password "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin --archive --gzip > "/var/backups/readmin-$STAMP.gz"
find /var/backups -name 'readmin-*.gz' -mtime +14 -delete
EOF
sudo chmod +x /etc/cron.daily/readmin-backup
```

Then copy `/var/backups` off the machine — Backblaze B2, an OVH Storage Box,
anywhere that is not this VPS. A backup on the box you are backing up is not a
backup. Restore with `mongorestore --archive --gzip` and test it once, now,
rather than discovering it does not work later.

Also back up your `.env`. Losing `CRYPTO_KEY` means every stored OAuth token is
unrecoverable.

## 10. Zen Firewall (Aikido)

Zen is already wired into all three processes — the `command:` entries in
`docker-compose.yml` preload it with
`node -r @aikidosec/firewall/instrument`. There is nothing to install; you only
need to supply a token.

With no `AIKIDO_TOKEN` the agent prints one line saying it is disabled and does
nothing, so the stack runs fine without an Aikido account.

To turn it on, set the token in `.env` and leave dry mode enabled:

```bash
AIKIDO_TOKEN=AIK_RUNTIME_your_token_here
AIKIDO_BLOCK=false
```

then `docker compose up -d`. Aikido recommend running detection-only for about
two weeks before setting `AIKIDO_BLOCK=true`, so you find false positives
without turning them into outages. `AIKIDO_DEBUG=true` makes the agent verbose.

**Do not launch these through `npm run`.** npm is itself a Node process, so a
preload reaches both it and the app, starting two agents — which double-reports
and inflates the instance count in your dashboard. The compose commands invoke
`node` directly for exactly this reason. The same applies to setting
`NODE_OPTIONS` instead of `-r`.

Verified instrumentation, by process:

| Process | Instruments |
| --- | --- |
| `api` | `fastify`, `mongodb`, `undici`, `raw-body`, `node:fs`, `node:http(s)`, `node:path` |
| `sync` | as above, minus the HTTP server |
| `panel` | `mongodb`, `node:fs`, `node:http(s)`, `node:path`, `node:vm` |

The panel does not get Fastify-level route context, but it does get `mongodb`,
so NoSQL injection protection covers the tRPC and SSR paths too.

Note that Aikido's own Next.js guide targets Next 12–14 with `output:
'standalone'`. This project is on Next 16 without standalone output, and the
`-r` preload works there as-is — no standalone migration is needed.

## 11. Billing is off, and Premium is on

`BILLING_ENABLED=false` in `.env.example`, so **you do not need a Stripe
account**. This is not a workaround: Premium cannot be purchased on a
self-hosted instance in the first place. `SUBSCRIPTIONS_CLOSED` in
`src/services/constants/Subscriptions.ts` is deliberately not host aware,
because subscriptions bill through ReAdmin's own Stripe account wherever the
code runs.

With billing off:

- **No Stripe customer is created at login.** This one matters — the call sits
  on the login path (`auth.service.ts`) and nothing upstream catches it, so a
  deployment with placeholder Stripe keys fails at login, not at boot.
- **`POST /internal/billing` returns 404**, rather than trying to verify a
  signature it has no secret for.
- **New workspaces are created with `premium.is: true`.** Premium gates real
  features (activity records, applications, distributions), and with no way to
  ever purchase it those features would be permanently unreachable.

For a workspace that already exists with Premium off:

```bash
docker compose exec mongo mongosh -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin readmin \
  --eval 'db.workspace.updateOne({groupId: "YOUR_GROUP_ID"}, {$set: {"premium.is": true}})'
```

To run *with* real billing instead, set `BILLING_ENABLED=true` and supply
`STRIPE_PUBLIC`, `STRIPE_SECRET` and `STRIPE_SIGNING_SECRET`. All three then
become required and the app refuses to start without them. Note that the
product and price IDs in `stripe.service.ts` still point at ReAdmin's Stripe
account, so you would need to replace those too.

## 12. The Roblox modules

Half of ReAdmin runs inside Roblox and is **not** deployed by anything above.
Until you republish both modules under your own account with your API hostname
baked in, the panel works, owners can download loaders, and nothing in-game
records anything.

[README §6.1](README.md#61-the-in-game-roblox-modules) has the four-step loop.
Do not skip it — this is the failure mode that looks like success.

---

## Operating it

```bash
docker compose ps                     # what is running
docker compose logs -f sync           # cron worker output
docker compose restart api            # restart one process
git pull && docker compose build && docker compose up -d   # deploy an update
```

**Never scale `sync`.** The cron jobs are not sharded — a second replica
duplicates ranking actions, DMs and distributions.

### If something is wrong

| Symptom | Cause |
| --- | --- |
| Build fails with `❌ Invalid environment variables` | A value is missing from `.env`. The error names it. |
| `Billing is enabled but STRIPE_… is not set` | Set `BILLING_ENABLED=false` (you almost certainly want this), or supply all three Stripe keys. |
| Login fails after entering Roblox credentials | `BILLING_ENABLED` is not `false` and the Stripe keys are fake. The login path creates a Stripe customer; bad keys throw and the error is not caught. |
| Build is killed with no message | Out of memory. Add swap ([step 2](#2-swap)). |
| Panel loads, every API call fails CORS | Step 6 — the panel origin is not in the allowlist. |
| Panel calls `api.readmin.app` | Step 6 — `trpc.ts` still has the hosted hostnames. |
| Images 403 or link to `minio:9000` | `CDN_ENDPOINT` must be the public `https://cdn.…` hostname. Presigned URLs are signed against it. |
| Certificates will not issue | DNS is not resolving to this box yet. Check with `dig`. |
| Mongo connection times out | `MONGODB_TLS=false` is missing — the client defaults to TLS, the container has no certificate. |
