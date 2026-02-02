#!/bin/bash

# ReverseQR Service Setup Script
# This script lets the user choose between Docker or Node.js server setup

set -euo pipefail

# Error handling
handle_error() {
  local line=$1
  echo "" >&2
  echo -e "${RED}[ERROR] Script failed on line $line${NC}" >&2
  exit 1
}
trap 'handle_error $LINENO' ERR

# Ensure output is not buffered
export PYTHONUNBUFFERED=1

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="reverseqr"
SERVICE_FILE="/tmp/${SERVICE_NAME}.service"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper function to check if command exists
check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] Required command not found: $1${NC}" >&2
    echo "Please install $1 and try again." >&2
    exit 1
  fi
}

# Helper function to wait for port to be in use
wait_for_port() {
  local port=$1
  local timeout=${2:-30}
  local elapsed=0
  while ! nc -z 127.0.0.1 "$port" 2>/dev/null; do
    if [ $elapsed -ge $timeout ]; then
      echo -e "${RED}[ERROR] Port $port did not become available within ${timeout}s${NC}" >&2
      return 1
    fi
    sleep 1
    ((elapsed++))
  done
  return 0
}

# Helper function to check if port is already in use
check_port_free() {
  local port=$1
  if ss -ltnp 2>/dev/null | grep -q ":$port "; then
    echo -e "${YELLOW}[WARNING] Port $port appears to be in use${NC}" >&2
    ss -ltnp 2>/dev/null | grep ":$port " | head -n1 >&2
    return 1
  fi
  return 0
}

