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
BIN_DIR="${SCRIPT_DIR}" # Modified by user for .bin structure

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

# --- Unpack Logic ---
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

# --- Unpack Logic ---
run_unpack() {
    local super_image="$1"
    local output_dir="$2"
    
    output_dir=${output_dir%/}

    if [ ! -f "$super_image" ]; then
        echo -e "${RED}Error: Input file not found: '$super_image'${RESET}"; exit 1
    fi
    
    TMP_DIR=$(mktemp -d -t super_unpack_XXXXXX)
    
    local raw_super_image="${TMP_DIR}/super.raw.img"
    local config_file="${TMP_DIR}/repack_info.txt"

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

    parse_lpdump_and_save_config "${TMP_DIR}/lpdump.txt" "$config_file"

    echo -e "\n${BLUE}Unpacking logical partitions...${RESET}"
    
    # Run lpunpack in the background and capture its output to prevent screen clutter.
    lpunpack --slot=0 "$raw_super_image" "$output_dir" >/dev/null 2>&1 &
    local pid=$!
    
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local spin=0

    # DON'T TOUCH \r\033[K
    while kill -0 $pid 2>/dev/null; do
        echo -ne "\r\033[K${YELLOW}Extracting all logical partitions... ${spinner[$((spin++ % 10))]}"
        sleep 0.1
    done

    wait $pid
    if [ $? -ne 0 ]; then
        echo -e "\r\033[K${RED}FAILED to unpack logical partitions [✗]"
        echo -e "${RED}The super image may be corrupt or an lpunpack error occurred.${RESET}"
        exit 1
    else
        echo -e "\r\033[K${GREEN}Successfully extracted all logical partitions [✓]"
    fi

    # Move the config file alongside the logical partitions' destination
    mv "$config_file" "${output_dir}/../.metadata/super_repack_info.txt"
}

# --- Repack Logic ---
run_repack() {
    local session_dir="$1"
    local output_image="$2"
    local raw_flag="$3"

    local create_sparse=true
    if [ "$raw_flag" == "--raw" ]; then
        create_sparse=false
        echo -e "\n${YELLOW}Raw output requested. The final image will not be sparse.${RESET}"
    fi

    session_dir=${session_dir%/}
    local config_file="${session_dir}/../.metadata/super_repack_info.txt"

    if [ ! -d "$session_dir" ] || [ ! -f "$config_file" ]; then
        echo -e "${RED}Error: Invalid session directory or missing metadata.${RESET}"; exit 1
    fi
    
    echo -e "\n${BLUE}Starting repack process using partitions from: ${BOLD}${session_dir}${RESET}"
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
        
        if [ -z "$partitions" ]; then continue; fi

        local total_group_size=0
        declare -A current_partition_sizes
        
        for part in $partitions; do
            local part_img="${session_dir}/${part}.img"
            if [ ! -f "$part_img" ]; then
                echo -e "${RED}Error: Repacked image '${part_img}' not found!${RESET}"
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
    
    if [ "$create_sparse" = true ]; then
        cmd+=" --sparse"
    fi
    cmd+=" --output ${output_image}"
    
    echo -e "\n${BOLD}Executing command:${RESET}"
    echo -e "$cmd\n"
    
    eval "$cmd"
    
    echo -e "\n${GREEN}${BOLD}Repack successful!${RESET}"
}


# --- START OF NEW, ROBUST MAIN EXECUTION LOGIC ---

# Initialize variables for arguments and flags
ACTION=""
ARGS=()
INTERACTIVE_MODE=true

# Parse arguments and flags
while (( "$#" )); do
  case "$1" in
    --no-banner)
      INTERACTIVE_MODE=false
      shift
      ;;
    -*)
      echo -e "${RED}Error: Unknown option $1${RESET}" >&2
      print_usage
      ;;
    *)
      if [ -z "$ACTION" ]; then
        ACTION="$1"
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

# Validate action
if [ "$ACTION" != "unpack" ] && [ "$ACTION" != "repack" ]; then
    if [ "$INTERACTIVE_MODE" = true ]; then print_banner; fi
    echo -e "${RED}Error: Invalid action. Please use 'unpack' or 'repack'.${RESET}"
    print_usage
fi

# Validate argument counts for each action
if [ "$ACTION" == "unpack" ] && [ "${#ARGS[@]}" -ne 2 ]; then
    if [ "$INTERACTIVE_MODE" = true ]; then print_banner; fi
    echo -e "${RED}Error: 'unpack' requires exactly 2 arguments: <super_image> and <output_directory>.${RESET}"
    print_usage
fi
if [ "$ACTION" == "repack" ] && { [ "${#ARGS[@]}" -ne 2 ] && [ "${#ARGS[@]}" -ne 3 ]; }; then
    if [ "$INTERACTIVE_MODE" = true ]; then print_banner; fi
    echo -e "${RED}Error: 'repack' requires 2 arguments with an optional '--raw' flag.${RESET}"
    print_usage
fi

# Conditionally print banner and run main logic
if [ "$INTERACTIVE_MODE" = true ]; then
    print_banner
fi
check_dependencies

case "$ACTION" in
    unpack)
        run_unpack "${ARGS[0]}" "${ARGS[1]}"
        ;;
    repack)
        run_repack "${ARGS[0]}" "${ARGS[1]}" "${ARGS[2]}"
        ;;
esac

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
