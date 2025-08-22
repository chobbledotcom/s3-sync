#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash awscli2 jq rclone

# S3 Multi-Provider Bucket Sync Script
# Syncs buckets between multiple S3-compatible storage providers

set -uo pipefail

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default values
DRY_RUN=false
PARALLEL=false
SPECIFIC_PAIR=""
SPECIFIC_BUCKET=""
VERBOSE=false
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --parallel)
            PARALLEL=true
            shift
            ;;
        --pair)
            SPECIFIC_PAIR="$2"
            shift 2
            ;;
        --bucket)
            SPECIFIC_BUCKET="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            SHOW_HELP=true
            shift
            ;;
    esac
done

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    cat << EOF
${BOLD}S3 Multi-Provider Bucket Sync${NC}

${YELLOW}Usage:${NC}
  $(basename "$0") [OPTIONS]

${YELLOW}Options:${NC}
  --dry-run           Preview operations without making changes
  --parallel          Run all sync pairs concurrently
  --pair SOURCE:DEST  Sync only specific provider pair
  --bucket NAME       Sync only specific bucket across all pairs
  --verbose, -v       Show detailed output
  --help, -h          Show this help message

${YELLOW}Examples:${NC}
  $(basename "$0")                           # Sync all pairs
  $(basename "$0") --dry-run                 # Preview all operations
  $(basename "$0") --pair hetzner1:scaleway1 # Sync specific pair
  $(basename "$0") --bucket my-bucket        # Sync specific bucket
  $(basename "$0") --parallel                # Run all pairs concurrently

${YELLOW}Configuration:${NC}
  Create a .env file in the same directory with:
  - SYNC_PAIRS: Comma-separated list of SOURCE:DEST pairs
  - Provider credentials for each provider mentioned in SYNC_PAIRS

EOF
    exit 0
fi

# Load environment variables from .env file
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo -e "${RED}Error: .env file not found in $SCRIPT_DIR${NC}"
    echo -e "${YELLOW}Please create a .env file with provider configurations.${NC}"
    echo -e "${YELLOW}See .env.example for reference.${NC}"
    exit 1
fi

# Validate SYNC_PAIRS is defined
if [ -z "${SYNC_PAIRS:-}" ]; then
    echo -e "${RED}Error: SYNC_PAIRS not defined in .env file${NC}"
    echo -e "${YELLOW}Example: SYNC_PAIRS=\"hetzner1:scaleway1,hetzner2:scaleway2\"${NC}"
    exit 1
fi

# Function to convert provider name to uppercase for env var lookup
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Function to validate provider credentials
validate_provider() {
    local provider="$1"
    local provider_upper=$(to_upper "$provider")
    
    local endpoint_var="${provider_upper}_S3_ENDPOINT"
    local region_var="${provider_upper}_S3_REGION"
    local access_key_var="${provider_upper}_ACCESS_KEY"
    local secret_key_var="${provider_upper}_SECRET_KEY"
    
    if [ -z "${!endpoint_var:-}" ] || [ -z "${!region_var:-}" ] || 
       [ -z "${!access_key_var:-}" ] || [ -z "${!secret_key_var:-}" ]; then
        echo -e "${RED}Error: Missing credentials for provider: $provider${NC}"
        echo -e "${YELLOW}Required variables:${NC}"
        echo "  - $endpoint_var"
        echo "  - $region_var"
        echo "  - $access_key_var"
        echo "  - $secret_key_var"
        return 1
    fi
    return 0
}

# Function to list buckets for a provider
list_buckets() {
    local provider="$1"
    local provider_upper=$(to_upper "$provider")
    
    local endpoint="${provider_upper}_S3_ENDPOINT"
    local region="${provider_upper}_S3_REGION"
    local access_key="${provider_upper}_ACCESS_KEY"
    local secret_key="${provider_upper}_SECRET_KEY"
    
    AWS_ACCESS_KEY_ID="${!access_key}" \
    AWS_SECRET_ACCESS_KEY="${!secret_key}" \
    aws s3api list-buckets \
        --endpoint-url "${!endpoint}" \
        --region "${!region}" \
        --output json 2>/dev/null | jq -r '.Buckets[]?.Name' 2>/dev/null || true
}

# Function to check if bucket exists
bucket_exists() {
    local provider="$1"
    local bucket="$2"
    local provider_upper=$(to_upper "$provider")
    
    local endpoint="${provider_upper}_S3_ENDPOINT"
    local region="${provider_upper}_S3_REGION"
    local access_key="${provider_upper}_ACCESS_KEY"
    local secret_key="${provider_upper}_SECRET_KEY"
    
    AWS_ACCESS_KEY_ID="${!access_key}" \
    AWS_SECRET_ACCESS_KEY="${!secret_key}" \
    aws s3api head-bucket \
        --bucket "$bucket" \
        --endpoint-url "${!endpoint}" \
        --region "${!region}" 2>/dev/null && return 0 || return 1
}

