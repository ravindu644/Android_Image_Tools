#!/bin/bash
# Android Super Image Unpacker & Repacker - by @ravindu644
#
# A tool to handle sparse conversion, unpacking, and repacking of super.img.

set -e

# --- Global Settings & Color Codes ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"
TMP_DIR="" # Will be set by the script

# Locate the script's own directory to find the local bin folder.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BIN_DIR="${SCRIPT_DIR}/bin"

# If a local bin directory exists, add it to the beginning of the PATH.
# This makes the script use the local tools before any system-wide ones.
if [ -d "$BIN_DIR" ]; then
    export PATH="$BIN_DIR:$PATH"
fi

# --- Core Functions ---
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT INT TERM

print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌──────────────────────────────────────────────────┐"
    echo "│        Super Image Tools - by @ravindu644        │"
    echo "└──────────────────────────────────────────────────┘"
    echo -e "${RESET}"
}

# --- MODIFIED: Added --raw flag documentation ---
print_usage() {
    echo -e "\n${RED}${BOLD}Usage: $0 <unpack|repack> [options]${RESET}"
    echo
    echo -e "  ${BOLD}Unpack a super image:${RESET}"
    echo -e "    $0 unpack <path_to_super.img> <output_directory>"
    echo -e "    ${YELLOW}Example:${RESET} $0 unpack INPUT_IMAGES/super.img EXTRACTED_SUPER/my_super"
    echo
    echo -e "  ${BOLD}Repack a super image:${RESET}"
    echo -e "    $0 repack <path_to_session_dir> <output_super.img> [--raw]"
    echo -e "    ${YELLOW}Example (sparse):${RESET} $0 repack EXTRACTED_SUPER/my_super REPACKED_IMAGES/super_new.img"
    echo -e "    ${YELLOW}Example (raw):${RESET}    $0 repack EXTRACTED_SUPER/my_super REPACKED_IMAGES/super_raw.img --raw"
    exit 1
}

check_dependencies() {
    local missing=""
    for tool in simg2img lpdump lpunpack lpmake file; do
        if ! command -v "$tool" &>/dev/null; then
            missing+="$tool "
        fi
    done
    if [ -n "$missing" ]; then
        echo -e "${RED}Error: Missing required tools: ${BOLD}${missing}${RESET}"
        echo -e "${YELLOW}Please ensure these are installed and in your PATH.${RESET}"
        exit 1
    fi
}

# --- Unpack Logic (Unchanged) ---
parse_lpdump_and_save_config() {
    local lpdump_file="$1"
    local config_file="$2"

    echo -e "\n${BLUE}Parsing super image metadata...${RESET}"

    local super_device_size
    super_device_size=$(awk '/Block device table:/,EOF {if ($1 == "Size:") {print $2; exit}}' "$lpdump_file")

    echo "# Repack config for super image, generated on $(date)" > "$config_file"
    echo "METADATA_SLOTS=$(grep -m 1 "Metadata slot count:" "$lpdump_file" | awk '{print $NF}')" >> "$config_file"
    echo "SUPER_DEVICE_SIZE=$super_device_size" >> "$config_file"
    echo >> "$config_file"

    awk '
        /Partition table:/ { in_partition_table=1; next }
        /Super partition layout:/ { in_partition_table=0 }

        in_partition_table {
            if ($1 == "Name:")  { current_partition = $2 }
            if ($1 == "Group:") {
                group_name = $2
                partitions_in_group[group_name] = partitions_in_group[group_name] " " current_partition
            }
        }
        END {
            printf "LP_GROUPS=\""
            first=1
            for (group in partitions_in_group) {
                if (!first) { printf " " }
                printf "%s", group
                first=0
            }
            print "\""
            print ""

            for (group_name in partitions_in_group) {
                sub(/^ /, "", partitions_in_group[group_name])
                printf "LP_GROUP_%s_PARTITIONS=\"%s\"\n", group_name, partitions_in_group[group_name]
            }
        }
    ' "$lpdump_file" >> "$config_file"
    
    echo -e "${GREEN}[✓] Repack configuration saved.${RESET}"
}

run_unpack() {
    local super_image="$1"
    local output_dir="$2"
    
    output_dir=${output_dir%/}

    if [ ! -f "$super_image" ]; then
        echo -e "${RED}Error: Input file not found: '$super_image'${RESET}"; exit 1
    fi
    
    TMP_DIR=$(mktemp -d -t super_unpack_XXXXXX)
    mkdir -p "$output_dir"
    
    local raw_super_image="${TMP_DIR}/super.raw.img"

    echo -e "\n${BLUE}${BOLD}Starting unpack process for${RESET} ${BOLD}${super_image}...${RESET}"
    
    if file "$super_image" | grep -q "sparse"; then
        echo -e "\n${YELLOW}${BOLD}Sparse image detected. Converting to raw image...${RESET}"
        simg2img "$super_image" "$raw_super_image"
    else
        echo -e "\n${BLUE}Image is raw. Copying to temp directory...${RESET}"
        cp "$super_image" "$raw_super_image"
    fi

    echo -e "\n${BLUE}Dumping partition layout...${RESET}"
    lpdump "$raw_super_image" > "${TMP_DIR}/lpdump.txt"

    parse_lpdump_and_save_config "${TMP_DIR}/lpdump.txt" "${output_dir}/repack_info.txt"

    echo -e "\n${BLUE}Unpacking logical partitions...${RESET}"
    lpunpack --slot=0 "$raw_super_image" "$output_dir"

    echo -e "\n${GREEN}${BOLD}Unpack successful!${RESET}"
    echo -e "  - Logical partitions and config stored in: ${BOLD}${output_dir}/${RESET}"
}

