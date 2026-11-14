# Hosted demo: one container, one public port (PORT, default 8080). services/dev-api/src/host.ts deploys the
# contracts once at boot, then gives each user a private Anvil + dev-api (local Anvil keys only).
# Real app (optional): set FUJI_ADMIN_PRIVATE_KEY, SESSION_SECRET, PRIVY_APP_ID, PRIVY_APP_SECRET as platform
# secrets and the host also runs the shared Fuji server behind /api/app (never baked into the image).
# NODE_ENV is deliberately not set: the per-user dev-api runs DEV_MODE=true (a sandbox by design) and refuses
# NODE_ENV=production. Do not add it here or in the platform's variables.
# Official Foundry release for linux/amd64, checked against the sha256 published on the GitHub release.
# Its own stage, so the 118 MB tarball never lands in the final image; only forge and anvil are copied.
FROM --platform=linux/amd64 node:26.8.2-slim AS foundry
ARG FOUNDRY_VERSION=1.9.0
ARG FOUNDRY_SHA256=8d17599b42e3139f1a9c171be3798c4ed8e743ae17b84cc3435e57bf2a51ae99
ADD https://github.com/foundry-rs/foundry/releases/download/v${FOUNDRY_VERSION}/foundry_v${FOUNDRY_VERSION}_linux_amd64.tar.gz /tmp/foundry.tgz
RUN echo "${FOUNDRY_SHA256}  /tmp/foundry.tgz" | sha256sum -c - \
  && mkdir -p /out && tar -xzf /tmp/foundry.tgz -C /out \
  && /out/forge --version | grep -q "${FOUNDRY_VERSION}" \
  && /out/anvil --version | grep -q "${FOUNDRY_VERSION}"

FROM --platform=linux/amd64 node:26.8.2-slim AS base
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
# forge runs the boot deploy; anvil runs every chain.
COPY --from=foundry /out/forge /out/anvil /root/.foundry/bin/
ENV PATH=/root/.foundry/bin:$PATH
RUN npm install -g pnpm@12.18.0
WORKDIR /app

# Build: contracts (contracts/lib is plain directories here, no .git), ABIs, and the web app.
# One stage with the full install: the boot deploy runs scripts/deploy.ts and forge, so nothing is pruned.
FROM base
COPY . .
RUN pnpm install --frozen-lockfile
RUN cd contracts && forge build
# Public by design: the Privy app id for the web build (an ARG is in the environment of RUN); empty = tutorial only.
ARG VITE_PRIVY_APP_ID=""
RUN pnpm --filter @kuber/shared build && pnpm --filter @kuber/web build
EXPOSE 8080
# node as process 1 so the platform's stop signal reaches the host and it can stop its children.
CMD ["node", "services/dev-api/src/host.ts"]
