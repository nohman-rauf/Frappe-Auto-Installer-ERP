#!/bin/bash
set -euo pipefail

# -------------------------
# Unattended ERPNext installer (Debian/Ubuntu)
# - Makes MariaDB root passwordless (mysql_native_password)
# - Installs bench and ERPNext v15
# WARNING: For local/dev use only. This makes MariaDB root passwordless.
# -------------------------

# Defaults (override by exporting env vars before running)
FOLDER="${ERP_BENCH_FOLDER:-frappe-bench}"
SITENAME="${ERP_SITE_NAME:-site.local}"
ADMIN_PASSWORD="${ERP_ADMIN_PASSWORD:-admin}"
FRAPPE_BRANCH="${ERP_FRAPPE_BRANCH:-version-15}"
ERPNEXT_BRANCH="${ERP_ERPNEXT_BRANCH:-version-15}"
NONINTERACTIVE=${NONINTERACTIVE:-1}

if [ "$NONINTERACTIVE" = "1" ]; then
  export DEBIAN_FRONTEND=noninteractive
fi

echo "Starting unattended ERPNext installer"
echo "Bench folder: $FOLDER"
echo "Site name: $SITENAME"
echo "Frappe branch: $FRAPPE_BRANCH"
echo "ERPNext branch: $ERPNEXT_BRANCH"

# Ensure running on Debian/Ubuntu
if ! command -v apt >/dev/null 2>&1; then
  echo "This script uses apt and is intended for Debian/Ubuntu."
  echo "Aborting."
  exit 1
fi

# Helper to check command
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Update & install prerequisites
echo "Updating apt and installing prerequisites..."
sudo apt update -y
sudo apt install -y software-properties-common curl gnupg2

sudo apt install -y git python3 python3-dev python3-pip python3-setuptools python3-venv \
    redis-server mariadb-server libmysqlclient-dev build-essential

# Install Node.js 18 and yarn (if not present)
if ! command_exists node || ! node -v | grep -q "v18"; then
  echo "Installing Node.js 18..."
  curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
  sudo apt install -y nodejs
fi

if ! command_exists yarn; then
  echo "Installing yarn..."
  sudo npm install -g yarn
fi

# Create python venv for bench
echo "Creating Python virtualenv for bench (if missing)..."
if [ ! -d "$HOME/.bench-venv" ]; then
  python3 -m venv "$HOME/.bench-venv"
fi

# Activate and install bench
echo "Activating bench venv and installing frappe-bench..."
# shellcheck disable=SC1090
source "$HOME/.bench-venv/bin/activate"
pip install --upgrade pip setuptools wheel
pip install frappe-bench

# Ensure bench is in path via symlink
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/.bench-venv/bin/bench" "$HOME/.local/bin/bench"
export PATH="$HOME/.local/bin:$PATH"

# Persist PATH for future shells (if using bash)
if [ -n "$HOME" ] && [ -f "$HOME/.bashrc" ] && ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

deactivate || true

# Configure MariaDB for utf8mb4 (frappe compatible)
echo "Configuring MariaDB defaults for utf8mb4..."
sudo tee /etc/mysql/conf.d/frappe.cnf >/dev/null <<'EOF'
[mysqld]
innodb-file-format=barracuda
innodb-file-per-table=1
innodb-large-prefix=1
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-name-resolve
EOF

sudo systemctl restart mariadb || true
sleep 2

# Make MariaDB root passwordless and use mysql_native_password
echo "Configuring MariaDB root account to be passwordless and use mysql_native_password..."
# Try multiple options to cover MariaDB versions / auth plugins
set +e
sudo mysql -uroot <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING '';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
RET=$?
if [ $RET -ne 0 ]; then
  echo "First ALTER USER failed, trying alternative ALTER USER syntax..."
  sudo mysql -uroot <<'SQL'
