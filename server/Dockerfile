FROM node:24-bookworm-slim

# git + ripgrep are used by the Claude Agent SDK's CLI
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ripgrep ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY tsconfig.json ./tsconfig.json
COPY src ./src

# the CLI refuses --dangerously-skip-permissions as root, so run as 'node';
# ~/.claude is pre-created so a bind-mounted credentials file lands in a
# directory the CLI can still write to (projects/, statsig/, ...)
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude
USER node
ENV HOME=/home/node

ENV NODE_ENV=production
ENV GRAMMARY_HOST=0.0.0.0

EXPOSE 8917

CMD ["npx", "tsx", "src/server.ts"]
