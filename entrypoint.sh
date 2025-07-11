#!/bin/sh

env >> /etc/environment

# Start tailing the scale_workers log in the background
touch /tmp/scale_workers.log
tail -F /tmp/scale_workers.log &

# execute CMD
echo "$@"
exec "$@"
