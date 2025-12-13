#!/bin/bash
# Android Super Image Unpacker & Repacker - by @ravindu644
#
# A tool to handle sparse conversion, unpacking, and repacking of super.img.

set -e

# --- Global Settings & Color Codes ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"

# Save original SELinux status and set to permissive for proper operations
ORIGINAL_SELINUX=$(getenforce 2>/dev/null || echo "Disabled")
if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
    setenforce 0
fi

# Locate the script's own directory to find the local bin folder.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BIN_DIR="${SCRIPT_DIR}" # Modified by user for .bin structure
PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
TMP_DIR="$PROJECT_ROOT/.tmp"

# Ensure .tmp directory exists
mkdir -p "$TMP_DIR"

if [ -d "$BIN_DIR" ]; then
    export PATH="$BIN_DIR:$PATH"
fi

# --- Core Functions ---
cleanup() {
    # Only cleanup temporary subdirectories, not the entire .tmp directory
    # (it may contain other temporary files from other processes)
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        # Only remove if it's a temporary subdirectory (contains super_unpack_ or super_repack_)
        if [[ "$TMP_DIR" == *"super_unpack_"* ]] || [[ "$TMP_DIR" == *"super_repack_"* ]]; then
            rm -rf "$TMP_DIR"
        fi
    fi

    # Restore original SELinux status
    if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
        setenforce 1 2>/dev/null || true
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

    # Detect virtual-ab flag from header flags
    local virtual_ab_flag="false"
    if grep -q "Header flags:.*virtual_ab_device" "$lpdump_file"; then
        virtual_ab_flag="true"
        echo -e "${BLUE}Detected virtual A/B partition layout.${RESET}"
    fi

    # Validate metadata slots
    local metadata_slots
    metadata_slots=$(grep -m 1 "Metadata slot count:" "$lpdump_file" | awk '{print $NF}')
    [ -z "$metadata_slots" ] && { echo -e "${RED}Error: Could not determine metadata slot count.${RESET}"; exit 1; }

    echo "# Repack config for super image, generated on $(date)" > "$config_file"
    echo "METADATA_SLOTS=$metadata_slots" >> "$config_file"
    echo "SUPER_DEVICE_SIZE=$super_device_size" >> "$config_file"
    echo "VIRTUAL_AB=$virtual_ab_flag" >> "$config_file"

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

            for (group_name in partitions_in_group) {
                sub(/^ /, "", partitions_in_group[group_name])
                printf "LP_GROUP_%s_PARTITIONS=\"%s\"\n", group_name, partitions_in_group[group_name]
            }
        }
    ' "$lpdump_file" >> "$config_file"

    # Strip <none> values from config file (replace =<none> with =)
    sed -i 's/=<none>$/=/' "$config_file"

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

    TMP_DIR=$(mktemp -d -p "$TMP_DIR" super_unpack_XXXXXX)

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
    # Ensure .metadata directory exists first
    mkdir -p "${output_dir}/../.metadata"
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

    # Set default virtual-ab flag if not present in config (for backward compatibility)
    VIRTUAL_AB="${VIRTUAL_AB:-false}"

    local cmd="lpmake"
    cmd+=" --metadata-size 65536"
    cmd+=" --super-name super"
    cmd+=" --metadata-slots ${METADATA_SLOTS}"
    cmd+=" --device super:${SUPER_DEVICE_SIZE}"

    # Add virtual-ab flag if detected
    if [ "$VIRTUAL_AB" = "true" ]; then
        cmd+=" --virtual-ab"
        echo -e "${BLUE}Using virtual A/B partition layout (groups share physical space).${RESET}"
    fi

    echo -e "\n${BLUE}Calculating new partition sizes and building command...${RESET}"

    if [ -z "$LP_GROUPS" ]; then
        echo -e "${RED}Error: No partition groups found in config file. Nothing to repack.${RESET}"
        exit 1
    fi

    # Calculate maximum possible group size based on super device size minus metadata overhead
    # Formula: Max Group Size = Super Device Size - Reserved Space - Metadata Size
    # LP_PARTITION_RESERVED_BYTES = 4096 bytes (reserved at start to avoid boot sector)
    # LP_METADATA_SIZE = 65536 bytes per slot
    # For virtual-AB: All groups share physical space, so they can all use the full max size
    # For non-virtual-AB: Groups may need to share space, but typically one group uses full max size
    local LP_PARTITION_RESERVED_BYTES=4096
    local LP_METADATA_SIZE=65536
    local metadata_slots="${METADATA_SLOTS:-2}"
    local total_metadata_size=$((LP_METADATA_SIZE * metadata_slots))
    local max_group_size=$((SUPER_DEVICE_SIZE - LP_PARTITION_RESERVED_BYTES - total_metadata_size))

    # Collect partition sizes
    declare -A partition_sizes
    declare -A group_sizes

    for group in $LP_GROUPS; do
        local group_partitions_var="LP_GROUP_${group}_PARTITIONS"
        local partitions="${!group_partitions_var}"
        [ -z "$partitions" ] && continue

        # Calculate partition sizes
        for part in $partitions; do
            local part_img="${session_dir}/${part}.img"
            [ ! -f "$part_img" ] && {
                echo -e "${RED}Error: Repacked image '${part_img}' not found!${RESET}"
                echo -e "${RED}Expected partition image for: ${BOLD}${part}${RESET}"
                exit 1
            }

            local size=$(stat -c%s "$part_img" 2>/dev/null)
            [ -z "$size" ] && { echo -e "${RED}Error: Could not determine size of '${part_img}'${RESET}"; exit 1; }

            # Handle empty partitions: 0 bytes for virtual-ab, 4096 for non-virtual-ab
            [ "$size" -eq 0 ] && size=$([ "$VIRTUAL_AB" = "true" ] && echo 0 || echo 4096)

            partition_sizes[$part]=$size
        done

        # All groups use the maximum possible size (not sum of partitions)
        group_sizes[$group]=$max_group_size
    done

    # Build lpmake command with groups and partitions
    local total_partitions_size=0
    # Calculate total size of ALL partition images (including 0-byte partitions)
    local total_all_partitions_size=0
    for group in $LP_GROUPS; do
        local group_partitions_var="LP_GROUP_${group}_PARTITIONS"
        local partitions="${!group_partitions_var}"
        [ -z "$partitions" ] && continue

        cmd+=" --group ${group}:${group_sizes[$group]}"
        [ "${group_sizes[$group]}" -gt "$total_partitions_size" ] && total_partitions_size=${group_sizes[$group]}

        for part in $partitions; do
            cmd+=" --partition ${part}:none:${partition_sizes[$part]}:${group}"
            # Sum up all partition sizes (including 0-byte partitions) for validation
            total_all_partitions_size=$((total_all_partitions_size + partition_sizes[$part]))
            # Empty partitions (0 bytes) don't need --image flag for virtual-ab
            # For non-virtual-ab or non-empty partitions, always include --image
            if [ "$VIRTUAL_AB" != "true" ] || [ "${partition_sizes[$part]}" -gt 0 ]; then
                cmd+=" --image ${part}=${session_dir}/${part}.img"
            fi
        done
    done

    # Validate that sum of all partition sizes doesn't exceed max group size
    if [ "$total_all_partitions_size" -gt "$max_group_size" ]; then
        local total_hr
        total_hr=$(numfmt --to=iec-i --suffix=B "$total_all_partitions_size")
        local max_group_hr
        max_group_hr=$(numfmt --to=iec-i --suffix=B "$max_group_size")

        echo -e "\n${RED}${BOLD}FATAL ERROR: The combined size of your repacked partitions is larger than the maximum group size can hold.${RESET}"
        echo -e "  - Total Partition Size: ${YELLOW}${total_hr}${RESET}"
        echo -e "  - Maximum Group Size:  ${YELLOW}${max_group_hr}${RESET}"
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

    # Transfer ownership to actual user if running under sudo
    if [ -n "$SUDO_USER" ] && [ -f "$output_image" ]; then
        chown "$SUDO_USER:$SUDO_USER" "$output_image"
    fi

    echo -e "\n${GREEN}${BOLD}Repack successful!${RESET}"
}