ALTER USER 'root'@'localhost' IDENTIFIED BY '';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  RET2=$?
  if [ $RET2 -ne 0 ]; then
    echo "Second ALTER USER failed, trying direct mysql.user update (last resort)..."
    sudo mysql -uroot <<'SQL'
UPDATE mysql.user SET plugin='mysql_native_password', authentication_string='' WHERE User='root' AND Host='localhost';
UPDATE mysql.user SET plugin='mysql_native_password', authentication_string='' WHERE User='root' AND Host='127.0.0.1';
FLUSH PRIVILEGES;
SQL
    RET3=$?
    if [ $RET3 -ne 0 ]; then
      echo "Failed to set root to passwordless automatically. Please run the following as root manually:"
      echo "  ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING ''; FLUSH PRIVILEGES;"
      exit 1
    fi
  fi
fi
set -e

echo "MariaDB root authentication adjusted."

# Ensure mariadb is running
sudo systemctl enable --now mariadb

# Initialize bench folder (non-interactive)
echo "Initializing bench at $FOLDER..."
# Activate bench venv
# shellcheck disable=SC1090
source "$HOME/.bench-venv/bin/activate"

if [ -d "$FOLDER" ]; then
  echo "Folder $FOLDER already exists. Skipping bench init."
else
  "$HOME/.bench-venv/bin/bench" init "$FOLDER" --frappe-branch "$FRAPPE_BRANCH" --skip-assets || {
    echo "bench init failed. Exiting."
    deactivate || true
    exit 1
  }
fi

cd "$FOLDER" || (echo "Cannot cd to $FOLDER" && exit 1)

# Create site non-interactively with empty mariadb root password
echo "Creating new site $SITENAME (non-interactive)..."
# bench new-site requires mariadb-root-password '' to allow root no-password
# Provide admin password via flag
"$HOME/.bench-venv/bin/bench" new-site "$SITENAME" --mariadb-root-password '' --admin-password "$ADMIN_PASSWORD" --install-app erpnext || {
  echo "First attempt to create site failed. Trying with explicit mysql socket (fallback)..."
  # Try with mysql socket path if needed
  MYSQL_SOCK=$(sudo mysqld --verbose --help 2>/dev/null | grep -m1 'socket' | awk '{print $2}' || true)
  if [ -n "$MYSQL_SOCK" ]; then
    echo "Found mysql socket: $MYSQL_SOCK - trying again with socket"
    export MYSQL_CLIENT_SOCKET="$MYSQL_SOCK"
    "$HOME/.bench-venv/bin/bench" new-site "$SITENAME" --mariadb-root-password '' --admin-password "$ADMIN_PASSWORD" --install-app erpnext || {
      echo "Failed to create site even after fallback. Aborting."
      deactivate || true
      exit 1
    }
  else
    echo "No mysql socket found. Aborting."
    deactivate || true
    exit 1
  fi
}

# Get ERPNext app (if missing) and install (install-app already used above)
if [ ! -d "apps/erpnext" ]; then
  echo "Fetching ERPNext app..."
  "$HOME/.bench-venv/bin/bench" get-app erpnext --branch "$ERPNEXT_BRANCH" || {
    echo "Failed to get erpnext app"
    deactivate || true
    exit 1
  }
  echo "Installing ERPNext app on site..."
  "$HOME/.bench-venv/bin/bench" --site "$SITENAME" install-app erpnext || {
    echo "Failed to install erpnext"
    deactivate || true
    exit 1
  }
fi

deactivate || true

echo "-------------------------------------------------"
echo "Installation finished (or at least reached final step)."
echo "Bench folder: $FOLDER"
echo "Site: $SITENAME"
echo "Admin password: $ADMIN_PASSWORD"
echo ""
echo "Start bench:"
echo "  cd $FOLDER && $HOME/.bench-venv/bin/bench start"
echo "Access the site at http://$SITENAME (you may need to edit /etc/hosts to point $SITENAME to this server)"
echo "Reminder: MariaDB root is now passwordless (for local/dev only)."
echo "-------------------------------------------------"
