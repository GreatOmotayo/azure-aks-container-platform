# --- Stage 1: install production dependencies only ---
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# --- Stage 2: final runtime image ---
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production

# Patches Alpine's own OS packages to their latest available fix at
# build time - same reasoning as apps/aduke/Dockerfile.
RUN apk update && apk upgrade --no-cache

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

USER node

EXPOSE 3001

CMD ["node", "src/worker.js"]