# --- MAIN EXECUTION LOGIC ---

# Initialize variables for arguments and flags
ACTION=""
POSITIONAL_ARGS=()
INTERACTIVE_MODE=true

# This loop correctly separates global flags from positional arguments,
# regardless of their order.
while (( "$#" )); do
  case "$1" in
    --no-banner)
      INTERACTIVE_MODE=false
      shift # Consume the flag
      ;;
    --raw)
      POSITIONAL_ARGS+=("$1")
      shift # Consume the flag
      ;;
    -*)
      echo -e "${RED}Error: Unknown global option $1${RESET}" >&2
      print_usage
      ;;
    *)
      # Not a flag, so it must be a positional argument.
      POSITIONAL_ARGS+=("$1")
      shift # Consume the argument
      ;;
  esac
done

# Now, POSITIONAL_ARGS contains only the action and its own arguments
ACTION=${POSITIONAL_ARGS[0]:-}
# Use array slicing to get the true arguments for the action
ACTION_ARGS=("${POSITIONAL_ARGS[@]:1}")

# Validate action
if [ "$ACTION" != "unpack" ] && [ "$ACTION" != "repack" ]; then
    if [ "$INTERACTIVE_MODE" = true ]; then print_banner; fi
    echo -e "${RED}Error: Invalid action. Please use 'unpack' or 'repack'.${RESET}"
    print_usage
fi

# Validate argument counts for each action
if [ "$ACTION" == "unpack" ] && [ "${#ACTION_ARGS[@]}" -ne 2 ]; then
    if [ "$INTERACTIVE_MODE" = true ]; then print_banner; fi
    echo -e "${RED}Error: 'unpack' requires exactly 2 arguments: <super_image> and <output_directory>.${RESET}"
    print_usage
fi
if [ "$ACTION" == "repack" ] && { [ "${#ACTION_ARGS[@]}" -ne 2 ] && [ "${#ACTION_ARGS[@]}" -ne 3 ]; }; then
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
        run_unpack "${ACTION_ARGS[@]}"
        ;;
    repack)
        run_repack "${ACTION_ARGS[@]}"
        ;;
esac

echo -e "\n${GREEN}${BOLD}Done!${RESET}\n"
