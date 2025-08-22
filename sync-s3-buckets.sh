#!/usr/bin/env bash

# S3 Multi-Provider Bucket Sync Script for GitHub Actions
# Syncs buckets between multiple S3-compatible storage providers
# Expects credentials to be set as environment variables from GitHub Secrets

set -uo pipefail

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Function to list buckets for a provider
list_buckets() {
    local provider="$1"
    local endpoint="$2"
    local region="$3"
    local access_key="$4"
    local secret_key="$5"
    
    AWS_ACCESS_KEY_ID="$access_key" \
    AWS_SECRET_ACCESS_KEY="$secret_key" \
    aws s3api list-buckets \
        --endpoint-url "$endpoint" \
        --region "$region" \
        --output json 2>/dev/null | jq -r '.Buckets[]?.Name' 2>/dev/null || true
}

# Function to check if bucket exists
bucket_exists() {
    local provider="$1"
    local bucket="$2"
    local endpoint="$3"
    local region="$4"
    local access_key="$5"
    local secret_key="$6"
    
    AWS_ACCESS_KEY_ID="$access_key" \
    AWS_SECRET_ACCESS_KEY="$secret_key" \
    aws s3api head-bucket \
        --bucket "$bucket" \
        --endpoint-url "$endpoint" \
        --region "$region" 2>/dev/null && return 0 || return 1
}

