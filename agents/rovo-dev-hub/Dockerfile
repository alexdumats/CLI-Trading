FROM node:20-alpine

WORKDIR /app

# Add non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S -G nodejs -u 1001 nodeuser

# Copy package files
COPY ./agents/rovo-dev-hub/package.json ./agents/rovo-dev-hub/package-lock.json* ./

# Install dependencies
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund

# Copy source and common modules
COPY ./agents/rovo-dev-hub/src ./src
COPY ./common ./common

# Set ownership
RUN chown -R 1001:1001 /app

USER nodeuser

EXPOSE 7010

CMD ["node", "src/index.js"]