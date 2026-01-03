# Local Asset Caching

To speed up repeated PXE boots, pull commonly used OS images locally.

## Pull Assets via Web UI

1. Go to netboot.xyz Web UI: http://tkn-b-haos.local:3000
2. Navigate to **Assets** in the menu
3. Click **Pull OS** for each OS you want to cache:

### Recommended Assets to Pull

| OS | Version | Use Case |
|----|---------|----------|
| Ubuntu | 24.04 LTS | BriefHours cluster, K3s nodes |
| Ubuntu | 22.04 LTS | Legacy deployments |
| SystemRescue | Latest | Emergency recovery |
| GParted | Latest | Disk partitioning |

## Asset Storage

Assets are stored in `/config/assets/` on HAOS:

```
/config/assets/
├── ubuntu-netboot-24.04-amd64/
│   ├── vmlinuz
│   └── initrd
├── ubuntu-netboot-22.04-amd64/
│   ├── vmlinuz
│   └── initrd
└── ...
```

## How Caching Works

1. iPXE menu loads `local-vars.ipxe` with cache settings
2. If `use_local_cache=1`, tries local assets first
3. Falls back to remote URLs if local assets not found
4. Local assets served from port 3000 (`/assets/`)

## Verify Cached Assets

```bash
# SSH to HAOS
ssh root@tkn-b-haos.local

# List cached assets
ls -la /config/assets/

# Check asset size
du -sh /config/assets/*
```

## Clear Cache

To remove cached assets:

```bash
rm -rf /config/assets/<asset-name>/
```

## Enable/Disable Caching

Edit `local-vars.ipxe`:

```ipxe
# Enable caching (default)
set use_local_cache 1

# Disable caching (always use remote)
set use_local_cache 0
```
