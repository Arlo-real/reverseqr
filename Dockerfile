# Dockerfile for ReverseQR
FROM node:20-alpine

# Create app directory
WORKDIR /app

# Create non-root user with fixed UID/GID
# Node official image may include 'node' user, but we ensure proper IDs
RUN addgroup -g 1000 node && \
    adduser -D -u 1000 -G node node || true

# Install dependencies first (better caching)
COPY package*.json ./
RUN npm install --omit=dev

# Copy application source
COPY src/ ./src/
COPY public/ ./public/

# Create uploads directory (outside public/ so it is never served statically) and fix ownership
RUN mkdir -p /app/uploads && \
    chown -R node:node /app && \
    chmod 755 /app/uploads

# Set environment variables (can be overridden by docker-compose.yml or .env)
ENV NODE_ENV=production
ENV PORT=3000
# Bind to all interfaces inside the container; the container network namespace
# (and the published-port config) controls external exposure, not this bind.
ENV HOST=0.0.0.0

# Switch to non-root user
USER node

# Run the application
CMD ["node", "src/server.js"]
