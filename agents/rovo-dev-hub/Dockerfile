FROM node:20-alpine

WORKDIR /app

# Add non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S -G nodejs -u 1001 nodeuser

# Copy package files
COPY package.json package-lock.json* ./

# Install dependencies
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund

# Copy source and common modules
COPY src ./src
COPY ../../common ./common

# Set ownership
RUN chown -R 1001:1001 /app

USER nodeuser

EXPOSE 7010

CMD ["node", "src/index.js"]