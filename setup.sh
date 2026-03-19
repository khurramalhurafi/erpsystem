#!/bin/bash
# =============================================================
#  ERP Server Setup Script — DigitalOcean Ubuntu 22.04
#  Stack: Python/FastAPI + React + PostgreSQL + Nginx + GitHub
#  Run as root: bash setup.sh
# =============================================================

set -e  # Stop on any error

# ─────────────────────────────────────────────
# CONFIGURATION — Edit these before running
# ─────────────────────────────────────────────
GITHUB_REPO="https://github.com/YOUR_USERNAME/YOUR_REPO.git"  # Your GitHub repo URL
APP_USER="erpuser"                    # Linux user that will run the app
APP_DIR="/var/www/erp"                # Where your app will live
DB_NAME="erp_db"                      # PostgreSQL database name
DB_USER="erp_user"                    # PostgreSQL username
DB_PASS="CHANGE_THIS_STRONG_PASSWORD" # PostgreSQL password — CHANGE THIS
WEBHOOK_SECRET="CHANGE_THIS_SECRET"   # GitHub webhook secret — CHANGE THIS
BACKEND_PORT=8000                     # Port FastAPI will run on

# ─────────────────────────────────────────────
# COLORS FOR OUTPUT
# ─────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "======================================================"
echo "  ERP Server Setup — Starting..."
echo "======================================================"
echo ""

# ─────────────────────────────────────────────
# 1. SYSTEM UPDATE
# ─────────────────────────────────────────────
info "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git unzip build-essential \
    software-properties-common ca-certificates \
    gnupg lsb-release ufw

info "System updated."

# ─────────────────────────────────────────────
# 2. CREATE APP USER (non-root for security)
# ─────────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
    info "Creating app user: $APP_USER"
    adduser --disabled-password --gecos "" $APP_USER
    usermod -aG sudo $APP_USER
else
    info "App user $APP_USER already exists."
fi

# ─────────────────────────────────────────────
# 3. INSTALL PYTHON 3.11
# ─────────────────────────────────────────────
info "Installing Python 3.11..."
add-apt-repository ppa:deadsnakes/ppa -y -q
apt-get update -qq
apt-get install -y -qq python3.11 python3.11-venv python3.11-dev python3-pip
python3.11 --version && info "Python installed."

# ─────────────────────────────────────────────
# 4. INSTALL NODE.JS 20 (for React build)
# ─────────────────────────────────────────────
info "Installing Node.js 20..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
apt-get install -y -qq nodejs
node --version && info "Node.js installed."

# ─────────────────────────────────────────────
# 5. INSTALL POSTGRESQL
# ─────────────────────────────────────────────
info "Installing PostgreSQL..."
apt-get install -y -qq postgresql postgresql-contrib

systemctl enable postgresql
systemctl start postgresql

# Create DB and user
info "Setting up PostgreSQL database..."
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE $DB_NAME OWNER $DB_USER'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\gexec
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

info "PostgreSQL database '$DB_NAME' and user '$DB_USER' created."

# ─────────────────────────────────────────────
# 6. INSTALL NGINX
# ─────────────────────────────────────────────
info "Installing Nginx..."
apt-get install -y -qq nginx
systemctl enable nginx
systemctl start nginx
info "Nginx installed and running."

# ─────────────────────────────────────────────
# 7. SETUP FIREWALL (UFW)
# ─────────────────────────────────────────────
info "Configuring firewall..."
ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp    # HTTP
ufw allow 443/tcp   # HTTPS (for future SSL)
ufw allow 9000/tcp  # GitHub webhook listener
ufw --force enable
info "Firewall configured. Ports open: 22 (SSH), 80, 443, 9000."

# ─────────────────────────────────────────────
# 8. CLONE YOUR GITHUB REPO
# ─────────────────────────────────────────────
info "Setting up app directory..."
mkdir -p $APP_DIR
chown -R $APP_USER:$APP_USER $APP_DIR

if [ "$GITHUB_REPO" != "https://github.com/YOUR_USERNAME/YOUR_REPO.git" ]; then
    info "Cloning GitHub repo..."
    sudo -u $APP_USER git clone $GITHUB_REPO $APP_DIR
else
    warning "GitHub repo not set. Creating placeholder structure..."
    sudo -u $APP_USER mkdir -p $APP_DIR/backend $APP_DIR/frontend
fi

