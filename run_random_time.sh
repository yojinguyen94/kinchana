#!/bin/bash

# Delay random from 0 to 720 minutes (12 hours)
DELAY_MINUTES=$(( RANDOM % 720 ))
echo "⏳ Sleeping for $DELAY_MINUTES minutes before running script..."
sleep "${DELAY_MINUTES}m"

bash /home/ubuntu/simulate_oci_user.sh
