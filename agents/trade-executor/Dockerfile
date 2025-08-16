FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup -g 1001 -S nodejs && adduser -S -G nodejs -u 1001 nodeuser
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund || npm install --omit=dev --no-audit --no-fund
COPY src ./src
RUN chown -R 1001:1001 /app
USER 1001
EXPOSE 7005
CMD ["node", "src/index.js"]