# --- MODIFIED: Repack Logic ---
run_repack() {
    local session_dir="$1"
    local output_image="$2"
    local raw_flag="$3" # The third argument, if it exists

    # Default to creating a sparse image
    local create_sparse=true
    if [ "$raw_flag" == "--raw" ]; then
        create_sparse=false
        echo -e "\n${YELLOW}Raw output requested. The final image will not be sparse.${RESET}"
    fi

    session_dir=${session_dir%/}
    local config_file="${session_dir}/repack_info.txt"

    if [ ! -d "$session_dir" ] || [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Invalid session directory or missing 'repack_info.txt'.${RESET}"; exit 1
        exit 1
    fi
    
    echo -e "\n${BLUE}Starting repack process using session: ${BOLD}${session_dir}...${RESET}${RESET}"
    source "$config_file"

    local cmd="lpmake"
    cmd+=" --metadata-size 65536"
    cmd+=" --super-name super"
    cmd+=" --metadata-slots ${METADATA_SLOTS}"
    cmd+=" --device super:${SUPER_DEVICE_SIZE}"
    
    echo -e "\n${BLUE}Calculating new partition sizes and building command...${RESET}"
    
    if [ -z "$LP_GROUPS" ]; then
        echo -e "${RED}Error: No partition groups found in config file. Nothing to repack.${RESET}"
        exit 1
    fi

    local total_partitions_size=0

    for group in $LP_GROUPS; do
        local group_partitions_var="LP_GROUP_${group}_PARTITIONS"
        local partitions="${!group_partitions_var}"
        
        if [ -z "$partitions" ]; then
            continue
        fi

        local total_group_size=0
        declare -A current_partition_sizes
        
        for part in $partitions; do
            local part_img="${session_dir}/${part}.img"
            if [ ! -f "$part_img" ]; then
                echo -e "${RED}Error: Repacked image '${part_img}' for partition '${part}' not found!${RESET}"
                exit 1
            fi
            local size
            size=$(stat -c%s "$part_img")
            current_partition_sizes[$part]=$size
            total_group_size=$((total_group_size + size))
        done
        
        total_partitions_size=$((total_partitions_size + total_group_size))
        
        cmd+=" --group ${group}:${total_group_size}"
        
        for part in $partitions; do
            cmd+=" --partition ${part}:readonly:${current_partition_sizes[$part]}:${group}"
            cmd+=" --image ${part}=${session_dir}/${part}.img"
        done
    done
    
    if [ "$total_partitions_size" -gt "$SUPER_DEVICE_SIZE" ]; then
        local total_hr
        total_hr=$(numfmt --to=iec-i --suffix=B "$total_partitions_size")
        local device_hr
        device_hr=$(numfmt --to=iec-i --suffix=B "$SUPER_DEVICE_SIZE")
        
        echo -e "\n${RED}${BOLD}FATAL ERROR: The combined size of your repacked partitions is larger than the super device can hold.${RESET}"
        echo -e "  - Total Partition Size: ${YELLOW}${total_hr}${RESET}"
        echo -e "  - Super Device Capacity:  ${YELLOW}${device_hr}${RESET}"
        echo -e "\n${RED}To fix this, you need to either modify your project to remove the bloat or use the 'EROFS' filesystem with lz4/lz4hc compression for the logical partitions.${RESET}"
        exit 1
    fi
    
    # Conditionally add the --sparse flag
    if [ "$create_sparse" = true ]; then
        cmd+=" --sparse"
    fi
    cmd+=" --output ${output_image}"
    
    echo -e "\n${BOLD}Executing command:${RESET}"
    echo -e "$cmd\n"
    
    eval "$cmd"
    
    echo -e "\n${GREEN}${BOLD}Repack successful!${RESET}"
    if [ "$create_sparse" = true ]; then
        echo -e "  - New sparse super image created at: ${BOLD}${output_image}${RESET}"
    else
        echo -e "  - New raw super image created at: ${BOLD}${output_image}${RESET}"
    fi
}

# --- MODIFIED: Main Execution Logic ---
if [ "$#" -lt 1 ]; then
    print_usage
fi

ACTION="$1"

if [ "$ACTION" != "unpack" ] && [ "$ACTION" != "repack" ]; then
    print_banner
    echo -e "${RED}Error: Invalid action '${ACTION}'. Please use 'unpack' or 'repack'.${RESET}"
    print_usage
fi

# Argument count validation is now more flexible for the repack command
if [ "$ACTION" == "unpack" ] && [ "$#" -ne 3 ]; then
    print_banner
    echo -e "${RED}Error: 'unpack' requires exactly 2 arguments.${RESET}"
    print_usage
fi
if [ "$ACTION" == "repack" ] && { [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; }; then
    print_banner
    echo -e "${RED}Error: 'repack' requires 2 arguments, with an optional '--raw' flag.${RESET}"
    print_usage
fi

shift
print_banner
check_dependencies

case "$ACTION" in
    unpack)
        run_unpack "$1" "$2"
        ;;
    repack)
        # Pass all remaining arguments to the function
        run_repack "$@"
        ;;
esac

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
