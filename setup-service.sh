#!/bin/bash

# ReverseQR Service Setup Script
# This script lets the user choose between Docker or Node.js server setup

set -e

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

# Function to set up Docker
setup_docker() {
  echo ""
  echo -e "${BLUE}=== Docker Setup ===${NC}"
  echo ""
  
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
  echo -e "  ${GREEN}1)${NC} Localhost only (port 3000)"
  echo -e "  ${GREEN}2)${NC} With Nginx reverse proxy (ports 80/443)"
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
      echo ""
      echo "[*] Building and starting ReverseQR with Nginx..."
      docker compose --profile nginx up -d --build
      echo ""
      echo -e "${GREEN}=== Docker Setup Complete ===${NC}"
      echo ""
      echo "ReverseQR is now running at: http://localhost"
      echo ""
      echo -e "${YELLOW}For HTTPS, see DOCKER.md for SSL certificate setup.${NC}"
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
    echo -e "${RED}ERROR: node executable not found${NC}"
    echo ""
    echo "Please run: which node"
    echo "Then set NODE_PATH manually and re-run:"
    echo "  sudo NODE_PATH=/path/to/node ./setup-service.sh"
    exit 1
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

  # Generate the service file
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
  echo -e "${GREEN}=== Installation Complete ===${NC}"
  echo ""
  echo "Service management commands:"
  echo "  sudo systemctl status ${SERVICE_NAME}       # Check status"
  echo "  sudo systemctl start ${SERVICE_NAME}        # Start service"
  echo "  sudo systemctl stop ${SERVICE_NAME}         # Stop service"
  echo "  sudo systemctl restart ${SERVICE_NAME}      # Restart service"
  echo "  sudo systemctl disable ${SERVICE_NAME}      # Disable auto-start"
  echo "  sudo journalctl -u ${SERVICE_NAME} -f       # View live logs"
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
