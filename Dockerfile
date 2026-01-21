# Dockerfile for ReverseQR
FROM node:20-alpine

# Create app directory
WORKDIR /app

# Install dependencies first (better caching)
COPY package*.json ./
RUN npm install --omit=dev

# Copy application source
COPY src/ ./src/
COPY public/ ./public/

# Create uploads directory
RUN mkdir -p /app/public/uploads

# Set environment variables (can be overridden by docker-compose.yml or .env)
ENV NODE_ENV=production
ENV PORT=3000


# Run the application
CMD ["node", "src/server.js"]
