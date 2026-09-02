# --- Stage 1: install production dependencies only ---
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev

# --- Stage 2: final runtime image ---
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production

# Only the installed node_modules and app source make it into this final
# image - no npm cache, no dev dependencies, nothing from the build stage
# that isn't strictly needed to run the app.
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY public ./public

# node:20-alpine ships a built-in, non-root 'node' user (UID 1000) -
# running as it rather than root is the default posture, matching the
# least-privilege pattern used everywhere else in this project.
USER node

EXPOSE 3000

CMD ["node", "src/server.js"]