# Function to create bucket
create_bucket() {
    local provider="$1"
    local bucket="$2"
    local provider_upper=$(to_upper "$provider")
    
    local endpoint="${provider_upper}_S3_ENDPOINT"
    local region="${provider_upper}_S3_REGION"
    local access_key="${provider_upper}_ACCESS_KEY"
    local secret_key="${provider_upper}_SECRET_KEY"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${BLUE}[DRY-RUN] Would create bucket: $bucket${NC}"
        # Don't return here in dry-run mode, let the flow continue
        # so we can show what would be synced
    else
        # Create bucket using aws s3 mb (make bucket) command
        echo -e "  ${CYAN}Creating bucket on ${!endpoint}...${NC}"
        
        # Use s3 mb command which is simpler and more reliable
        AWS_ACCESS_KEY_ID="${!access_key}" \
        AWS_SECRET_ACCESS_KEY="${!secret_key}" \
        aws s3 mb "s3://$bucket" \
            --endpoint-url "${!endpoint}" \
            --region "${!region}" 2>&1
        
        # Check if bucket was created successfully
        if [ $? -eq 0 ]; then
            echo -e "  ${GREEN}✓ Bucket created successfully${NC}"
            return 0
        else
            echo -e "  ${RED}✗ Failed to create bucket${NC}"
            return 1
        fi
    fi
}

# Function to generate rclone config for a provider
generate_rclone_config() {
    local provider="$1"
    local config_file="$2"
    local provider_upper=$(to_upper "$provider")
    
    local endpoint="${provider_upper}_S3_ENDPOINT"
    local region="${provider_upper}_S3_REGION"
    local access_key="${provider_upper}_ACCESS_KEY"
    local secret_key="${provider_upper}_SECRET_KEY"
    
    # Detect provider type based on endpoint
    local provider_type="Other"
    if [[ "${!endpoint}" == *"scw.cloud"* ]]; then
        provider_type="Scaleway"
    fi
    # Hetzner uses "Other" as provider type
    
    cat >> "$config_file" << EOF
[$provider]
type = s3
provider = $provider_type
access_key_id = ${!access_key}
secret_access_key = ${!secret_key}
endpoint = ${!endpoint}
region = ${!region}

EOF
}

# Function to sync a bucket using rclone
sync_bucket() {
    local source_provider="$1"
    local dest_provider="$2"
    local bucket="$3"
    local config_file="$4"
    
    local rclone_opts="--config $config_file"
    
    if [ "$VERBOSE" = true ]; then
        rclone_opts="$rclone_opts -vv --stats 5s"
    else
        # Always show some verbosity to see what's happening
        rclone_opts="$rclone_opts -v --progress --stats 10s"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        rclone_opts="$rclone_opts --dry-run"
        echo -e "  ${BLUE}[DRY-RUN] Would sync: $bucket${NC}"
    fi
    
    # Add safety and performance options
    # --update: Skip files that are newer on the destination
    # --transfers: Number of file transfers to run in parallel
    # --checkers: Number of checkers to run in parallel
    rclone_opts="$rclone_opts --update --transfers 4 --checkers 8"
    
    # Optional: Add more aggressive options for speed
    # --size-only: Skip based on size only (faster but less accurate)
    # --fast-list: Use recursive list (faster but not all S3 providers support it)
    # Uncomment if you want to try these:
    # rclone_opts="$rclone_opts --size-only --fast-list"
    
    # Perform the sync
    echo -e "  ${CYAN}Syncing bucket: $bucket${NC}"
    echo -e "  ${CYAN}Source: $source_provider:$bucket${NC}"
    echo -e "  ${CYAN}Dest:   $dest_provider:$bucket${NC}"
    
    # Show what rclone is about to do
    echo -e "  ${CYAN}Scanning files...${NC}"
    
    # Rclone will automatically check and skip existing files
    rclone sync \
        "$source_provider:$bucket" \
        "$dest_provider:$bucket" \
        $rclone_opts
    
    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}✓ Successfully synced: $bucket${NC}"
    else
        echo -e "  ${RED}✗ Failed to sync: $bucket${NC}"
        return 1
    fi
}

