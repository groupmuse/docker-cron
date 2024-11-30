#!/bin/bash

# Config
DIGITALOCEAN_APP_URL="https://api.digitalocean.com/v2/apps/fe1dbd39-84b1-41f1-9ca2-25e974b691ff"
QUEUE_API_URL="https://www.groupmuse.com/cron/queue_size?api_key=$CRON_API_KEY"
YAML_FILE="appspec.yaml"

# Step 1: GET the full app spec in YAML format and save to a temporary file
echo "Fetching full app spec from DigitalOcean..."
curl -s -X GET "$DIGITALOCEAN_APP_URL" \
  -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -o fullspec.yaml

echo "Full app spec saved to fullspec.yaml."

# Step 2: Extract `app.spec` and save to appspec.yaml wrapped in a `spec` key
echo "Extracting app.spec..."
#yq e '.app.spec' fullspec.yaml > $YAML_FILE
yq e '{ "spec": .app.spec }' fullspec.yaml > $YAML_FILE
echo "Extracted app.spec saved to $YAML_FILE."

# Step 3: Get the current queue length
echo "Fetching queue length..."
queue_length=$(curl -s $QUEUE_API_URL | sed -n 's/.*"pending":\([0-9]*\).*/\1/p')
echo "Queue length is $queue_length."

# Step 4: Decide the new worker count based on queue length
if [ "$queue_length" -le 100 ]; then
  new_worker_count=1
elif [ "$queue_length" -le 250 ]; then
  new_worker_count=2
elif [ "$queue_length" -le 400 ]; then
  new_worker_count=3
elif [ "$queue_length" -le 600 ]; then
  new_worker_count=4
elif [ "$queue_length" -gt 600 ]; then
  new_worker_count=5
else
  new_worker_count=1 # default to 1 worker
fi
echo "Target new worker count is $new_worker_count."

# Check how many workers are currently running
current_worker_count=$(yq e '.spec.workers[] | select(.name == "groupmuse-rails-worker").instance_count' $YAML_FILE)
echo "Current worker count is $current_worker_count."

# If target worker count is current worker count, don't do anything
if [ "$new_worker_count" -eq "$current_worker_count" ]; then
  echo "New worker count is equal to current worker count. No need to scale. Exiting..."
  exit 0
fi

# Don't allow scaling down to 2+ workers, only 0 or 1
if [ "$new_worker_count" -lt "$current_worker_count" ] && [ "$new_worker_count" -gt 1 ]; then
  echo "Downscaling to $new_worker_count workers is not allowed (only 0 and 1 are). Exiting..."
  exit 0
fi

# Step 5: Update the workers' instance_count in the YAML
echo "Updating worker instance counts in $YAML_FILE..."
yq e '.spec.workers[] |= select(.name == "groupmuse-rails-worker").instance_count = '"$new_worker_count" $YAML_FILE -i

echo "Updated app spec saved to $YAML_FILE."

# Step 6: PUT the updated YAML back to DigitalOcean
echo "Uploading updated app spec to DigitalOcean..."
curl -s -X PUT "$DIGITALOCEAN_APP_URL" \
  -H "Authorization: Bearer $DIGITALOCEAN_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  --data-binary @appspec.yaml > /dev/null

# Step 7: Clean up
rm fullspec.yaml
rm $YAML_FILE
echo "Cleaned up temporary files."

echo "App spec updated successfully!"
