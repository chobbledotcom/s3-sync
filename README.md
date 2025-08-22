# S3 Bucket Sync

Automated S3 bucket synchronization between Hetzner and Scaleway storage providers.

## Features

- Syncs multiple S3 bucket pairs automatically
- Creates missing buckets on destination
- Runs daily via GitHub Actions
- Supports manual triggering
- Uses cached apt packages for fast CI runs
- Nix flake available for local development

## Setup

### GitHub Secrets Required

Configure the following secrets in your GitHub repository settings:

#### For each pair (1-4):
- `HETZNER[1-4]_ACCESS_KEY` - Hetzner S3 access key
- `HETZNER[1-4]_SECRET_KEY` - Hetzner S3 secret key
- `SCALEWAY[1-4]_ACCESS_KEY` - Scaleway S3 access key
- `SCALEWAY[1-4]_SECRET_KEY` - Scaleway S3 secret key

Endpoints and regions are hardcoded:
- Hetzner: `https://hel1.your-objectstorage.com` (region: `eu-central`)
- Scaleway: `https://s3.fr-par.scw.cloud` (region: `fr-par`)

## Local Usage

### With Nix Shell (Original Script)
```bash
# Copy .env.example to .env and configure
cp .env.example .env
# Edit .env with your credentials

# Run sync
./sync-s3-buckets.nix

# Dry run
./sync-s3-buckets.nix --dry-run

# Sync specific pair
./sync-s3-buckets.nix --pair hetzner1:scaleway1
```

### With Nix Flake
```bash
# Enter development shell
nix develop

# Run the sync script
bash sync-s3-buckets.sh
```

## GitHub Actions

The workflow runs daily at 2 AM UTC and can also be manually triggered from the Actions tab.

### Manual Trigger
1. Go to Actions tab
2. Select "Sync S3 Buckets" workflow
3. Click "Run workflow"

## Script Options

### Original Script (sync-s3-buckets.nix)
- `--dry-run` - Preview operations without making changes
- `--parallel` - Run all sync pairs concurrently
- `--pair SOURCE:DEST` - Sync only specific provider pair
- `--bucket NAME` - Sync only specific bucket across all pairs
- `--verbose` - Show detailed output

## Files

- `sync-s3-buckets.nix` - Original NixOS script with .env file support
- `sync-s3-buckets.sh` - Simplified bash script for GitHub Actions
- `flake.nix` - Nix flake providing required tools
- `.github/workflows/sync-s3-buckets.yml` - GitHub Actions workflow
- `.env.example` - Example configuration for local usage