# Function to create bucket
create_bucket() {
    local provider="$1"
    local bucket="$2"
    local endpoint="$3"
    local region="$4"
    local access_key="$5"
    local secret_key="$6"
    
    echo -e "  ${CYAN}Creating bucket on $endpoint...${NC}"
    
    # Use s3 mb command which is simpler and more reliable
    AWS_ACCESS_KEY_ID="$access_key" \
    AWS_SECRET_ACCESS_KEY="$secret_key" \
    aws s3 mb "s3://$bucket" \
        --endpoint-url "$endpoint" \
        --region "$region" 2>&1
    
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Bucket created successfully${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Failed to create bucket${NC}"
        return 1
    fi
}

# Function to generate rclone config for a provider
generate_rclone_config() {
    local provider_name="$1"
    local config_file="$2"
    local endpoint="$3"
    local region="$4"
    local access_key="$5"
    local secret_key="$6"
    
    # Detect provider type based on endpoint
    local provider_type="Other"
    if [[ "$endpoint" == *"scw.cloud"* ]]; then
        provider_type="Scaleway"
    fi
    # Hetzner uses "Other" as provider type
    
    cat >> "$config_file" << EOF
[$provider_name]
type = s3
provider = $provider_type
access_key_id = $access_key
secret_access_key = $secret_key
endpoint = $endpoint
region = $region

EOF
}

# Function to sync a bucket using rclone
sync_bucket() {
    local source_provider="$1"
    local dest_provider="$2"
    local bucket="$3"
    local config_file="$4"
    
    echo -e "  ${CYAN}Syncing bucket: $bucket${NC}"
    echo -e "  ${CYAN}Source: $source_provider:$bucket${NC}"
    echo -e "  ${CYAN}Dest:   $dest_provider:$bucket${NC}"
    
    echo -e "  ${CYAN}Scanning files...${NC}"
    
    # Rclone will automatically check and skip existing files
    rclone sync \
        "$source_provider:$bucket" \
        "$dest_provider:$bucket" \
        --config "$config_file" \
        -v --progress --stats 10s \
        --update --transfers 4 --checkers 8
    
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Successfully synced: $bucket${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Failed to sync: $bucket${NC}"
        return 1
    fi
}

# Function to process a sync pair
process_sync_pair() {
    local pair_name="$1"
    local source_endpoint="$2"
    local source_region="$3"
    local source_access_key="$4"
    local source_secret_key="$5"
    local dest_endpoint="$6"
    local dest_region="$7"
    local dest_access_key="$8"
    local dest_secret_key="$9"
    
    echo -e "\n${BOLD}${YELLOW}Processing: $pair_name${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # List buckets from both providers
    echo -e "${CYAN}Fetching bucket lists...${NC}"
    local source_buckets=$(list_buckets "source" "$source_endpoint" "$source_region" "$source_access_key" "$source_secret_key")
    local dest_buckets=$(list_buckets "dest" "$dest_endpoint" "$dest_region" "$dest_access_key" "$dest_secret_key")
    
    if [ -z "$source_buckets" ]; then
        echo -e "${YELLOW}No buckets found on source provider${NC}"
        return 0
    fi
    
    # Count buckets
    local source_count=$(echo "$source_buckets" | wc -l)
    local dest_count=0
    if [ -n "$dest_buckets" ]; then
        dest_count=$(echo "$dest_buckets" | wc -l)
    fi
    
    echo -e "${GREEN}Source buckets: $source_count found${NC}"
    echo -e "${GREEN}Destination buckets: $dest_count found${NC}"
    
    # Generate temporary rclone config
    local temp_config=$(mktemp /tmp/rclone-config-XXXXXX)
    generate_rclone_config "source" "$temp_config" "$source_endpoint" "$source_region" "$source_access_key" "$source_secret_key"
    generate_rclone_config "dest" "$temp_config" "$dest_endpoint" "$dest_region" "$dest_access_key" "$dest_secret_key"
    
    # Process each source bucket
    local created_count=0
    local synced_count=0
    local failed_count=0
    
    for bucket in $source_buckets; do
        echo -e "\n${BOLD}Bucket: $bucket${NC}"
        
        # Check if bucket exists on destination
        if ! bucket_exists "dest" "$bucket" "$dest_endpoint" "$dest_region" "$dest_access_key" "$dest_secret_key"; then
            echo -e "  ${YELLOW}Bucket does not exist on destination${NC}"
            if create_bucket "dest" "$bucket" "$dest_endpoint" "$dest_region" "$dest_access_key" "$dest_secret_key"; then
                ((created_count++))
            else
                echo -e "  ${RED}Check your credentials and endpoint configuration${NC}"
                ((failed_count++))
                continue
            fi
        fi
        
        # Sync the bucket
        if sync_bucket "source" "dest" "$bucket" "$temp_config"; then
            ((synced_count++))
        else
            ((failed_count++))
        fi
    done
    
    # Clean up temp config
    rm -f "$temp_config"
    
    # Summary for this pair
    echo -e "\n${BOLD}Summary for $pair_name:${NC}"
    echo -e "  ${GREEN}Buckets created: $created_count${NC}"
    echo -e "  ${GREEN}Buckets synced: $synced_count${NC}"
    if [ $failed_count -gt 0 ]; then
        echo -e "  ${RED}Failed operations: $failed_count${NC}"
    fi
    
    return 0
}

# Main execution
main() {
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}    S3 Multi-Provider Bucket Sync${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
    
    # Fixed endpoints and regions
    local HETZNER_ENDPOINT="https://hel1.your-objectstorage.com"
    local HETZNER_REGION="eu-central"
    local SCALEWAY_ENDPOINT="https://s3.fr-par.scw.cloud"
    local SCALEWAY_REGION="fr-par"
    
    # Track which pairs are processed
    local pairs_processed=0
    
    # Process each pair based on available credentials
    # Pair 1
    if [ -n "${HETZNER1_ACCESS_KEY:-}" ] && [ -n "${HETZNER1_SECRET_KEY:-}" ] && \
       [ -n "${SCALEWAY1_ACCESS_KEY:-}" ] && [ -n "${SCALEWAY1_SECRET_KEY:-}" ]; then
        process_sync_pair "Hetzner1 → Scaleway1" \
            "$HETZNER_ENDPOINT" "$HETZNER_REGION" "$HETZNER1_ACCESS_KEY" "$HETZNER1_SECRET_KEY" \
            "$SCALEWAY_ENDPOINT" "$SCALEWAY_REGION" "$SCALEWAY1_ACCESS_KEY" "$SCALEWAY1_SECRET_KEY"
        ((pairs_processed++))
    else
        echo -e "${YELLOW}Skipping Pair 1: Missing credentials${NC}"
    fi
    
    # Pair 2
    if [ -n "${HETZNER2_ACCESS_KEY:-}" ] && [ -n "${HETZNER2_SECRET_KEY:-}" ] && \
       [ -n "${SCALEWAY2_ACCESS_KEY:-}" ] && [ -n "${SCALEWAY2_SECRET_KEY:-}" ]; then
        process_sync_pair "Hetzner2 → Scaleway2" \
            "$HETZNER_ENDPOINT" "$HETZNER_REGION" "$HETZNER2_ACCESS_KEY" "$HETZNER2_SECRET_KEY" \
            "$SCALEWAY_ENDPOINT" "$SCALEWAY_REGION" "$SCALEWAY2_ACCESS_KEY" "$SCALEWAY2_SECRET_KEY"
        ((pairs_processed++))
    else
        echo -e "${YELLOW}Skipping Pair 2: Missing credentials${NC}"
    fi
    
    # Pair 3
    if [ -n "${HETZNER3_ACCESS_KEY:-}" ] && [ -n "${HETZNER3_SECRET_KEY:-}" ] && \
       [ -n "${SCALEWAY3_ACCESS_KEY:-}" ] && [ -n "${SCALEWAY3_SECRET_KEY:-}" ]; then
        process_sync_pair "Hetzner3 → Scaleway3" \
            "$HETZNER_ENDPOINT" "$HETZNER_REGION" "$HETZNER3_ACCESS_KEY" "$HETZNER3_SECRET_KEY" \
            "$SCALEWAY_ENDPOINT" "$SCALEWAY_REGION" "$SCALEWAY3_ACCESS_KEY" "$SCALEWAY3_SECRET_KEY"
        ((pairs_processed++))
    else
        echo -e "${YELLOW}Skipping Pair 3: Missing credentials${NC}"
    fi
    
    # Pair 4
    if [ -n "${HETZNER4_ACCESS_KEY:-}" ] && [ -n "${HETZNER4_SECRET_KEY:-}" ] && \
       [ -n "${SCALEWAY4_ACCESS_KEY:-}" ] && [ -n "${SCALEWAY4_SECRET_KEY:-}" ]; then
        process_sync_pair "Hetzner4 → Scaleway4" \
            "$HETZNER_ENDPOINT" "$HETZNER_REGION" "$HETZNER4_ACCESS_KEY" "$HETZNER4_SECRET_KEY" \
            "$SCALEWAY_ENDPOINT" "$SCALEWAY_REGION" "$SCALEWAY4_ACCESS_KEY" "$SCALEWAY4_SECRET_KEY"
        ((pairs_processed++))
    else
        echo -e "${YELLOW}Skipping Pair 4: Missing credentials${NC}"
    fi
    
    # Check if any pairs were processed
    if [ $pairs_processed -eq 0 ]; then
        echo -e "\n${RED}Error: No credential pairs found!${NC}"
        echo -e "${YELLOW}Please configure at least one set of credentials.${NC}"
        exit 1
    fi
    
    echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}    Sync Complete!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
}

# Run main function
main