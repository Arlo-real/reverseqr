# Dockerfile for ReverseQR
FROM node:20-alpine

# Create app directory
WORKDIR /app

# Install dependencies first (better caching)
COPY package*.json ./
RUN npm ci --only=production

# Copy application source
COPY src/ ./src/
COPY public/ ./public/

# Create uploads directory
RUN mkdir -p /app/public/uploads

# Set environment variables
ENV NODE_ENV=production
ENV PORT=3000

# Expose the port
EXPOSE 3000

# Run the application
CMD ["node", "src/server.js"]