# ─────────────────────────────────────────────
# 9. SETUP PYTHON VIRTUAL ENVIRONMENT (Backend)
# ─────────────────────────────────────────────
info "Setting up Python virtual environment..."
sudo -u $APP_USER python3.11 -m venv $APP_DIR/backend/venv

# Install FastAPI and common ERP dependencies
sudo -u $APP_USER $APP_DIR/backend/venv/bin/pip install --quiet \
    fastapi \
    uvicorn[standard] \
    sqlalchemy \
    asyncpg \
    alembic \
    psycopg2-binary \
    python-dotenv \
    pydantic \
    pydantic-settings \
    python-jose[cryptography] \
    passlib[bcrypt] \
    python-multipart \
    httpx \
    pandas \
    openpyxl

info "Python backend dependencies installed."

# ─────────────────────────────────────────────
# 10. CREATE BACKEND .env FILE
# ─────────────────────────────────────────────
info "Creating backend .env file..."
cat > $APP_DIR/backend/.env <<EOF
DATABASE_URL=postgresql://$DB_USER:$DB_PASS@localhost/$DB_NAME
SECRET_KEY=$(openssl rand -hex 32)
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=60
ENVIRONMENT=production
EOF
chown $APP_USER:$APP_USER $APP_DIR/backend/.env
chmod 600 $APP_DIR/backend/.env
info ".env file created."

# ─────────────────────────────────────────────
# 11. SETUP SYSTEMD SERVICE (keeps app running)
# ─────────────────────────────────────────────
info "Creating systemd service for FastAPI backend..."
cat > /etc/systemd/system/erp-backend.service <<EOF
[Unit]
Description=ERP FastAPI Backend
After=network.target postgresql.service

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR/backend
Environment="PATH=$APP_DIR/backend/venv/bin"
EnvironmentFile=$APP_DIR/backend/.env
ExecStart=$APP_DIR/backend/venv/bin/uvicorn main:app --host 127.0.0.1 --port $BACKEND_PORT --workers 2
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable erp-backend
info "Backend service created (will start after you add your code)."

# ─────────────────────────────────────────────
# 12. BUILD REACT FRONTEND (if package.json exists)
# ─────────────────────────────────────────────
if [ -f "$APP_DIR/frontend/package.json" ]; then
    info "Building React frontend..."
    cd $APP_DIR/frontend
    sudo -u $APP_USER npm install --silent
    sudo -u $APP_USER npm run build --silent
    info "React frontend built."
else
    warning "No frontend/package.json found. Skipping React build."
    sudo -u $APP_USER mkdir -p $APP_DIR/frontend/build
    echo "<h1>ERP Frontend - Coming Soon</h1>" > $APP_DIR/frontend/build/index.html
fi

# ─────────────────────────────────────────────
# 13. CONFIGURE NGINX
# ─────────────────────────────────────────────
info "Configuring Nginx..."
SERVER_IP=$(curl -s ifconfig.me)