# Function to set up HTTPS with Let's Encrypt
setup_https() {
  echo ""
  echo -e "${BLUE}=== HTTPS Setup ===${NC}"
  echo ""
  echo "This will guide you through setting up HTTPS with Let's Encrypt."
  echo ""
  echo -e "${YELLOW}Prerequisites:${NC}"
  echo "  - A domain name pointing to this server's IP address"
  echo "  - Port 80 and 443 accessible from the internet"
  echo ""
  
  # Check if .env exists, if not create from example
  if [ ! -f "$SCRIPT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env.example" ]; then
      cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
      echo "[*] Created .env file from .env.example"
    fi
  fi
  
  # Read existing BASE_URL from .env
  EXISTING_URL=""
  EXISTING_DOMAIN=""
  if [ -f "$SCRIPT_DIR/.env" ]; then
    EXISTING_URL=$(grep -E "^BASE_URL=" "$SCRIPT_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    # Extract domain from URL
    EXISTING_DOMAIN=$(echo "$EXISTING_URL" | sed 's|https\?://||g' | sed 's|:.*||g' | sed 's|/.*||g')
  fi
  
  # Check if existing domain is localhost or not set
  if [ -n "$EXISTING_DOMAIN" ] && [ "$EXISTING_DOMAIN" != "localhost" ]; then
    echo "Current domain in .env: $EXISTING_DOMAIN"
    read -p "Use this domain? [Y/n]: " USE_EXISTING
    if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
      DOMAIN_NAME="$EXISTING_DOMAIN"
    else
      read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
    fi
  else
    read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
  fi
  
  if [ -z "$DOMAIN_NAME" ]; then
    echo -e "${RED}Error: Domain name is required for HTTPS setup.${NC}"
    exit 1
  fi
  
  # Sanitize domain name: remove protocol and trailing slashes
  DOMAIN_NAME=$(echo "$DOMAIN_NAME" | sed 's|https\?://||g' | sed 's|/.*||g')
  
  # Check if domain DNS is resolvable
  echo "[*] Checking DNS resolution for $DOMAIN_NAME..."
  if ! nslookup "$DOMAIN_NAME" >/dev/null 2>&1; then
    echo -e "${YELLOW}[WARNING] Could not resolve $DOMAIN_NAME via DNS${NC}"
    echo "Make sure your domain is pointing to this server's IP address."
    echo ""
  fi
  
  read -p "Enter your email address (for Let's Encrypt notifications): " EMAIL_ADDRESS
  
  if [ -z "$EMAIL_ADDRESS" ]; then
    echo -e "${RED}Error: Email address is required for Let's Encrypt.${NC}"
    exit 1
  fi
  
  echo ""
  echo -e "${YELLOW}Configuration:${NC}"
  echo "  Domain: $DOMAIN_NAME"
  echo "  Email:  $EMAIL_ADDRESS"
  echo ""
  read -p "Is this correct? [y/N]: " CONFIRM
  
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Setup cancelled."
    exit 1
  fi
  
  # Update nginx config with domain name
  NGINX_CONF="$SCRIPT_DIR/docker/nginx/conf.d/default.conf"
  
  echo ""
  echo "[*] Configuring Nginx for $DOMAIN_NAME..."
  
  # Replace yourdomain.com with actual domain in nginx config
  sed -i "s/yourdomain.com/$DOMAIN_NAME/g" "$NGINX_CONF"
  
  # Start containers with nginx and ssl profiles
  echo "[*] Starting containers..."
  docker compose --profile nginx --profile ssl up -d --build
  
  echo ""
  echo "[*] Waiting for services to be ready..."
  
  # Wait for reverseqr to be ready
  echo "[*] Waiting for reverseqr application..."
  local max_wait=60
  local elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    if docker compose logs reverseqr 2>/dev/null | grep -q "Running initial cleanup"; then
      echo -e "${GREEN}[+] ReverseQR is ready${NC}"
      break
    fi
    sleep 2
    ((elapsed+=2))
  done
  
  if [ $elapsed -ge $max_wait ]; then
    echo -e "${YELLOW}[WARNING] ReverseQR may not be ready, but continuing...${NC}"
    docker compose logs reverseqr | tail -20
  fi
  
  # Wait for nginx
  echo "[*] Waiting for nginx..."
  if ! wait_for_port 80 30; then
    echo -e "${RED}[ERROR] nginx failed to start on port 80${NC}" >&2
    docker compose logs nginx
    exit 1
  fi
  echo -e "${GREEN}[+] Services are ready${NC}"
  echo ""
  echo "[*] Obtaining SSL certificate from Let's Encrypt..."
  echo ""
  
  # Request certificate (need --profile ssl to access certbot service, --entrypoint to override default)
  docker compose --profile ssl run --rm --entrypoint "" certbot certbot certonly --webroot \
    --webroot-path=/var/www/certbot \
    -d "$DOMAIN_NAME" \
    --email "$EMAIL_ADDRESS" \
    --agree-tos \
    --non-interactive
  
  CERTBOT_EXIT=$?
  
  if [ $CERTBOT_EXIT -ne 0 ]; then
    echo ""
    echo -e "${RED}[ERROR] Failed to obtain SSL certificate.${NC}"
    echo ""
    echo "Common issues and solutions:"
    echo "  1. Domain DNS not pointing to this server:"
    echo "     nslookup $DOMAIN_NAME"
    echo ""
    echo "  2. Port 80 blocked by firewall:"
    echo "     sudo ufw allow 80/tcp"
    echo ""
    echo "  3. Another service using port 80:"
    echo "     sudo ss -ltnp | grep :80"
    echo ""
    echo "  4. View certbot logs:"
    echo "     sudo tail -50 /var/log/letsencrypt/letsencrypt.log"
    echo ""
    echo "You can retry manually with:"
    echo "  sudo certbot --nginx -d $DOMAIN_NAME"
    return 1
  fi
  
  echo ""
  echo -e "${GREEN}[+] SSL certificate obtained successfully!${NC}"
  echo ""
  
  # Enable HTTPS in nginx config
  echo "[*] Enabling HTTPS configuration..."
  
  # Uncomment HTTPS redirect
  sed -i 's|# location / {|location / {|g' "$NGINX_CONF"
  sed -i 's|#     return 301 https://\$host\$request_uri;|    return 301 https://\$host\$request_uri;|g' "$NGINX_CONF"
  sed -i 's|# }|    }|g' "$NGINX_CONF"
  
  # Comment out the HTTP proxy block (keep the acme-challenge location)
  # This is a bit tricky, so we'll use a Python script for complex sed operations
  
  # Actually, let's create a production-ready config
  cat > "$NGINX_CONF" << EOF
# ReverseQR Nginx Server Configuration (HTTPS enabled)

upstream reverseqr_backend {
    server reverseqr:3000;
    keepalive 64;
}

# HTTP server - redirect to HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    # Let's Encrypt verification
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME;

    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;

    # SSL configuration
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://reverseqr_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
EOF

  # Update BASE_URL in .env if it exists
  if [ -f "$SCRIPT_DIR/.env" ]; then
    if grep -q "BASE_URL=" "$SCRIPT_DIR/.env"; then
      sed -i "s|BASE_URL=.*|BASE_URL=https://$DOMAIN_NAME|g" "$SCRIPT_DIR/.env"
    else
      echo "BASE_URL=https://$DOMAIN_NAME" >> "$SCRIPT_DIR/.env"
    fi
    echo "[*] Updated BASE_URL in .env"
  fi
  
  # Restart nginx to apply new config
  echo "[*] Restarting Nginx with HTTPS configuration..."
  docker compose --profile nginx restart nginx
  
  # Restart reverseqr container to pick up new BASE_URL
  echo "[*] Restarting ReverseQR to apply new BASE_URL..."
  docker compose restart reverseqr
  
  echo ""
  echo -e "${GREEN}=== HTTPS Setup Complete ===${NC}"
  echo ""
  echo "ReverseQR is now running at: https://$DOMAIN_NAME"
  echo ""
  
  # Ask about automatic certificate renewal
  echo -e "${YELLOW}Certificate Renewal:${NC}"
  echo "Let's Encrypt certificates expire after 90 days."
  echo ""
  read -p "Would you like to set up automatic certificate renewal? [Y/n]: " AUTO_RENEW
  
  if [[ ! "$AUTO_RENEW" =~ ^[Nn]$ ]]; then
    # Create the renewal script
    RENEW_SCRIPT="$SCRIPT_DIR/renew-cert.sh"
    cat > "$RENEW_SCRIPT" << 'RENEWEOF'
#!/bin/bash
cd "$(dirname "$0")"
docker compose --profile ssl run --rm --entrypoint '' certbot certbot renew --quiet
docker compose --profile nginx restart nginx
RENEWEOF
    chmod +x "$RENEW_SCRIPT"
    
    # Add cron job (runs daily at 3am, certbot only renews if needed)
    CRON_JOB="0 3 * * * $RENEW_SCRIPT"
    
    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -qF "$RENEW_SCRIPT"; then
      echo "[*] Automatic renewal cron job already exists."
    else
      (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
      echo -e "${GREEN}[+] Automatic renewal enabled!${NC}"
      echo "    Cron job added: runs daily at 3:00 AM"
    fi
  else
    echo ""
    echo "To manually renew, run:"
    echo "  docker compose --profile ssl run --rm --entrypoint '' certbot certbot renew"
  fi
  echo ""
}

# Function to set up Docker
setup_docker() {
  echo ""
  echo -e "${BLUE}=== Docker Setup ===${NC}"
  echo ""
  
  # Check required system commands
  check_cmd curl
  
  # Check if Docker is installed
  if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker is not installed.${NC}"
    read -p "Would you like to install Docker now? [y/N]: " INSTALL_DOCKER
    
    if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
      echo "[*] Installing Docker..."
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker "${SUDO_USER:-$USER}"
      echo -e "${GREEN}Docker installed successfully!${NC}"
      echo -e "${YELLOW}NOTE: You may need to log out and back in for group changes to take effect.${NC}"
    else
      echo "Please install Docker manually and run this script again."
      echo "  curl -fsSL https://get.docker.com | sh"
      exit 1
    fi
  fi
  
  # Verify docker command works
  if ! docker ps >/dev/null 2>&1; then
    echo -e "${RED}[ERROR] docker command failed. You may need to add your user to docker group:${NC}" >&2
    echo "  sudo usermod -aG docker \$USER" >&2
    echo "  Then log out and back in." >&2
    exit 1
  fi
  
  # Check if docker compose is available
  if ! docker compose version &> /dev/null; then
    echo -e "${RED}Docker Compose V2 is not available.${NC}"
    echo "Please ensure you have Docker Compose V2 installed."
    exit 1
  fi
  
  # Copy .env.example if .env doesn't exist
  if [ ! -f "$SCRIPT_DIR/.env" ]; then
    if [ -f "$SCRIPT_DIR/.env.example" ]; then
      cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
      echo "[*] Created .env file from .env.example"
      echo -e "${YELLOW}Please edit .env to configure your settings.${NC}"
    fi
  fi
  
  echo ""
  echo "How would you like to run Docker?"
  echo ""
  echo -e "  ${GREEN}1)${NC} Localhost only (port 3000) - for testing"
  echo -e "  ${GREEN}2)${NC} With Nginx + HTTPS (Let's Encrypt)"
  echo ""
  read -p "Enter your choice [1/2]: " DOCKER_MODE
  
  cd "$SCRIPT_DIR"
  
  case "$DOCKER_MODE" in
    1)
      echo ""
      echo "[*] Building and starting ReverseQR..."
      docker compose up -d --build
      echo ""
      echo -e "${GREEN}=== Docker Setup Complete ===${NC}"
      echo ""
      echo "ReverseQR is now running at: http://localhost:3000"
      ;;
    2)
      setup_https
      ;;
    *)
      echo "Invalid choice, defaulting to localhost mode..."
      docker compose up -d --build
      echo ""
      echo "ReverseQR is now running at: http://localhost:3000"
      ;;
  esac
  
  echo ""
  echo "Useful commands:"
  echo "  docker compose logs -f          # View logs"
  echo "  docker compose down              # Stop"
  echo "  docker compose up -d             # Start"
  echo "  docker compose down -v           # Stop and remove data"
  echo ""
  exit 0
}

