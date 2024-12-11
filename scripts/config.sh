#!/bin/bash

# Default values
DEFAULT_OUTBOUND_INTERFACE="eth0"

# Try to automatically detect the main outbound interface
detect_outbound_interface() {
    # Look for the interface with default route
    local interface
    interface=$(ip route show default | grep -Po '(?<=dev )[^ ]+' | head -1)
    
    if [[ -n "$interface" ]]; then
        echo "$interface"
    else
        echo "$DEFAULT_OUTBOUND_INTERFACE"
    fi
}

# Environment variable can override the detected interface
OUTBOUND_INTERFACE=${INFERNO_OUTBOUND_INTERFACE:-$(detect_outbound_interface)}