cat > /etc/nginx/sites-available/erp <<EOF
server {
    listen 80;
    server_name $SERVER_IP _;

    # Gzip compression
    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml;

    # Serve React frontend
    root $APP_DIR/frontend/build;
    index index.html;

    # API requests → FastAPI backend
    location /api/ {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
    }

    # GitHub webhook listener
    location /webhook {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host \$host;
    }

    # React Router — serve index.html for all frontend routes
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

# Enable site
ln -sf /etc/nginx/sites-available/erp /etc/nginx/sites-enabled/erp
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
info "Nginx configured. Site accessible at http://$SERVER_IP"

# ─────────────────────────────────────────────
# 14. SETUP AUTO-DEPLOY WEBHOOK
# (Listens for GitHub push → pulls code → restarts app)
# ─────────────────────────────────────────────
info "Setting up GitHub auto-deploy webhook..."

# Install webhook tool
apt-get install -y -qq webhook

# Create deploy script
cat > /var/www/deploy.sh <<'DEPLOY'
#!/bin/bash
set -e
APP_DIR="/var/www/erp"
APP_USER="erpuser"
LOG="/var/log/erp-deploy.log"

echo "=== Deploy started: $(date) ===" >> $LOG

# Pull latest code (code only — database is untouched)
cd $APP_DIR
sudo -u $APP_USER git pull origin main >> $LOG 2>&1

# Reinstall backend deps if requirements changed
if [ -f "$APP_DIR/backend/requirements.txt" ]; then
    sudo -u $APP_USER $APP_DIR/backend/venv/bin/pip install -r $APP_DIR/backend/requirements.txt --quiet >> $LOG 2>&1
fi

# Run database migrations (safe — never deletes data)
if [ -f "$APP_DIR/backend/alembic.ini" ]; then
    cd $APP_DIR/backend
    sudo -u $APP_USER $APP_DIR/backend/venv/bin/alembic upgrade head >> $LOG 2>&1
fi

# Rebuild frontend if needed
if [ -f "$APP_DIR/frontend/package.json" ]; then
    cd $APP_DIR/frontend
    sudo -u $APP_USER npm install --silent >> $LOG 2>&1
    sudo -u $APP_USER npm run build --silent >> $LOG 2>&1
fi

# Restart backend
systemctl restart erp-backend

echo "=== Deploy done: $(date) ===" >> $LOG
DEPLOY
chmod +x /var/www/deploy.sh

# Webhook config
mkdir -p /etc/webhook
cat > /etc/webhook/hooks.json <<EOF
[
  {
    "id": "deploy",
    "execute-command": "/var/www/deploy.sh",
    "command-working-directory": "$APP_DIR",
    "trigger-rule": {
      "match": {
        "type": "payload-hmac-sha256",
        "secret": "$WEBHOOK_SECRET",
        "parameter": {
          "source": "header",
          "name": "X-Hub-Signature-256"
        }
      }
    }
  }
]
EOF

# Webhook systemd service
cat > /etc/systemd/system/webhook.service <<EOF
[Unit]
Description=GitHub Webhook Listener
After=network.target

[Service]
ExecStart=/usr/bin/webhook -hooks /etc/webhook/hooks.json -port 9000 -verbose
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable webhook
systemctl start webhook
info "Webhook listener running on port 9000."

# ─────────────────────────────────────────────
# 15. SETUP DAILY DATABASE BACKUPS
# ─────────────────────────────────────────────
info "Setting up daily database backups..."
mkdir -p /var/backups/erp
chown postgres:postgres /var/backups/erp

cat > /etc/cron.daily/erp-db-backup <<EOF
#!/bin/bash
# Daily PostgreSQL backup — keeps 30 days
BACKUP_DIR="/var/backups/erp"
FILENAME="erp_backup_\$(date +%Y%m%d_%H%M%S).sql.gz"
sudo -u postgres pg_dump $DB_NAME | gzip > \$BACKUP_DIR/\$FILENAME
# Delete backups older than 30 days
find \$BACKUP_DIR -name "*.sql.gz" -mtime +30 -delete
echo "Backup saved: \$FILENAME"
EOF
chmod +x /etc/cron.daily/erp-db-backup
info "Daily database backups configured (saved to /var/backups/erp, 30-day retention)."

# ─────────────────────────────────────────────
# DONE — Print Summary
# ─────────────────────────────────────────────
SERVER_IP=$(curl -s ifconfig.me)
echo ""
echo "======================================================"
echo -e "  ${GREEN}Setup Complete!${NC}"
echo "======================================================"
echo ""
echo "  Your server IP:     http://$SERVER_IP"
echo "  App directory:      $APP_DIR"
echo "  Database:           $DB_NAME (PostgreSQL)"
echo "  DB user:            $DB_USER"
echo "  Backend port:       $BACKEND_PORT (FastAPI)"
echo "  Deploy log:         /var/log/erp-deploy.log"
echo "  DB backups:         /var/backups/erp/"
echo ""
echo "  ── Next Steps ──────────────────────────────────"
echo ""
echo "  1. Edit the top of this script and set:"
echo "     - GITHUB_REPO to your actual GitHub repo URL"
echo "     - DB_PASS and WEBHOOK_SECRET to strong values"
echo ""
echo "  2. In your GitHub repo settings, add a webhook:"
echo "     URL:    http://$SERVER_IP/webhook/deploy"
echo "     Secret: (the WEBHOOK_SECRET you set above)"
echo "     Event:  Just the push event"
echo ""
echo "  3. Start the backend after adding your code:"
echo "     systemctl start erp-backend"
echo ""
echo "  4. To check backend logs:"
echo "     journalctl -u erp-backend -f"
echo ""
echo "  5. To trigger a manual deploy:"
echo "     bash /var/www/deploy.sh"
echo ""
echo "======================================================"