# Function to set up Node.js with systemd
setup_nodejs() {
  echo ""
  echo -e "${BLUE}=== Node.js + systemd Setup ===${NC}"
  echo ""
  
  # Ask about deployment mode
  echo "How do you want to deploy ReverseQR?"
  echo ""
  echo -e "  ${GREEN}1)${NC} Local Testing - HTTP only, localhost:3000 (development)"
  echo -e "  ${GREEN}2)${NC} Production - HTTPS with domain name"
  echo ""
  read -p "Enter your choice [1/2]: " DEPLOY_MODE
  
  case "$DEPLOY_MODE" in
    1|local|testing)
      DEPLOY_LOCAL=true
      ;;
    2|prod|production)
      DEPLOY_LOCAL=false
      ;;
    *)
      echo -e "${YELLOW}Invalid choice. Defaulting to local testing mode.${NC}"
      DEPLOY_LOCAL=true
      ;;
  esac
  
  echo ""
  if command -v docker &> /dev/null; then
    if docker compose ps --quiet 2>/dev/null | grep -q .; then
      echo "[*] Stopping Docker containers from previous setup..."
      cd "$SCRIPT_DIR"
      docker compose --profile nginx --profile ssl down 2>/dev/null || true
      docker compose down 2>/dev/null || true
      echo -e "${GREEN}[+] Docker containers stopped.${NC}"
      echo ""
    fi
  fi
  
  echo "Detecting system configuration..."

  # Get the current user
  CURRENT_USER="${SUDO_USER:-$(whoami)}"
  echo "[DEBUG] Current user: $CURRENT_USER"

  # Find the node executable
  echo "[DEBUG] Searching for node executable..."

  # When running with sudo, the PATH might not include the user's node
  # Try to find node using the original user's shell or common locations
  NODE_PATH=""

  # If running with sudo, try to get node path from the user's login shell
  if [ -n "$SUDO_USER" ]; then
    echo "[DEBUG] Running with sudo, checking original user's login shell..."
    # Use login shell (-l) to load user's .bashrc/.profile which sets up nvm/fnm/etc
    NODE_PATH=$(sudo -u "$SUDO_USER" bash -lc 'which node' 2>/dev/null) || true
    
    # Also try with -i for interactive shell
    if [ -z "$NODE_PATH" ]; then
      NODE_PATH=$(sudo -u "$SUDO_USER" bash -ic 'which node' 2>/dev/null) || true
    fi
    
    # Try to find in user's home directory (nvm, fnm, n, etc.)
    if [ -z "$NODE_PATH" ]; then
      USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
      echo "[DEBUG] Searching in user home: $USER_HOME"
      for path in "$USER_HOME"/.nvm/versions/node/*/bin/node \
                  "$USER_HOME"/.fnm/node-versions/*/installation/bin/node \
                  "$USER_HOME"/.local/share/fnm/node-versions/*/installation/bin/node \
                  "$USER_HOME"/.n/bin/node \
                  "$USER_HOME"/.local/bin/node; do
        if [ -x "$path" ] 2>/dev/null; then
          NODE_PATH="$path"
          echo "[DEBUG] Found node at: $NODE_PATH"
          break
        fi
      done
    fi
  fi

  # If not found, try the current PATH
  if [ -z "$NODE_PATH" ]; then
    echo "[DEBUG] Trying current PATH..."
    NODE_PATH=$(which node 2>/dev/null) || true
  fi

  # If still not found, try common system locations
  if [ -z "$NODE_PATH" ]; then
    echo "[DEBUG] Searching common system locations..."
    for path in /usr/bin/node /usr/local/bin/node /opt/node/bin/node /snap/bin/node; do
      if [ -x "$path" ] 2>/dev/null; then
        NODE_PATH="$path"
        echo "[DEBUG] Found node at: $NODE_PATH"
        break
      fi
    done
  fi

  if [ -z "$NODE_PATH" ]; then
    echo -e "${YELLOW}Node.js is not installed.${NC}"
    echo ""
    echo "How would you like to install Node.js?"
    echo ""
    echo -e "  ${GREEN}1)${NC} Install via NodeSource (recommended, latest LTS)"
    echo -e "  ${GREEN}2)${NC} Install via apt (may be older version)"
    echo -e "  ${GREEN}3)${NC} Skip - I'll install it manually"
    echo ""
    read -p "Enter your choice [1/2/3]: " NODE_INSTALL_CHOICE
    
    case "$NODE_INSTALL_CHOICE" in
      1)
        echo ""
        echo "[*] Installing Node.js via NodeSource..."
        # Install Node.js 20.x LTS via NodeSource
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
        NODE_PATH=$(which node 2>/dev/null) || true
        if [ -z "$NODE_PATH" ]; then
          echo -e "${RED}Error: Node.js installation failed.${NC}"
          exit 1
        fi
        echo -e "${GREEN}[+] Node.js installed successfully!${NC}"
        ;;
      2)
        echo ""
        echo "[*] Installing Node.js via apt..."
        apt-get update
        apt-get install -y nodejs npm
        NODE_PATH=$(which node 2>/dev/null) || true
        if [ -z "$NODE_PATH" ]; then
          # Debian sometimes installs /usr/bin/nodejs instead of /usr/bin/node
          if [ -x /usr/bin/nodejs ]; then
            echo "[*] Creating symlink /usr/bin/node -> /usr/bin/nodejs"
            ln -sf /usr/bin/nodejs /usr/bin/node
            NODE_PATH=/usr/bin/node
          else
            echo -e "${RED}Error: Node.js installation failed.${NC}"
            exit 1
          fi
        fi
        echo -e "${GREEN}[+] Node.js installed successfully!${NC}"
        ;;
      *)
        echo ""
        echo "Please install Node.js manually and run this script again."
        echo ""
        echo "Recommended methods:"
        echo "  - NodeSource: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -"
        echo "  - nvm: https://github.com/nvm-sh/nvm"
        echo "  - fnm: https://github.com/Schniz/fnm"
        exit 1
        ;;
    esac
  fi

  # Allow manual override via environment variable
  if [ -n "${NODE_PATH_OVERRIDE:-}" ]; then
    NODE_PATH="$NODE_PATH_OVERRIDE"
    echo "[DEBUG] Using NODE_PATH override: $NODE_PATH"
  fi

  echo ""
  echo "Installation directory: $SCRIPT_DIR"
  echo "User: $CURRENT_USER"
  echo "Node executable: $NODE_PATH"
  echo ""

  echo "[DEBUG] Generating service file at $SERVICE_FILE"
  cat > "$SERVICE_FILE" << EOF
# ReverseQR systemd service file
# Generated by setup-service.sh on $(date)
# Installation directory: $SCRIPT_DIR

[Unit]
Description=ReverseQR - Secure File Sharing Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$SCRIPT_DIR

# Environment variables (loaded from .env file)
EnvironmentFile=$SCRIPT_DIR/.env

# Start command
ExecStart=$NODE_PATH $SCRIPT_DIR/src/server.js

# Restart policy
Restart=on-failure
RestartSec=10

# Process management
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$SERVICE_NAME

# Security settings
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  echo "[DEBUG] Service file generated successfully at $SERVICE_FILE"
  echo ""

  # Check if running with sudo
  if [[ $EUID -ne 0 ]]; then
    echo "This script needs sudo to install the service file."
    echo ""
    echo "To install the service, run:"
    echo "  sudo bash $0"
    echo ""
    echo "Or manually install with:"
    echo "  sudo cp $SERVICE_FILE /etc/systemd/system/${SERVICE_NAME}.service"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo systemctl enable ${SERVICE_NAME}"
    echo "  sudo systemctl start ${SERVICE_NAME}"
    exit 0
  fi

  # Install npm dependencies
  echo "[*] Installing npm dependencies..."
  cd "$SCRIPT_DIR"
  
  # Find npm in the same directory as node
  NODE_DIR=$(dirname "$NODE_PATH")
  NPM_PATH="${NODE_DIR}/npm"
  
  if [ ! -x "$NPM_PATH" ]; then
    # Try common locations
    if command -v npm >/dev/null 2>&1; then
      NPM_PATH=$(which npm)
    else
      echo -e "${RED}[ERROR] npm not found at $NPM_PATH or in PATH${NC}" >&2
      echo "npm should be installed alongside node." >&2
      exit 1
    fi
  fi
  
  echo "[DEBUG] Using npm at: $NPM_PATH"
  
  if ! sudo -u "$CURRENT_USER" "$NPM_PATH" install --omit=dev; then
    echo -e "${RED}[ERROR] Failed to install npm dependencies.${NC}" >&2
    echo "Troubleshooting tips:" >&2
    echo "  - Check npm logs: cat ~/.npm/_logs/*.log" >&2
    echo "  - Try clearing cache: $NPM_PATH cache clean --force" >&2
    echo "  - Ensure disk space: df -h" >&2
    exit 1
  fi
  echo -e "${GREEN}[+] Dependencies installed successfully!${NC}"
  
  # Verify node_modules ownership
  if [ -d "$SCRIPT_DIR/node_modules" ]; then
    chown -R "$CURRENT_USER:$CURRENT_USER" "$SCRIPT_DIR/node_modules"
  fi
  echo ""

  # Install the service file
  echo "[*] Installing service file to /etc/systemd/system/${SERVICE_NAME}.service..."
  cp -v "$SERVICE_FILE" "/etc/systemd/system/${SERVICE_NAME}.service"

  # Reload systemd daemon
  echo "[*] Reloading systemd daemon..."
  systemctl daemon-reload

  # Enable the service
  echo "[*] Enabling ${SERVICE_NAME} service to start on boot..."
  systemctl enable "${SERVICE_NAME}"

  # Start the service
  echo "[*] Starting ${SERVICE_NAME} service..."
  systemctl start "${SERVICE_NAME}"

  echo ""
  echo -e "${GREEN}=== Node.js Service Installed ===${NC}"
  echo ""
  
  if [ "$DEPLOY_LOCAL" = true ]; then
    echo "✓ Local testing setup complete!"
    echo ""
    echo "You can access ReverseQR at:"
    echo -e "  ${GREEN}http://localhost:3000${NC}"
    echo ""
    echo "Service management commands:"
    echo "  sudo systemctl status ${SERVICE_NAME}       # Check status"
    echo "  sudo systemctl restart ${SERVICE_NAME}      # Restart service"
    echo "  sudo journalctl -u ${SERVICE_NAME} -f       # View live logs"
    echo ""
    echo -e "${YELLOW}Note: This is HTTP only, suitable for local testing.${NC}"
    echo "To add HTTPS and nginx later, run this script again."
    echo ""
  else
    # Production setup - ask about HTTPS
    echo "✓ Node.js service installed!"
    echo ""
    echo "The server is running on port 3000 (internal, behind nginx)."
    echo ""
    read -p "Would you like to set up HTTPS with nginx and Let's Encrypt now? [Y/n]: " SETUP_HTTPS
    
    if [[ ! "$SETUP_HTTPS" =~ ^[Nn]$ ]]; then
      setup_nodejs_https
    else
      echo ""
      echo "You can access ReverseQR at: http://localhost:3000"
      echo ""
      echo -e "${YELLOW}Note: HTTPS is required for file transfers to work over the internet.${NC}"
      echo "Run this script again to set up HTTPS later."
      echo ""
    fi
  fi
  
  echo "Service management commands:"
  echo "  sudo systemctl status ${SERVICE_NAME}       # Check status"
  echo "  sudo systemctl start ${SERVICE_NAME}        # Start service"
  echo "  sudo systemctl stop ${SERVICE_NAME}         # Stop service"
  echo "  sudo systemctl restart ${SERVICE_NAME}      # Restart service"
  echo "  sudo systemctl disable ${SERVICE_NAME}      # Disable auto-start"
  echo "  sudo journalctl -u ${SERVICE_NAME} -f       # View live logs"
  echo ""
}

# Function to set up HTTPS for Node.js with system nginx
setup_nodejs_https() {
  echo ""
  echo -e "${BLUE}=== HTTPS Setup (nginx + Let's Encrypt) ===${NC}"
  echo ""
  
  # Check/read domain from .env
  EXISTING_URL=""
  EXISTING_DOMAIN=""
  if [ -f "$SCRIPT_DIR/.env" ]; then
    EXISTING_URL=$(grep -E "^BASE_URL=" "$SCRIPT_DIR/.env" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    EXISTING_DOMAIN=$(echo "$EXISTING_URL" | sed 's|https\?://||g' | sed 's|:.*||g' | sed 's|/.*||g')
  fi
  
  if [ -n "$EXISTING_DOMAIN" ] && [ "$EXISTING_DOMAIN" != "localhost" ]; then
    echo "Current domain in .env: $EXISTING_DOMAIN"
    read -p "Use this domain? [Y/n]: " USE_EXISTING
    if [[ ! "$USE_EXISTING" =~ ^[Nn]$ ]]; then
      DOMAIN_NAME="$EXISTING_DOMAIN"
    else
      read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
    fi
  else
    read -p "Enter your domain name (e.g., example.com): " DOMAIN_NAME
  fi
  
  if [ -z "$DOMAIN_NAME" ]; then
    echo -e "${RED}Error: Domain name is required for HTTPS setup.${NC}"
    return 1
  fi
  
  # Sanitize domain name
  DOMAIN_NAME=$(echo "$DOMAIN_NAME" | sed 's|https\?://||g' | sed 's|/.*||g')
  
  read -p "Enter your email address (for Let's Encrypt notifications): " EMAIL_ADDRESS
  
  if [ -z "$EMAIL_ADDRESS" ]; then
    echo -e "${RED}Error: Email address is required for Let's Encrypt.${NC}"
    return 1
  fi
  
  echo ""
  echo "[*] Installing nginx and certbot..."
  apt-get update
  apt-get install -y nginx certbot python3-certbot-nginx
  
  echo ""
  echo "[*] Configuring nginx..."
  
  # Create nginx config for the site
  cat > /etc/nginx/sites-available/reverseqr << EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_buffering off;
        proxy_read_timeout 86400;
    }
}
EOF

  # Enable the site
  ln -sf /etc/nginx/sites-available/reverseqr /etc/nginx/sites-enabled/
  
  # Remove default site if it exists
  rm -f /etc/nginx/sites-enabled/default
  
  # Test nginx config
  nginx -t
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: nginx configuration test failed.${NC}"
    return 1
  fi
  
  # Restart nginx
  systemctl restart nginx
  systemctl enable nginx
  
  # Wait for nginx to be ready
  echo "[*] Waiting for nginx to start..."
  if ! wait_for_port 80 30; then
    echo -e "${RED}[ERROR] nginx failed to start on port 80${NC}" >&2
    systemctl status nginx >&2
    return 1
  fi
  
  echo ""
  echo "[*] Obtaining SSL certificate from Let's Encrypt..."
  certbot --nginx -d "$DOMAIN_NAME" --email "$EMAIL_ADDRESS" --agree-tos --non-interactive --redirect
  
  CERTBOT_EXIT=$?
  
  if [ $CERTBOT_EXIT -ne 0 ]; then
    echo ""
    echo -e "${RED}Error: Failed to obtain SSL certificate.${NC}"
    echo ""
    echo "Common issues:"
    echo "  - Domain DNS not pointing to this server"
    echo "  - Port 80 blocked by firewall"
    echo ""
    echo "You can retry manually with:"
    echo "  sudo certbot --nginx -d $DOMAIN_NAME"
    return 1
  fi
  
  # Update BASE_URL in .env
  if [ -f "$SCRIPT_DIR/.env" ]; then
    if grep -q "BASE_URL=" "$SCRIPT_DIR/.env"; then
      sed -i "s|BASE_URL=.*|BASE_URL=https://$DOMAIN_NAME|g" "$SCRIPT_DIR/.env"
    else
      echo "BASE_URL=https://$DOMAIN_NAME" >> "$SCRIPT_DIR/.env"
    fi
    echo "[*] Updated BASE_URL in .env"
  fi
  
  # Restart the Node.js service to pick up new BASE_URL
  systemctl restart reverseqr
  
  echo ""
  echo -e "${GREEN}=== HTTPS Setup Complete ===${NC}"
  echo ""
  echo "ReverseQR is now running at: https://$DOMAIN_NAME"
  echo ""
  echo -e "${YELLOW}Certificate Renewal:${NC}"
  echo "Certbot automatically renews certificates via systemd timer."
  echo "To check: sudo systemctl status certbot.timer"
  echo ""
}

# Main menu
echo -e "${BLUE}=== ReverseQR Setup ===${NC}"
echo ""
echo "Choose how to run ReverseQR:"
echo ""
echo -e "  ${GREEN}1)${NC} Docker (recommended) - Containerized, easy setup"
echo -e "  ${GREEN}2)${NC} Node.js with systemd - Traditional server setup"
echo ""
read -p "Enter your choice [1/2]: " SETUP_CHOICE

case "$SETUP_CHOICE" in
  1|docker|Docker|DOCKER)
    setup_docker
    ;;
  2|node|Node|nodejs|systemd)
    setup_nodejs
    ;;
  *)
    echo -e "${YELLOW}Invalid choice. Please run the script again and choose 1 or 2.${NC}"
    exit 1
    ;;
esac
