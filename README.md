# TKN-B HAOS Netboot.xyz Configuration

This repository contains the netboot.xyz configuration for the TKN-B Home Assistant OS instance.

## Structure

- `menus/` - iPXE menu files
- `assets/` - Custom boot assets (kernels, images)
- `config/` - Additional configuration files

## Sync

Changes pushed to `main` are automatically synced to Home Assistant via scheduled pull or webhook.

Logs: `/config/logs/netboot_sync.log` on HAOS
