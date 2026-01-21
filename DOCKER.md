# Docker Setup for ReverseQR


## Prerequisites

- Docker Engine 20.10+
- Docker Compose v2.0+

### Install Docker (Linux)

```bash
# Auto-install Docker and Docker Compose
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker

```
## Configuration

Copy the example environment file and customize:

```bash
cp .env.example .env
nano .env
```

## Quick Start (Localhost)

The simplest way to run ReverseQR:

```bash
# Build and run
docker compose up -d

# View logs
docker compose logs -f

# Stop
docker compose down
```

The application will be available at `http://localhost:3000`.


## Running with Nginx

For production deployments with Nginx reverse proxy:

```bash
# Start with nginx profile
docker compose --profile nginx up -d
```

This will:
- Run the Node.js application on internal port 3000
- Run Nginx on ports 80 and 443
- Proxy requests from Nginx to the application

### SSL/HTTPS Setup

#### Option 1: Use your own certificates

Place your certificates in `docker/nginx/ssl/`:
- `fullchain.pem` - Full certificate chain
- `privkey.pem` - Private key

Then edit `docker/nginx/conf.d/default.conf` to enable the HTTPS server block.

#### Option 2: Use Let's Encrypt with Certbot

1. Update the domain name in `docker/nginx/conf.d/default.conf`

2. Start with both nginx and ssl profiles:
   ```bash
   docker compose --profile nginx --profile ssl up -d
   ```

3. Generate initial certificates:
   ```bash
   docker compose run --rm certbot certonly --webroot \
     --webroot-path=/var/www/certbot \
     -d yourdomain.com \
     --email your@email.com \
     --agree-tos
   ```

4. Uncomment the HTTPS server block in `docker/nginx/conf.d/default.conf`

5. Restart nginx:
   ```bash
   docker compose --profile nginx restart nginx
   ```

## Development Mode

For development with hot-reload:

```bash
# Create a development compose override
cat > docker-compose.override.yml << 'EOF'
services:
  reverseqr:
    build:
      context: .
      dockerfile: Dockerfile.dev
    volumes:
      - ./src:/app/src
      - ./public:/app/public
    environment:
      - NODE_ENV=development
    command: npm run dev
EOF

docker compose up
```

## Useful Commands

```bash
# Rebuild after code changes
docker compose build --no-cache

# View logs
docker compose logs -f reverseqr

# Execute command in container
docker compose exec reverseqr sh

# Check container health
docker compose ps

# Remove volumes (clears uploads)
docker compose down -v

# Update to latest base images
docker compose pull
docker compose up -d --build
```

## Data Persistence

Uploaded files are **temporarily** stored in a Docker volume called `uploads_data`. 

**Important**: Files are automatically deleted after the retention period specified in your `.env` file (`FILE_RETENTION_TIME`, default: 30 minutes). The volume persists between container restarts, but the cleanup process runs regularly to remove expired files.

## Troubleshooting

### Port already in use
```bash
# Change the host port
HOST_PORT=8080 docker compose up -d
```

### Permission issues with uploads
```bash
# Fix permissions on the volume
docker compose exec reverseqr chown -R node:node /app/public/uploads
```

### Container won't start
```bash
# Check logs for errors
docker compose logs reverseqr

# Verify the build
docker compose build --no-cache
```