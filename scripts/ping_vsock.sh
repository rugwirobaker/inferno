#!/bin/bash
# Path to the control socket
SOCK_PATH="control.sock"
DEFAULT_PORT=10002
TIMEOUT=2

PORT=${1:-$DEFAULT_PORT}

# Use netcat to connect to the control socket, issue the CONNECT command and request ping
RESPONSE=$( (echo "CONNECT $PORT"; sleep 1; echo -e "GET /v1/ping HTTP/1.1\nHost: firecracker\n\n") | timeout $TIMEOUT nc -U "$SOCK_PATH")

# Check the response for "ok" and set the exit code accordingly
if echo "$RESPONSE" | grep -q "ok"; then
  echo "Received ok"
  exit 0
else
  echo "Did not receive ok"
  exit 1
fi
