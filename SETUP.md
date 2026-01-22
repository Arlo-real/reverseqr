# Production Setup Guide


## Prerequisites
- Ubuntu/Debian server with sudo access
- Domain name pointing to your server

> [!TIP]
> You can skip all this by using setup-script.sh

> [!NOTE]
> If you want to use docker, please see the docker.md file


## 1. Configure Environment

Install node.js and npm. Get it [here](https://nodejs.org/en/download)

```bash
cd /path/to/reverseqr
cp .env.example .env
```

Edit `.env` and set:
- `BASE_URL=https://yourdomain.com` (important for generated links)
- `PORT=3000` (internal port, Nginx will proxy to this)
- Adjust `MAX_FILE_SIZE_BYTES`, `SESSION_TIMEOUT_MS`, etc. as needed

## 2. Install Dependencies

```bash
npm install
```

## 3. Configure Nginx

First, create the nginx site configuration at `/etc/nginx/sites-available/reverseqr`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name yourdomain.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
```

**Note**: Replace `:3000` with the actual port opened on the server

Remove the default nginx site, enable the site and restart nginx:
```bash
sudo rm /etc/nginx/sites-enabled/default
sudo ln -s /etc/nginx/sites-available/reverseqr /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

## 4. Set Up SSL Certificate

Install certbot and obtain a certificate using the nginx plugin:

```bash
sudo apt update
sudo apt install certbot python3-certbot-nginx -y
sudo certbot --nginx -d yourdomain.com
```

Certbot will automatically:
- Obtain the SSL certificate
- Configure nginx to use HTTPS
- Set up HTTP to HTTPS redirect

Your certificates will be stored at `/etc/letsencrypt/live/yourdomain.com/`

## 5. Auto-Renew SSL Certificates

```bash
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer
```

## 6. Add to autostart using systemd

First, find your node executable path:
```bash
which node
```

Create a systemd service file at `/etc/systemd/system/reverseqr.service`:

```ini
[Unit]
Description=ReverseQR - Secure File & Text Sharing
After=network.target

[Service]
Type=simple
User=yourusername
WorkingDirectory=/path/to/reverseqr
ExecStart=/path/to/node src/server.js
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**Important**: Replace the following:
- `/path/to/reverseqr` - Your installation directory (e.g., `/home/username/reverseqr`)
- `/path/to/node` - Output from `which node` (e.g., `/home/username/.nvm/versions/node/v20.18.0/bin/node`)
- `yourusername` - Your Linux username (run `whoami` to check)


Enable and start the service:
```bash
sudo systemctl daemon-reload
sudo systemctl enable reverseqr
sudo systemctl start reverseqr
```

### Useful commands:

Check if it's running:
```bash
sudo systemctl status reverseqr
```

Restart the service:
```bash
sudo systemctl restart reverseqr
```

View live logs:
```bash
sudo journalctl -u reverseqr -f
```

Disable auto-start:
```bash
sudo systemctl disable reverseqr
```




## Troubleshooting

### 502 Bad Gateway
This means nginx can't reach the Node.js server:
```bash
# Check if the service is running
sudo systemctl status reverseqr

# Check server logs for errors
sudo journalctl -u reverseqr -n 50

# Make sure the default nginx site is removed
sudo rm /etc/nginx/sites-enabled/default

# Test if the server responds locally
curl http://localhost:3000 # replace with your port

# Verify PORT in .env matches nginx proxy_pass
cat .env | grep PORT
```

### Common issues
- **SSL errors**: Verify certificate paths in nginx config
- **File uploads fail**: Check permissions on `public/uploads/` directory
- **QR code not working**: Ensure `BASE_URL` in `.env` matches your domain
- **Service won't start**: Check node path with `which node` and update the service file
