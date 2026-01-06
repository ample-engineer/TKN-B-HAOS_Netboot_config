#!/bin/bash
# Sync netboot.xyz configuration from GitHub
# Runs on HA startup + every 6 hours via automation

REPO_URL="https://github.com/ThomkerNet/TKN-B-HAOS_Netboot_config.git"
LOCAL_DIR="/config/netboot-config"
LOG_FILE="/config/logs/netboot_sync.log"

mkdir -p /config/logs

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "Starting netboot config sync..."

if [ -d "$LOCAL_DIR/.git" ]; then
    cd "$LOCAL_DIR"
    git fetch origin main 2>&1 | while read line; do log "$line"; done
    git reset --hard origin/main 2>&1 | while read line; do log "$line"; done
else
    rm -rf "$LOCAL_DIR"
    git clone "$REPO_URL" "$LOCAL_DIR" 2>&1 | while read line; do log "$line"; done
fi

# Sync menus to netboot.xyz addon
if [ -d "$LOCAL_DIR/menus" ]; then
    cp -r "$LOCAL_DIR/menus/"* /config/menus/ 2>/dev/null
    log "Synced menus"
fi

# Sync assets
if [ -d "$LOCAL_DIR/assets" ]; then
    cp -r "$LOCAL_DIR/assets/"* /config/assets/ 2>/dev/null
    log "Synced assets"
fi

# Sync config files
if [ -d "$LOCAL_DIR/config" ]; then
    cp -r "$LOCAL_DIR/config/"* /config/ 2>/dev/null
    log "Synced config"
fi

log "Sync complete"