# Function to process a sync pair
process_sync_pair() {
    local pair="$1"
    local source="${pair%:*}"
    local dest="${pair#*:}"
    
    echo -e "\n${BOLD}${YELLOW}Processing: $source → $dest${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Validate both providers
    if ! validate_provider "$source"; then
        echo -e "${RED}Skipping pair due to missing source credentials${NC}"
        return 1
    fi
    
    if ! validate_provider "$dest"; then
        echo -e "${RED}Skipping pair due to missing destination credentials${NC}"
        return 1
    fi
    
    # List buckets from both providers
    echo -e "${CYAN}Fetching bucket lists...${NC}"
    local source_buckets=$(list_buckets "$source")
    local dest_buckets=$(list_buckets "$dest")
    
    if [ -z "$source_buckets" ]; then
        echo -e "${YELLOW}No buckets found on source provider: $source${NC}"
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
    generate_rclone_config "$source" "$temp_config"
    generate_rclone_config "$dest" "$temp_config"
    
    # Track virtually created buckets in dry-run mode
    local virtually_created_buckets=""
    
    # Process each source bucket
    local created_count=0
    local synced_count=0
    local failed_count=0
    
    for bucket in $source_buckets; do
        # Skip if specific bucket is requested and this isn't it
        if [ -n "$SPECIFIC_BUCKET" ] && [ "$bucket" != "$SPECIFIC_BUCKET" ]; then
            continue
        fi
        
        # Check if bucket should be excluded
        if [ -n "${EXCLUDE_BUCKETS:-}" ]; then
            if echo "$EXCLUDE_BUCKETS" | grep -q "\b$bucket\b"; then
                echo -e "${YELLOW}Skipping excluded bucket: $bucket${NC}"
                continue
            fi
        fi
        
        echo -e "\n${BOLD}Bucket: $bucket${NC}"
        
        # Check if bucket exists on destination (or was virtually created in dry-run)
        local bucket_exists_on_dest=false
        if [ "$DRY_RUN" = true ] && echo "$virtually_created_buckets" | grep -q "^$bucket$"; then
            bucket_exists_on_dest=true
        elif bucket_exists "$dest" "$bucket" 2>/dev/null; then
            bucket_exists_on_dest=true
        fi
        
        if [ "$bucket_exists_on_dest" = false ]; then
            echo -e "  ${YELLOW}Bucket does not exist on destination${NC}"
            if [ "$DRY_RUN" = false ]; then
                if create_bucket "$dest" "$bucket"; then
                    echo -e "  ${GREEN}✓ Created bucket: $bucket${NC}"
                    ((created_count++))
                else
                    echo -e "  ${RED}✗ Failed to create bucket: $bucket${NC}"
                    echo -e "  ${RED}Check your credentials and endpoint configuration${NC}"
                    ((failed_count++))
                    continue
                fi
            else
                create_bucket "$dest" "$bucket"
                ((created_count++))
                # Track this bucket as virtually created for dry-run
                virtually_created_buckets="${virtually_created_buckets}${bucket}\n"
            fi
        fi
        
        # Sync the bucket
        if sync_bucket "$source" "$dest" "$bucket" "$temp_config"; then
            ((synced_count++))
        else
            ((failed_count++))
        fi
    done
    
    # Clean up temp config
    rm -f "$temp_config"
    
    # Summary for this pair
    echo -e "\n${BOLD}Summary for $source → $dest:${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "  ${BLUE}[DRY-RUN] Would create: $created_count bucket(s)${NC}"
        echo -e "  ${BLUE}[DRY-RUN] Would sync: $synced_count bucket(s)${NC}"
    else
        echo -e "  ${GREEN}Buckets created: $created_count${NC}"
        echo -e "  ${GREEN}Buckets synced: $synced_count${NC}"
    fi
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
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Running in DRY-RUN mode - no changes will be made${NC}"
    fi
    
    # Parse sync pairs
    IFS=',' read -ra PAIRS_ARRAY <<< "$SYNC_PAIRS"
    
    # Filter pairs if specific pair is requested
    if [ -n "$SPECIFIC_PAIR" ]; then
        PAIRS_ARRAY=("$SPECIFIC_PAIR")
        echo -e "${YELLOW}Processing only: $SPECIFIC_PAIR${NC}"
    fi
    
    echo -e "${CYAN}Processing ${#PAIRS_ARRAY[@]} sync pair(s)...${NC}"
    
    # Process pairs
    if [ "$PARALLEL" = true ]; then
        echo -e "${YELLOW}Running in parallel mode${NC}"
        
        # Run all pairs in background
        for pair in "${PAIRS_ARRAY[@]}"; do
            process_sync_pair "$pair" &
        done
        
        # Wait for all background jobs
        wait
    else
        # Process sequentially
        local pair_num=1
        local total_pairs=${#PAIRS_ARRAY[@]}
        
        for pair in "${PAIRS_ARRAY[@]}"; do
            echo -e "\n${BOLD}${CYAN}[$pair_num/$total_pairs]${NC}"
            process_sync_pair "$pair"
            ((pair_num++))
        done
    fi
    
    echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}    Sync Complete!${NC}"
    echo -e "${BOLD}${GREEN}═══════════════════════════════════════════${NC}"
}

# Run main function
main