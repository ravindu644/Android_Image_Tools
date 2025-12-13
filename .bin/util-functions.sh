# Color codes
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

# Print banner
print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌──────────────────────────────────────────────────┐"
    echo "│     Android Image Tools - by @ravindu644         │"
    echo "└──────────────────────────────────────────────────┘"
    echo -e "${RESET}"
}

# Detect OS type
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID_LIKE" == *debian* ]] || [[ "$ID" == "ubuntu" ]] || [[ "$ID" == "debian" ]]; then
            OS_TYPE="debian"
        elif [[ "$ID_LIKE" == *rhel* ]] || [[ "$ID" == "fedora" ]]; then
            OS_TYPE="rhel"
        else
            echo -e "${RED}Unsupported Operating System.${RESET}"
            exit 1
        fi
    else
        echo -e "${RED}Cannot detect OS.${RESET}"
        exit 1
    fi
}

check_dependencies() {
    local missing_pkgs=()
    local erofs_utils_missing=false

    if [ "$OS_TYPE" = "debian" ]; then
        local REQUIRED_PACKAGES=("android-sdk-libsparse-utils" "build-essential" "automake" "autoconf" "libtool" "pkg-config" "git" "fuse3" "e2fsprogs" "pv" "liblz4-dev" "uuid-dev" "libfuse3-dev" "fuse3" "f2fs-tools" "fuse2fs" "attr" "zlib1g-dev" "rsync")
        local check_cmd="dpkg -s"
        local install_cmd="apt"
    elif [ "$OS_TYPE" = "rhel" ]; then
        local REQUIRED_PACKAGES=("android-tools" "gcc" "make" "automake" "autoconf" "libtool" "pkgconf" "git" "fuse3" "e2fsprogs" "pv" "lz4-devel" "libuuid-devel" "fuse3-devel" "fuse3" "f2fs-tools" "attr" "zlib-ng-compat-devel" "rsync")
        local check_cmd="rpm -q"
        local install_cmd="dnf"
    fi

    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! $check_cmd "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    # Check for erofs-utils with FUSE support
    if ! command -v mkfs.erofs &>/dev/null || ! command -v erofsfuse &>/dev/null; then
        erofs_utils_missing=true
    fi

    if [ ${#missing_pkgs[@]} -eq 0 ] && [ "$erofs_utils_missing" = false ]; then
        return 0 # All dependencies are present, exit silently
    fi

    # If we reach here, some dependencies are missing.
    clear
    print_banner
    if [ "$OS_TYPE" = "debian" ]; then
        echo -e "${RED}Debian Based host found...${RESET}"
    elif [ "$OS_TYPE" = "rhel" ]; then
        echo -e "${RED}Fedora Based host found...${RESET}"
    fi
    echo -e "\n${RED}${BOLD}Warning: Missing required dependencies.${RESET}"

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}The following packages are missing:${RESET}"
        echo "  - ${missing_pkgs[*]}"
    fi

    if [ "$erofs_utils_missing" = true ]; then
        echo -e "\n${YELLOW}The 'erofs-utils' build tools are also missing.${RESET}"
    fi

    read -rp "$(echo -e "\n${BLUE}Do you want to attempt automatic installation? (y/N): ${RESET}")" choice

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}Starting automatic installation...${RESET}"
        set -e

        if [ ${#missing_pkgs[@]} -gt 0 ]; then
            local unique_pkgs=$(echo "${missing_pkgs[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')
            echo -e "\n${BLUE}Updating package lists...${RESET}"
            sudo $install_cmd update
            echo -e "\n${BLUE}Installing required packages: $unique_pkgs${RESET}"
            sudo $install_cmd install -y $unique_pkgs
        fi

        if [ "$erofs_utils_missing" = true ]; then
            echo -e "\n${BLUE}Cloning and compiling 'erofs-utils'...${RESET}"
            local erofs_tmp_dir
            erofs_tmp_dir=$(mktemp -d)
            git clone https://github.com/erofs/erofs-utils.git "$erofs_tmp_dir"
            cd "$erofs_tmp_dir"
            ./autogen.sh
            ./configure --enable-fuse
            make
            sudo make install
            cd "$SCRIPT_DIR"
            rm -rf "$erofs_tmp_dir"
            echo -e "${GREEN}'erofs-utils' installed successfully.${RESET}"
        fi

        set +e
        echo -e "\n${GREEN}${BOLD}[✓] All dependencies should now be installed.${RESET}"
        read -rp "Press Enter to continue..."
    else
        echo -e "\n${YELLOW}Automatic installation declined.${RESET}"
        echo -e "Please install the dependencies manually and re-run the script."
        exit 1
    fi
}
