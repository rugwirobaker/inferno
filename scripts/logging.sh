#!/bin/bash

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    return 1  # Return error code for better composability
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# Debug logging (disabled by default)
DEBUG=${DEBUG:-0}
debug() {
    if [[ "${DEBUG}" -eq 1 ]]; then
        echo -e "[DEBUG] $1" >&2
    fi
}

# Function to handle script errors with line numbers
handle_error() {
    local line_no=$1
    local error_code=$2
    error "Error on line ${line_no}: Command exited with status ${error_code}"
}

# Set up error handling
set_error_handlers() {
    set -euo pipefail
    trap 'handle_error ${LINENO} $?' ERR
}