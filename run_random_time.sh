#!/bin/bash

DELAY_MINUTES=$(( RANDOM % 720 ))
echo "⏳ Sleeping for $DELAY_MINUTES minutes before running script..."
sleep "${DELAY_MINUTES}m"

bash ./simulate_oci_user.sh
