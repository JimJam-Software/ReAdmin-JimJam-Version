# ReAdmin — single image, three processes.
#
# The panel, API and sync worker all build from this one image and differ only
# in their run command (see docker-compose.yml). Next is not built in
# `standalone` mode, so the runtime needs the full node_modules tree and we
# ship a single-stage image rather than trying to prune it.
FROM node:24-bookworm-slim

# Chromium for puppeteer-core, plus the native libraries listed in ./Aptfile.
# images.service.ts probes /usr/bin/chromium-browser before falling back to
# @sparticuz/chromium; Debian installs the binary as /usr/bin/chromium, so the
# symlink is what makes the fast path hit.
RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium \
        ca-certificates fonts-liberation \
        libgtk2.0-0 libgtk-3-0 libnotify-dev libnss3 libxss1 libasound2 \
        libxtst6 xauth xvfb libgbm-dev libnspr4 \
    && ln -sf /usr/bin/chromium /usr/bin/chromium-browser \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# devDependencies are required: `fastify:build` runs tsc.
ENV NPM_CONFIG_PRODUCTION=false
COPY package.json package-lock.json* ./
RUN npm install

COPY . .

# next.config.js requires src/services/env.js at the top, so the *complete*
# server environment must be present during `next build`, not just at runtime.
# Next loads .env into process.env before evaluating next.config.js, so we
# mount the real .env as a BuildKit secret: it is readable during the build but
# is never written into an image layer.
#
# NEXT_PUBLIC_* values are inlined into the client bundle here regardless —
# that is inherent to Next, and is why the panel must be rebuilt (not just
# restarted) when one of those changes.
RUN --mount=type=secret,id=dotenv,target=/app/.env \
    npm run build && npm run fastify:build

ENV NODE_ENV=production
CMD ["npm", "run", "start"]
