#!/bin/bash

# Source shared logging utilities
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"

# Enable strict error handling
set_error_handlers

# List of required dependencies and their versions (if applicable)
DEPENDENCIES=(
    "ip"        # iproute2 package
    "nanoid"    # for generating random identifiers
    "jq"        # JSON processing
    "nft"       # nftables
    "sqlite3"   # database operations
)

# Optional dependencies that enhance functionality
OPTIONAL_DEPENDENCIES=(
    "haproxy"   # load balancing (optional)
)

check_dependency() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "missing"
        return 1
    fi
    
    # Get version information if available
    case "$cmd" in
        nft)
            echo "$(nft --version 2>&1 | head -n1)"
            ;;
        sqlite3)
            echo "$(sqlite3 --version | cut -d' ' -f1)"
            ;;
        haproxy)
            echo "$(haproxy -v 2>&1 | head -n1 | cut -d' ' -f3)"
            ;;
        *)
            echo "installed"
            ;;
    esac
    return 0
}

verify_dependencies() {
    local mode="$1"  # can be "check" or "install-info"
    local missing=0
    local status
    
    log "Checking Required Dependencies:"
    echo "---------------------"
    for dep in "${DEPENDENCIES[@]}"; do
        printf "%-15s: " "$dep"
        status=$(check_dependency "$dep")
        if [ $? -eq 0 ]; then
            echo "$status"
        else
            echo "MISSING"
            case "$dep" in
                ip)
                    warn "  Install with: sudo apt-get install iproute2"
                    ;;
                nanoid)
                    warn "  Install with: npm install -g nanoid-cli"
                    ;;
                jq)
                    warn "  Install with: sudo apt-get install jq"
                    ;;
                nft)
                    warn "  Install with: sudo apt-get install nftables"
                    ;;
                sqlite3)
                    warn "  Install with: sudo apt-get install sqlite3"
                    ;;
            esac
            missing=$((missing + 1))
        fi
    done

    log "Checking Optional Dependencies:"
    echo "---------------------"
    for dep in "${OPTIONAL_DEPENDENCIES[@]}"; do
        printf "%-15s: " "$dep"
        status=$(check_dependency "$dep")
        if [ $? -eq 0 ]; then
            echo "$status"
        else
            echo "MISSING (optional)"
            case "$dep" in
                haproxy)
                    warn "  Install with: sudo apt-get install haproxy"
                    ;;
            esac
        fi
    done

    if [ $missing -gt 0 ]; then
        error "Missing $missing required dependencies."
        if [ "$mode" = "check" ]; then
            return 1
        fi
    else
        log "All required dependencies are installed."
    fi
    return 0
}

# Function to generate installation script
generate_install_script() {
    local missing_deps=()
    
    for dep in "${DEPENDENCIES[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -eq 0 ]; then
        log "All required dependencies are already installed."
        return 0
    fi
    
    log "Generating installation script..."
    
    echo "#!/bin/bash"
    echo "# Generated installation script for vm-network dependencies"
    echo
    echo "set -e"
    echo
    echo "echo 'Installing required dependencies...'"
    echo
    
    for dep in "${missing_deps[@]}"; do
        case "$dep" in
            ip)
                echo "echo 'Installing iproute2...'"
                echo "sudo apt-get install -y iproute2"
                ;;
            nanoid)
                echo "echo 'Installing nanoid-cli...'"
                echo "if ! command -v npm >/dev/null 2>&1; then"
                echo "    echo 'Installing nodejs and npm first...'"
                echo "    sudo apt-get install -y nodejs npm"
                echo "fi"
                echo "sudo npm install -g nanoid-cli"
                ;;
            jq)
                echo "echo 'Installing jq...'"
                echo "sudo apt-get install -y jq"
                ;;
            nft)
                echo "echo 'Installing nftables...'"
                echo "sudo apt-get install -y nftables"
                ;;
            sqlite3)
                echo "echo 'Installing sqlite3...'"
                echo "sudo apt-get install -y sqlite3"
                ;;
        esac
        echo
    done
    
    echo "echo 'All dependencies have been installed.'"
    echo "echo 'Please run \"vm-network check\" to verify the installation.'"
    
    log "Installation script generated successfully."
}