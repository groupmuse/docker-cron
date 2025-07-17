#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
LOCK_FILE="/tmp/scale_workers.lock"
LAST_SCALE_FILE="/tmp/last_scale_time"
MIN_SCALE_INTERVAL=300  # 5 minutes in seconds
TEMP_DIR=$(mktemp -d)

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Cleanup function
cleanup() {
    rm -f "$LOCK_FILE"
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Check for lock file
if [ -f "$LOCK_FILE" ]; then
    log "Another scaling operation in progress. Exiting..."
    exit 0
fi
touch "$LOCK_FILE"

# Validate required environment variables
if [[ -z "${DIGITALOCEAN_API_TOKEN:-}" ]]; then
    log "ERROR: DIGITALOCEAN_API_TOKEN is not set"
    exit 1
fi

if [[ -z "${CRON_API_KEY:-}" ]]; then
    log "ERROR: CRON_API_KEY is not set"
    exit 1
fi

# Check recent scaling history
if [ -f "$LAST_SCALE_FILE" ]; then
    last_scale=$(cat "$LAST_SCALE_FILE")
    current_time=$(date +%s)
    time_diff=$((current_time - last_scale))
    
    if [ $time_diff -lt $MIN_SCALE_INTERVAL ]; then
        log "Scaled $time_diff seconds ago (less than $MIN_SCALE_INTERVAL seconds). Waiting for deployment to complete..."
        exit 0
    fi
fi

# Configuration
DIGITALOCEAN_APP_ID="${DIGITALOCEAN_APP_ID:-fe1dbd39-84b1-41f1-9ca2-25e974b691ff}"
DIGITALOCEAN_APP_URL="https://api.digitalocean.com/v2/apps/${DIGITALOCEAN_APP_ID}"
QUEUE_API_URL="https://www.groupmuse.com/cron/queue_size?api_key=${CRON_API_KEY}"
YAML_FILE="appspec.yaml"

log "Starting worker scaling script..."

# Step 1: GET the full app spec
# log "Fetching full app spec from DigitalOcean..."
if ! curl -sf -X GET "$DIGITALOCEAN_APP_URL" \
  -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -o "$TEMP_DIR/fullspec.yaml"; then
    log "ERROR: Failed to fetch app spec"
    exit 1
fi

# Step 2: Extract app.spec
# log "Extracting app.spec..."
if ! yq e '{ "spec": .app.spec }' "$TEMP_DIR/fullspec.yaml" > "$TEMP_DIR/$YAML_FILE"; then
    log "ERROR: Failed to extract app spec"
    exit 1
fi

# Check if autoscaling is enabled for the worker
autoscaling_enabled=$(yq e '.spec.workers[] | select(.name == "groupmuse-rails-worker") | has("autoscaling")' "$TEMP_DIR/$YAML_FILE" 2>/dev/null || echo "false")

if [[ "$autoscaling_enabled" == "true" ]]; then
    log "Autoscaling is enabled for groupmuse-rails-worker. Manual scaling disabled. Exiting..."
    exit 0
fi

# Step 3: Get the current queue length
# log "Fetching queue length..."
queue_response=$(curl -sf "$QUEUE_API_URL" || echo '{"pending": 0}')
queue_length=$(echo "$queue_response" | jq -r '.pending // 0')

if ! [[ "$queue_length" =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid queue length: $queue_length"
    exit 1
fi

log "Queue length is $queue_length."

# Get current worker count
current_worker_count=$(yq e '.spec.workers[] | select(.name == "groupmuse-rails-worker") | .instance_count // 0' "$TEMP_DIR/$YAML_FILE" | head -n1)

# Handle empty or invalid result
if [[ -z "$current_worker_count" ]] || ! [[ "$current_worker_count" =~ ^[0-9]+$ ]]; then
    log "WARNING: Could not determine current worker count, assuming 1"
    current_worker_count=1
fi

log "Current worker count is $current_worker_count."

# Step 4: Determine new worker count with hysteresis
# Scale UP thresholds (aggressive)
if (( queue_length <= 100 )); then
    new_worker_count=1
elif (( queue_length <= 250 )); then
    new_worker_count=2
elif (( queue_length <= 500 )); then
    new_worker_count=3
elif (( queue_length <= 1000 )); then
    new_worker_count=4
elif (( queue_length <= 2000 )); then
    new_worker_count=5
elif (( queue_length <= 3000 )); then
    new_worker_count=6
elif (( queue_length <= 5000 )); then
    new_worker_count=7
elif (( queue_length <= 7500 )); then
    new_worker_count=8
elif (( queue_length <= 10000 )); then
    new_worker_count=9
else
    new_worker_count=10
fi

# Scale DOWN to 1 worker if queue is low (less than 10 jobs)
# Otherwise, keep current worker count!
if [[ "$new_worker_count" -lt "$current_worker_count" ]]; then
    # Only downscale if queue has fewer than 10 jobs
    if [[ $queue_length -lt 10 ]]; then
        new_worker_count=1
    else
        # Keep current worker count if queue is 10 or more
        new_worker_count=$current_worker_count
    fi
fi

log "Target new worker count is $new_worker_count (based on queue length $queue_length and current worker count $current_worker_count)."

# Check if scaling is needed
if [[ "$new_worker_count" -eq "$current_worker_count" ]]; then
    log "No scaling needed. Current count matches target."
    exit 0
fi

# Log scaling decision
if [[ "$new_worker_count" -gt "$current_worker_count" ]]; then
    log "Scaling UP from $current_worker_count to $new_worker_count workers (queue: $queue_length)"
else
    log "Scaling DOWN from $current_worker_count to $new_worker_count workers (queue: $queue_length)"
fi

# Step 5: Update worker count
log "Updating worker instance count to $new_worker_count..."
if ! yq e '(.spec.workers[] | select(.name == "groupmuse-rails-worker") | .instance_count) = '"$new_worker_count" "$TEMP_DIR/$YAML_FILE" -i; then
    log "ERROR: Failed to update worker count"
    exit 1
fi

# Step 6: Upload updated spec
log "Uploading updated app spec to DigitalOcean..."
if ! curl -sf -X PUT "$DIGITALOCEAN_APP_URL" \
  -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  --data-binary "@$TEMP_DIR/$YAML_FILE" > /dev/null; then
    log "ERROR: Failed to upload app spec"
    exit 1
fi

# Record successful scaling time
date +%s > "$LAST_SCALE_FILE"

log "Successfully scaled workers from $current_worker_count to $new_worker_count"

