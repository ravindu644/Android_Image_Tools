#!/bin/bash
# EROFS Image Repacker Script with Enhanced Attribute Restoration

# --- Argument Parsing & Variable Setup ---
EXTRACT_DIR=""
OUTPUT_IMG=""

# Default values for non-interactive mode
FS_CHOICE=""
EXT4_MODE=""
EXT4_OVERHEAD_PERCENT="" # Now empty by default
EROFS_COMP=""
EROFS_LEVEL=""
NO_BANNER=false
QUIET=false

# Parse positional arguments first
if [ $# -ge 1 ]; then
    EXTRACT_DIR="$1"
fi
if [ $# -ge 2 ] && [[ "$2" != --* ]]; then
    OUTPUT_IMG="$2"
    shift 2
else
    shift 1
fi

# Non-interactive argument parsing
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --fs) FS_CHOICE="$2"; shift; shift ;;
        --ext4-mode) EXT4_MODE="$2"; shift; shift ;;
        --ext4-overhead-percent) EXT4_OVERHEAD_PERCENT="$2"; shift; shift ;;
        --erofs-compression) EROFS_COMP="$2"; shift; shift ;;
        --erofs-level) EROFS_LEVEL="$2"; shift; shift ;;
        --no-banner) NO_BANNER=true; shift ;;
        --quiet) QUIET=true; shift ;;
        *) shift ;;
    esac
done

set -e

# Define color codes
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$SCRIPT_DIR/.tmp"

# Banner function
print_banner() {
  if [ "$NO_BANNER" = false ]; then
    echo -e "${BOLD}${GREEN}"
    echo "┌───────────────────────────────────────────┐"
    echo "│         Repack EROFS - by @ravindu644     │"
    echo "└───────────────────────────────────────────┘"
    echo -e "${RESET}"
  fi
}

print_banner

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"
  exit 1
fi

# Save original SELinux status and set to permissive for proper context restoration
ORIGINAL_SELINUX=$(getenforce 2>/dev/null || echo "Disabled")
if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
    setenforce 0
fi

# Check if mkfs.erofs is installed
if ! command -v mkfs.erofs &> /dev/null; then
  echo -e "${RED}mkfs.erofs command not found. Please install erofs-utils package.${RESET}"
  echo -e "For Ubuntu/Debian: sudo apt install erofs-utils"
  echo -e "For other distributions, check your package manager.${RESET}"
  exit 1
fi

# Check if extracted folder is provided
if [ -z "$EXTRACT_DIR" ]; then
  script_name=$(basename "$0")
  echo -e "${YELLOW}Usage: $script_name <extracted_folder_path> [output_image.img] [options]${RESET}"
  echo -e "Example: $script_name extracted_vendor"
  exit 1
fi

# Determine output image name if not provided
if [ -z "$OUTPUT_IMG" ]; then
    PARTITION_NAME=$(basename "$EXTRACT_DIR" | sed 's/^extracted_//')
    OUTPUT_IMG="${PARTITION_NAME}_repacked.img"
fi

REPACK_INFO="${EXTRACT_DIR}/.repack_info"
PARTITION_NAME=$(basename "$EXTRACT_DIR" | sed 's/^extracted_//')
FS_CONFIG_FILE="${REPACK_INFO}/fs-config.txt"
FILE_CONTEXTS_FILE="${REPACK_INFO}/file_contexts.txt"

# Add temp directory definition and cleanup function
TEMP_ROOT="$TMP_DIR/repack-erofs"
WORK_DIR="${TEMP_ROOT}/${PARTITION_NAME}_work"
MOUNT_POINT=""

# Safely load metadata from file (handles values like <none>)
load_metadata() {
    local metadata_file="$1"
    [ ! -f "$metadata_file" ] && return
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        export "${key}"="${value}"
    done < "$metadata_file"
}

cleanup() {
    if [ "$NO_BANNER" = false ]; then
        echo -e "\n${YELLOW}Cleaning up temporary files...${RESET}"
    fi

    # First unmount any mounted filesystems
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sync
        umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null
    fi

    # Then remove temporary files
    [ -d "$TEMP_ROOT" ] && rm -rf "$TEMP_ROOT"
    [ -f "$OUTPUT_IMG.tmp" ] && rm -f "$OUTPUT_IMG.tmp"

    # Restore original SELinux status
    if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
        setenforce 1 2>/dev/null || true
    fi

    if [ "$NO_BANNER" = false ]; then
        echo -e "${GREEN}Cleanup completed.${RESET}"
    fi
}

# Register cleanup for interrupts and errors. The trap will handle the exit.
trap 'cleanup; exit 1' INT TERM EXIT

# Check if repack info exists
if [ ! -d "$REPACK_INFO" ]; then
  echo -e "${RED}Error: Repack info directory not found at ${REPACK_INFO}${RESET}"
  echo -e "${RED}This directory does not appear to be created by the unpack script.${RESET}"
  exit 1
fi

# Remove trailing slash if present
EXTRACT_DIR=${EXTRACT_DIR%/}

# Check if extracted directory exists
if [ ! -d "$EXTRACT_DIR" ]; then
  echo -e "${RED}Error: Directory '$EXTRACT_DIR' not found.${RESET}"
  exit 1
fi

find_matching_pattern() {
    local path="$1"
    local config_file="$2"
    local pattern=""

    # If the path is the root itself, handle it directly
    if [ "$path" = "/" ]; then
        echo "$(grep -E '^/ ' "$config_file" | head -n1)"
        return
    fi

    local parent_dir
    parent_dir=$(dirname "$path")

    # Loop upwards from the immediate parent until we find an ancestor in the metadata
    while true; do
        # Check if this parent exists in the config file.
        pattern=$(grep -E "^${parent_dir} " "$config_file" | head -n1)
        if [ -n "$pattern" ]; then
            echo "$pattern"
            return
        fi

        # If we have reached the root directory and haven't found a match, break the loop
        if [ "$parent_dir" = "/" ]; then
            break
        fi

        # Go up one level
        parent_dir=$(dirname "$parent_dir")
    done

    # As a final fallback, use the root's entry if no other ancestor was found
    echo "$(grep -E '^/ ' "$config_file" | head -n1)"
}

restore_attributes() {
    echo -e "\n${BLUE}Initializing permission restoration...${RESET}"
    echo -e "${BLUE}┌─ Analyzing filesystem structure...${RESET}"

    # Process symlinks first
    if [ -f "${REPACK_INFO}/symlink_info.txt" ]; then
        while IFS=' ' read -r path target uid gid mode context || [ -n "$path" ]; do
            [ -z "$path" ] && continue
            [[ "$path" =~ ^#.*$ ]] && continue

            full_path="$1$path"
            [ ! -L "$full_path" ] && ln -sf "$target" "$full_path"
            chown -h "$uid:$gid" "$full_path" 2>/dev/null || true

            # Try to set context from symlink_info, otherwise fall back to file_contexts
            if [ -n "$context" ] && [ "$context" != "?" ]; then
                setfattr -h -n security.selinux -v "$context" "$full_path" 2>/dev/null || true
            else
                # Look up context using the same pattern matching as for files/directories
                context_pattern=$(find_matching_pattern "$path" "$FILE_CONTEXTS_FILE")
                fallback_context=$(echo "$context_pattern" | awk '{$1=""; print $0}' | sed 's/^ //')
                [ -n "$fallback_context" ] && setfattr -h -n security.selinux -v "$fallback_context" "$full_path" 2>/dev/null || true
            fi
        done < "${REPACK_INFO}/symlink_info.txt"
    fi

    DIR_COUNT=$(find "$1" -type d | wc -l)
    FILE_COUNT=$(find "$1" -type f | wc -l)
    echo -e "${BLUE}├─ Found ${BOLD}$DIR_COUNT${RESET}${BLUE} directories${RESET}"
    echo -e "${BLUE}└─ Found ${BOLD}$FILE_COUNT${RESET}${BLUE} files${RESET}\n"

    # Process directories
    echo -e "${BLUE}Processing directory structure...${RESET}"
    processed=0
    spin=0
    spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    find "$1" -type d | while read -r item; do
        processed=$((processed + 1))
        percentage=$((processed * 100 / DIR_COUNT))
        rel_path=${item#$1}
        rel_path_escaped=$(printf '%s' "$rel_path" | sed 's/[.[\*^$()+?{|}]/\\&/g')
        [ -z "$rel_path" ] && rel_path="/"

        # Use awk for robust parsing
        stored_attrs=$(grep -E "^${rel_path_escaped} " "$FS_CONFIG_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        stored_context=$(grep -E "^${rel_path_escaped} " "$FILE_CONTEXTS_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')

        if [ -z "$stored_attrs" ]; then
            # New directory: find attributes from the closest known ancestor
            pattern=$(find_matching_pattern "$rel_path" "$FS_CONFIG_FILE")
            uid=$(echo "$pattern" | awk '{print $2}')
            gid=$(echo "$pattern" | awk '{print $3}')
            mode=$(echo "$pattern" | awk '{print $4}')

            chown "${uid:-0}:${gid:-0}" "$item" 2>/dev/null || true
            chmod "${mode:-755}" "$item" 2>/dev/null || true

            context_pattern=$(find_matching_pattern "$rel_path" "$FILE_CONTEXTS_FILE")
            context=$(echo "$context_pattern" | awk '{$1=""; print $0}' | sed 's/^ //')
            [ -n "$context" ] && setfattr -n security.selinux -v "$context" "$item" 2>/dev/null || true
        else
            # Existing directory: restore original attributes
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')

            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && setfattr -n security.selinux -v "$stored_context" "$item" 2>/dev/null || true
        fi

        if [ "$QUIET" = false ]; then echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Mapping contexts: ${percentage}% (${processed}/${DIR_COUNT})${RESET}"; fi
    done
    echo -e "\r\033[K${GREEN}[✓] Directory attributes mapped${RESET}\n"

    # Process files
    echo -e "${BLUE}Processing file permissions...${RESET}"
    processed=0
    spin=0

    find "$1" -type f | while read -r item; do
        processed=$((processed + 1))
        percentage=$((processed * 100 / FILE_COUNT))
        rel_path=${item#$1}
        rel_path_escaped=$(printf '%s' "$rel_path" | sed 's/[.[\*^$()+?{|}]/\\&/g')

        stored_attrs=$(grep -E "^${rel_path_escaped} " "$FS_CONFIG_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        stored_context=$(grep -E "^${rel_path_escaped} " "$FILE_CONTEXTS_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')

        if [ -z "$stored_attrs" ]; then
            # New file: find ownership/context from the closest known ancestor
            pattern=$(find_matching_pattern "$rel_path" "$FS_CONFIG_FILE")
            uid=$(echo "$pattern" | awk '{print $2}')
            gid=$(echo "$pattern" | awk '{print $3}')

            chown "${uid:-0}:${gid:-0}" "$item" 2>/dev/null || true
            chmod 644 "$item" 2>/dev/null || true

            context_pattern=$(find_matching_pattern "$rel_path" "$FILE_CONTEXTS_FILE")
            context=$(echo "$context_pattern" | awk '{$1=""; print $0}' | sed 's/^ //')
            [ -n "$context" ] && setfattr -n security.selinux -v "$context" "$item" 2>/dev/null || true
        else
            # Existing file: restore original attributes
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')

            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && setfattr -n security.selinux -v "$stored_context" "$item" 2>/dev/null || true
        fi

        if [ "$QUIET" = false ]; then echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Restoring contexts: ${percentage}% (${processed}/${FILE_COUNT})${RESET}"; fi
    done
    echo -e "\r\033[K${GREEN}[✓] File attributes restored${RESET}\n"
}

verify_modifications() {
    local src="$1"
    echo -e "\n${BLUE}Verifying modified files...${RESET}"

    # Generate current checksums excluding .repack_info
    local curr_sums="$TMP_DIR/current_checksums.txt"
    (cd "$src" && find . -type f -not -path "./.repack_info/*" -exec sha256sum {} \;) > "$curr_sums"

    echo -e "${BLUE}Analyzing changes...${RESET}"
    local modified_files=0
    local total_files=0
    local spin=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    while IFS= read -r line; do
        total_files=$((total_files + 1))
        checksum=$(echo "$line" | cut -d' ' -f1)
        file=$(echo "$line" | cut -d' ' -f3-)

        # Show spinner while processing
        if [ "$QUIET" = false ]; then echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Analyzing files...${RESET}"; fi

        if ! grep -q "$checksum.*$file" "${REPACK_INFO}/original_checksums.txt" 2>/dev/null; then
            modified_files=$((modified_files + 1))
            echo -e "\r\033[K${YELLOW}Modified: $file${RESET}"
        fi
    done < "$curr_sums"

    # Clear progress line and show summary
    echo -e "\r\033[K${BLUE}Found ${YELLOW}$modified_files${BLUE} modified files out of $total_files total files${RESET}"
    rm -f "$curr_sums"
}

show_copy_progress() {
    local src="$1"
    local dst="$2"
    local total_size=$(du -sb "$src" 2>/dev/null | cut -f1)
    local spin=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    while kill -0 $! 2>/dev/null; do
        # Suppress errors from du - rsync creates temporary files that may be renamed during copy
        current_size=$(du -sb "$dst" 2>/dev/null | cut -f1 || echo "0")
        [ -z "$current_size" ] && current_size=0
        [ "$current_size" -gt 0 ] && [ "$total_size" -gt 0 ] && percentage=$((current_size * 100 / total_size)) || percentage=0
        current_hr=$(numfmt --to=iec-i --suffix=B "$current_size" 2>/dev/null || echo "0B")
        total_hr=$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "0B")

        # Clear entire line with \033[K before printing
        if [ "$QUIET" = false ]; then echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Copying to work directory: ${percentage}% (${current_hr}/${total_hr})${RESET}"; fi
        sleep 0.1
    done

    # Clear line and show completion
    echo -e "\r\033[K${GREEN}[✓] Files copied to work directory${RESET}"
}

remove_repack_info() {
    local target_dir="$1"
    rm -rf "${target_dir}/.repack_info" 2>/dev/null
    rm -rf "${target_dir}/fs-config.txt" 2>/dev/null
}

prepare_working_directory() {
    echo -e "\n${BLUE}Preparing working directory...${RESET}"
    mkdir -p "$TEMP_ROOT"
    [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    # Copy with SELinux contexts and progress
    echo -e "${BLUE}Copying files to work directory...${RESET}"
    (cd "$EXTRACT_DIR" && tar -cf - .) | (cd "$WORK_DIR" && tar -xf -) &
    show_copy_progress "$EXTRACT_DIR" "$WORK_DIR"
    wait $!
    copy_exit=$?

    if [ $copy_exit -ne 0 ]; then
        echo -e "${RED}Error: Failed to copy files to work directory${RESET}"
        cleanup
        exit 1
    fi

    verify_modifications "$WORK_DIR"
    restore_attributes "$WORK_DIR"
    remove_repack_info "$WORK_DIR"
}

create_ext4_image_quiet() {
    local blocks="$1"
    local output="$2"
    local mount_point="$3"

    # Create raw image quietly
    dd if=/dev/zero of="$output" bs=4096 count="$blocks" status=none

    # Format ext4 quietly
    mkfs.ext4 -q \
        -O ext_attr,dir_index,filetype,extent,sparse_super,large_file,huge_file,uninit_bg,dir_nlink,extra_isize \
        -O ^has_journal,^resize_inode,^64bit,^flex_bg,^metadata_csum "$output"

    mkdir -p "$mount_point"
    mount -o loop,rw,seclabel "$output" "$mount_point" 2>/dev/null
}

# Prepare EXT4 features string for mkfs by comparing with default mkfs.ext4 features
prepare_ext4_features() {
    local original_features="$1"
    local tmp_dummy_img
    tmp_dummy_img=$(mktemp "${TMP_DIR:-/tmp}/dummy_ext4_features_XXXXXX.img" 2>/dev/null || echo "/tmp/dummy_ext4_features_$$.img")

    # Create a dummy ext4 image to get default features (silently, no logging)
    dd if=/dev/zero of="$tmp_dummy_img" bs=4096 count=100 2>/dev/null
    mkfs.ext4 -q -F "$tmp_dummy_img" 2>/dev/null

    # Extract default features from dummy image
    local default_features
    default_features=$(tune2fs -l "$tmp_dummy_img" 2>/dev/null | grep "Filesystem features:" | awk -F':' '{print $2}' | xargs | sed 's/ /,/g')

    # Clean up dummy image
    rm -f "$tmp_dummy_img"

    # Filter out runtime-only flags that can't be set with mkfs.ext4
    # These appear in tune2fs -l output but are not valid mkfs.ext4 options
    local RUNTIME_FLAGS=("orphan_file" "needs_recovery" "orphan_present" "uninit_bg")
    local filtered_original="$original_features"
    local filtered_default="$default_features"

    for flag in "${RUNTIME_FLAGS[@]}"; do
        filtered_original=$(echo "$filtered_original" | sed "s/,$flag//g; s/^$flag,//g; s/,$flag$//g; s/^$flag$//g")
        filtered_default=$(echo "$filtered_default" | sed "s/,$flag//g; s/^$flag,//g; s/,$flag$//g; s/^$flag$//g")
    done

    # Special handling for has_journal: it's enabled by default in ext4, so we never enable it explicitly
    # If original doesn't have it, we disable it with ^has_journal
    local has_journal_in_original=false
    if echo "$filtered_original" | grep -q "has_journal"; then
        has_journal_in_original=true
        # Remove has_journal from original features (we'll handle it separately)
        filtered_original=$(echo "$filtered_original" | sed "s/,has_journal//g; s/^has_journal,//g; s/,has_journal$//g; s/^has_journal$//g")
    fi

    # Clean up any double commas
    filtered_original=$(echo "$filtered_original" | sed 's/,,/,/g; s/^,//; s/,$//')
    filtered_default=$(echo "$filtered_default" | sed 's/,,/,/g; s/^,//; s/,$//')

    # Convert comma-separated strings to arrays for comparison
    IFS=',' read -ra original_array <<< "$filtered_original"
    IFS=',' read -ra default_array <<< "$filtered_default"

    # Find features to enable (in original but not in default)
    local features_to_enable=()
    for feature in "${original_array[@]}"; do
        feature=$(echo "$feature" | xargs) # trim whitespace
        [[ -z "$feature" ]] && continue
        local found=false
        for def_feature in "${default_array[@]}"; do
            def_feature=$(echo "$def_feature" | xargs)
            if [[ "$feature" == "$def_feature" ]]; then
                found=true
                break
            fi
        done
        [[ "$found" == false ]] && features_to_enable+=("$feature")
    done

    # Find features to disable (in default but not in original)
    local features_to_disable=()
    for def_feature in "${default_array[@]}"; do
        def_feature=$(echo "$def_feature" | xargs)
        [[ -z "$def_feature" ]] && continue
        local found=false
        for feature in "${original_array[@]}"; do
            feature=$(echo "$feature" | xargs)
            if [[ "$def_feature" == "$feature" ]]; then
                found=true
                break
            fi
        done
        [[ "$found" == false ]] && features_to_disable+=("^$def_feature")
    done

    # Handle has_journal: if original doesn't have it, disable it (it's enabled by default)
    if [ "$has_journal_in_original" = false ]; then
        features_to_disable+=("^has_journal")
    fi

    # Build mkfs.ext4 -O options string
    local enable_str=""
    local disable_str=""

    if [ ${#features_to_enable[@]} -gt 0 ]; then
        enable_str=$(IFS=','; echo "${features_to_enable[*]}")
    fi

    if [ ${#features_to_disable[@]} -gt 0 ]; then
        disable_str=$(IFS=','; echo "${features_to_disable[*]}")
    fi

    # Return format: "enable_features|disable_features" (pipe separator for parsing)
    if [ -n "$enable_str" ] && [ -n "$disable_str" ]; then
        echo "$enable_str|$disable_str"
    elif [ -n "$enable_str" ]; then
        echo "$enable_str|"
    elif [ -n "$disable_str" ]; then
        echo "|$disable_str"
    else
        echo "|"
    fi
}

# Create EXT4 image with original parameters
create_ext4_image_strict() {
    local output_img="$1"
    local block_size="$2"
    local block_count="$3"
    local features_string="$4"

    dd if=/dev/zero of="$output_img" bs="$block_size" count="$block_count" status=none

    # Parse features string (format: "enable_features|disable_features")
    local enable_features=""
    local disable_features=""
    if [[ "$features_string" == *"|"* ]]; then
        enable_features="${features_string%%|*}"
        disable_features="${features_string#*|}"
    else
        # Fallback: treat as enable features only
        enable_features="$features_string"
    fi

    # Build mkfs.ext4 command with proper -O options
    local mkfs_cmd="mkfs.ext4 -q -b $block_size -m $ORIGINAL_RESERVED_BLOCKS_PERCENTAGE -I $ORIGINAL_INODE_SIZE -N $ORIGINAL_INODE_COUNT -U $ORIGINAL_UUID"

    # Add enable features if any
    if [ -n "$enable_features" ]; then
        mkfs_cmd+=" -O $enable_features"
    fi

    # Add disable features if any (separate -O option)
    if [ -n "$disable_features" ]; then
        mkfs_cmd+=" -O $disable_features"
    fi

    # Add volume label if present
    [ -n "$ORIGINAL_VOLUME_NAME" ] && mkfs_cmd+=" -L $ORIGINAL_VOLUME_NAME"

    # Add output file
    mkfs_cmd+=" $output_img"

    eval "$mkfs_cmd"
}

# Check if tar pipe failed due to space issues
check_tar_space_error() {
    local exit_code="$1"
    local log_file="$2"

    if [ "$exit_code" -eq 0 ]; then
        return 1  # No error
    fi

    # Check log file for space-related errors
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        if grep -qi "No space left on device\|write failed\|failed to set\|error.*space\|ENOSPC\|tar:.*: No space left\|tar:.*: Cannot write" "$log_file" 2>/dev/null; then
            return 0  # Space error detected
        fi
    fi

    # If exit code is 1 and we have a log file, check for common space-related patterns
    if [ "$exit_code" -eq 1 ]; then
        # Check if destination is full
        if [ -n "$log_file" ] && [ -f "$log_file" ]; then
            if grep -qi "write error\|cannot create\|failed to write" "$log_file" 2>/dev/null; then
                return 0  # Likely space error
            fi
        fi
    fi

    return 1  # Not a space error
}

calculate_optimal_ext4_size() {
    local content_dir="$1"
    local overhead_percent="${2:-15}"

    # Send debug output to stderr so it doesn't interfere with return value
    echo -e "${BLUE}Calculating optimal image size...${RESET}" >&2

    # Step 1: Get actual content size (excluding .repack_info)
    local content_bytes=$(du -sb --exclude=.repack_info "$content_dir" | awk '{print $1}')
    echo -e "${BLUE}├─ Content size: $(numfmt --to=iec-i --suffix=B $content_bytes)${RESET}" >&2

    # Step 2: Calculate block allocation overhead (files take whole blocks)
    local block_size=4096
    local file_count=$(find "$content_dir" -not -path "*/.repack_info/*" -type f | wc -l)
    local dir_count=$(find "$content_dir" -type d -not -path "*/.repack_info/*" | wc -l)

    # Estimate block allocation overhead more conservatively
    # Each file/directory takes at least 1 block, and files may have partial blocks
    # Use a conservative estimate: assume 2-3% overhead for block allocation
    # This accounts for small files, partial blocks, and directory blocks
    local block_allocation_overhead=$((content_bytes * 3 / 100))

    # Step 3: Calculate ext4 metadata overhead
    # Count files and directories for inode calculation
    local required_inodes=$((file_count + dir_count + 100))

    # Ext4 uses 1 inode per 16KB by default, but we'll be more precise
    local inode_size=256  # Default inode size

    # Calculate minimum blocks needed for inodes
    local inode_table_blocks=$(( (required_inodes * inode_size + block_size - 1) / block_size ))

    # Base metadata overhead: superblock, group descriptors, bitmaps, etc.
    # Estimate ~300KB base (more conservative)
    local base_metadata_overhead=$((300 * 1024))

    # Directory entries overhead: each directory needs space for entries and directory blocks
    # Estimate ~2-4KB per directory (more conservative for directory blocks)
    local dir_entry_overhead=$((dir_count * 3072))  # ~3KB per directory

    # Content-based metadata overhead (more accurate than percentage)
    # Account for extent trees, directory blocks, etc.
    # Increase to 10% to be more conservative
    local content_metadata_overhead=$((content_bytes * 10 / 100))  # 10% for content metadata

    # Safety margin for block allocation differences and mkfs.ext4 overhead
    # Increase significantly - mkfs.ext4 can allocate more than expected
    local safety_margin=$((800 * 1024))  # 800KB safety margin

    # Total metadata overhead
    local total_metadata_overhead=$((base_metadata_overhead + dir_entry_overhead + content_metadata_overhead + safety_margin + inode_table_blocks * block_size))

    echo -e "${BLUE}├─ Base metadata overhead: $(numfmt --to=iec-i --suffix=B $base_metadata_overhead)${RESET}" >&2
    echo -e "${BLUE}├─ Content overhead (8%): $(numfmt --to=iec-i --suffix=B $content_metadata_overhead)${RESET}" >&2
    echo -e "${BLUE}├─ Safety margin: $(numfmt --to=iec-i --suffix=B $safety_margin)${RESET}" >&2
    echo -e "${BLUE}├─ Total metadata overhead: $(numfmt --to=iec-i --suffix=B $total_metadata_overhead)${RESET}" >&2
    echo -e "${BLUE}├─ Required inodes: $required_inodes${RESET}" >&2

    # Step 4: Calculate base filesystem size (content + block overhead + metadata)
    local base_fs_size=$((content_bytes + block_allocation_overhead + total_metadata_overhead))

    # Step 5: Add user-specified overhead (using integer arithmetic)
    local user_overhead=$((base_fs_size * overhead_percent / 100))
    local final_size=$((base_fs_size + user_overhead))

    # Step 6: Round up to nearest block boundary
    local final_blocks=$(( (final_size + block_size - 1) / block_size ))
    local final_size_rounded=$((final_blocks * block_size))

    echo -e "${BLUE}├─ User overhead (${overhead_percent}%): $(numfmt --to=iec-i --suffix=B $user_overhead)${RESET}" >&2
    echo -e "${BLUE}└─ Final size: $(numfmt --to=iec-i --suffix=B $final_size_rounded) (${final_blocks} blocks)${RESET}" >&2

    # Only return the number
    echo "$final_blocks"
}

create_ext4_flexible() {
    local extract_dir="$1"
    local output_img="$2"
    local mount_point="$3"
    local overhead_percent="$4"

    echo -e "\n${YELLOW}${BOLD}Flexible mode: Calculating optimal image size...${RESET}\n"

    local content_size=$(du -sb --exclude=.repack_info "$extract_dir" | awk '{print $1}')
    local max_attempts=5
    local attempt=1
    local optimal_blocks

    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -eq 1 ]; then
            # First attempt: use calculated size + 10% overhead for mkfs.ext4 metadata
            optimal_blocks=$(calculate_optimal_ext4_size "$extract_dir" "$overhead_percent")
            optimal_blocks=$((optimal_blocks + (optimal_blocks * 10 / 100)))  # Add 10% overhead
        else
            # Subsequent attempts: increase size by 10% each time
            echo -e "${YELLOW}Attempt $attempt: Increasing image size by 10%...${RESET}"
            optimal_blocks=$((optimal_blocks + (optimal_blocks * 10 / 100)))
        fi

        echo -e "\n${BLUE}Creating ext4 image (${optimal_blocks} blocks)...${RESET}"

        # Create the image with calculated size
        dd if=/dev/zero of="$output_img" bs=4096 count="$optimal_blocks" status=none

        # Format with optimal settings
        if [ "$FILESYSTEM_TYPE" == "ext4" ] && [ -n "$ORIGINAL_UUID" ]; then
            # Preserve original filesystem characteristics when available
            local features_for_mkfs
            features_for_mkfs=$(prepare_ext4_features "$ORIGINAL_FEATURES")

            # Parse features string
            local enable_features="${features_for_mkfs%%|*}"
            local disable_features="${features_for_mkfs#*|}"

            local mkfs_cmd="mkfs.ext4 -q -b 4096 -I $ORIGINAL_INODE_SIZE -m $ORIGINAL_RESERVED_BLOCKS_PERCENTAGE -U $ORIGINAL_UUID"
            [ -n "$enable_features" ] && mkfs_cmd+=" -O $enable_features"
            [ -n "$disable_features" ] && mkfs_cmd+=" -O $disable_features"
            [ -n "$ORIGINAL_VOLUME_NAME" ] && mkfs_cmd+=" -L $ORIGINAL_VOLUME_NAME"
            mkfs_cmd+=" $output_img"
            eval "$mkfs_cmd"
        else
            # Use optimized defaults for new filesystem
            mkfs.ext4 -q -b 4096 -i 16384 -m 1 -O ^has_journal,^resize_inode,dir_index,extent,sparse_super "$output_img"
        fi

        # Mount the new filesystem
        mkdir -p "$mount_point"
        mount -o loop,rw "$output_img" "$mount_point" 2>/dev/null

        if [ $? -ne 0 ]; then
            echo -e "${RED}Error: Failed to mount created image${RESET}"
            rm -f "$output_img"
            attempt=$((attempt + 1))
            continue
        fi

        echo -e "${GREEN}✓ Image created and mounted successfully${RESET}"

        # Verify we have enough space
        local available_space=$(df --output=avail -B1 "$mount_point" | tail -n1)
        local total_space=$(df --output=size -B1 "$mount_point" | tail -n1)

        # Add 5% buffer for safety (ext4 can have allocation differences)
        local required_space=$((content_size + (content_size * 5 / 100)))

        if [ "$available_space" -ge "$required_space" ]; then
            # Success! We have enough space
            local free_after_copy=$((available_space - content_size))
            local free_percentage=$(( free_after_copy * 100 / total_space ))
            if [ $attempt -gt 1 ]; then
                echo -e "${GREEN}✓ Sufficient space after size adjustment${RESET}"
            fi
            echo -e "${BLUE}Available space: $(numfmt --to=iec-i --suffix=B $available_space) (~${free_percentage}% free after copy)${RESET}"
            return 0
        else
            # Not enough space, unmount and try again with larger size
            echo -e "\n${YELLOW}Insufficient space: Available $(numfmt --to=iec-i --suffix=B $available_space), Required $(numfmt --to=iec-i --suffix=B $required_space)${RESET}"
            umount "$mount_point" 2>/dev/null
            rm -f "$output_img"
            attempt=$((attempt + 1))
        fi
    done

    # All attempts failed
    echo -e "${RED}Error: Failed to create image with sufficient space after $max_attempts attempts${RESET}"
    return 1
}

# Function to get original filesystem parameters (robust and universal)
get_fs_param() {
    local image_file="$1"
    local param="$2"
    if [ ! -f "$image_file" ]; then
        echo ""
        return
    fi
    # This robustly extracts the value after the colon, trims whitespace,
    # and takes the first "word", which is the actual numerical value or keyword.
    # It correctly handles lines like "Reserved blocks uid: 0 (user root)".
    tune2fs -l "$image_file" | grep -E "^${param}:" | awk -F':' '{print $2}' | awk '{print $1}'
}

# Start repacking process with better visuals
if [ "$NO_BANNER" = false ]; then
    echo -e "\n${BLUE}${BOLD}Starting repacking process...${RESET}"
    echo -e "${BLUE}┌─ Source directory: ${BOLD}$EXTRACT_DIR${RESET}"
    echo -e "${BLUE}└─ Target image: ${BOLD}$OUTPUT_IMG${RESET}\n"
fi

# Load metadata to check mount method
MOUNT_METHOD=""
if [ -f "${REPACK_INFO}/metadata.txt" ]; then
    load_metadata "${REPACK_INFO}/metadata.txt"
fi

# Add filesystem selection before any operations
if [ -z "$FS_CHOICE" ]; then
    if [ "$MOUNT_METHOD" == "fuse" ]; then
        echo -e "\n${RED}${BOLD}WARNING: FUSE-based unpacking detected.${RESET}"
        echo -e "${RED}Repacking as EXT4 is not supported for images unpacked with FUSE.${RESET}"
        echo -e "${RED}Only EROFS repacking is available for this directory.${RESET}"
        FS_CHOICE="erofs"
        sleep 2 # Give user time to read
    else
        echo -e "\n${BLUE}${BOLD}Select filesystem type:${RESET}"
        echo -e "1. EROFS"
        echo -e "2. EXT4"
        read -p "Enter your choice [1-2]: " choice
        case $choice in
            1) FS_CHOICE="erofs" ;;
            2) FS_CHOICE="ext4" ;;
            *) FS_CHOICE="erofs" ;;
        esac
    fi
else
    # Non-interactive check
    if [ "$MOUNT_METHOD" == "fuse" ] && [ "$FS_CHOICE" == "ext4" ]; then
        echo -e "\n${RED}${BOLD}ERROR: FUSE-based unpacking detected.${RESET}"
        echo -e "${RED}Repacking as EXT4 is not supported for images unpacked with FUSE.${RESET}"
        echo -e "${RED}Please use '--fs erofs' for this directory.${RESET}"
        exit 1
    fi
fi

case $FS_CHOICE in
    erofs)
        # EROFS flow - prepare working directory first
        prepare_working_directory

        if [ -z "$EROFS_COMP" ]; then
            echo -e "\n${BLUE}${BOLD}Select compression method:${RESET}"
            echo -e "1. none (default)"
            echo -e "2. lz4"
            echo -e "3. lz4hc (level 0-12, default 9)"
            echo -e "4. deflate (level 0-9, default 1)"
            read -p "Enter your choice [1-4]: " comp_choice

            case $comp_choice in
              2) EROFS_COMP="lz4" ;;
              3) EROFS_COMP="lz4hc" ;;
              4) EROFS_COMP="deflate" ;;
              *) EROFS_COMP="none" ;;
            esac
        fi

        case $EROFS_COMP in
          lz4)
            COMPRESSION="-zlz4"
            ;;
          lz4hc)
            if [ -z "$EROFS_LEVEL" ]; then
                read -p "$(echo -e ${BLUE}"Enter LZ4HC compression level (0-12, default 9): "${RESET})" COMP_LEVEL
            else
                COMP_LEVEL="$EROFS_LEVEL"
            fi

            if [[ "$COMP_LEVEL" =~ ^([0-9]|1[0-2])$ ]]; then
              COMPRESSION="-zlz4hc,level=$COMP_LEVEL"
            else
              echo -e "${YELLOW}Invalid level. Using default level 9.${RESET}"
              COMPRESSION="-zlz4hc"
            fi
            ;;
          deflate)
             if [ -z "$EROFS_LEVEL" ]; then
                read -p "$(echo -e ${BLUE}"Enter DEFLATE compression level (0-9, default 1): "${RESET})" COMP_LEVEL
            else
                COMP_LEVEL="$EROFS_LEVEL"
            fi

            if [[ "$COMP_LEVEL" =~ ^[0-9]$ ]]; then
              COMPRESSION="-zdeflate,level=$COMP_LEVEL"
            else
              echo -e "${YELLOW}Invalid level. Using default level 1.${RESET}"
              COMPRESSION="-zdeflate"
            fi
            ;;
          *)
            COMPRESSION=""
            echo -e "${BLUE}Using no compression.${RESET}"
            ;;
        esac

        MKFS_CMD="mkfs.erofs"
        if [ -n "$COMPRESSION" ]; then
            MKFS_CMD="$MKFS_CMD $COMPRESSION"
        fi
        if [ -n "$ORIGINAL_UUID" ]; then
            MKFS_CMD="$MKFS_CMD -U '$ORIGINAL_UUID'"
        fi
        if [ -n "$ORIGINAL_VOLUME_NAME" ]; then
            MKFS_CMD="$MKFS_CMD -L '$ORIGINAL_VOLUME_NAME'"
        fi
        MKFS_CMD="$MKFS_CMD $OUTPUT_IMG.tmp $WORK_DIR"

        echo -e "\n${BLUE}Executing command:${RESET}"
        echo -e "${BOLD}$MKFS_CMD${RESET}\n"

        echo -e "${BLUE}Creating EROFS image... This may take some time.${RESET}\n"
        eval $MKFS_CMD

        mv "$OUTPUT_IMG.tmp" "$OUTPUT_IMG"
        echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
        echo -e "${BLUE}Image size: $(stat -c %s "$OUTPUT_IMG" | numfmt --to=iec-i --suffix=B)${RESET}\n"
        ;;

    ext4)
        MOUNT_POINT="${TEMP_ROOT}/ext4_mount"
        mkdir -p "$MOUNT_POINT"

        if [ -z "$EXT4_MODE" ]; then
            echo -e "\n${BLUE}${BOLD}Select EXT4 Repack Mode:${RESET}"
            echo -e "1. Strict (clone original image structure)"
            echo -e "2. Flexible (auto-resize with configurable free space)"
            read -p "Enter your choice [1-2]: " repack_mode_choice
            [ "$repack_mode_choice" == "1" ] && EXT4_MODE="strict" || EXT4_MODE="flexible"
        fi

        # Load metadata first to get variables
        load_metadata "${REPACK_INFO}/metadata.txt"

        # Fallback logic to ensure critical variables are set if metadata is old
        if [ -z "$ORIGINAL_BLOCK_COUNT" ] || [ -z "$ORIGINAL_BLOCK_SIZE" ]; then
            if [ -f "$SOURCE_IMAGE" ]; then
                echo -e "${YELLOW}Warning: Incomplete metadata. Reading info from source image.${RESET}"
                ORIGINAL_BLOCK_COUNT=$(get_fs_param "$SOURCE_IMAGE" "Block count")
                ORIGINAL_BLOCK_SIZE=$(get_fs_param "$SOURCE_IMAGE" "Block size")
            else
                if [ "$EXT4_MODE" == "strict" ]; then
                    echo -e "${RED}Error: Cannot use strict mode. Source image not found and metadata is incomplete.${RESET}"
                    exit 1
                fi
                FILESYSTEM_TYPE="unknown"
            fi
        fi

        CURRENT_CONTENT_SIZE=$(du -sb --exclude=.repack_info "$EXTRACT_DIR" | awk '{print $1}')

        if [ "$EXT4_MODE" == "flexible" ]; then
            if [ -z "$EXT4_OVERHEAD_PERCENT" ]; then
                echo -e "\n${BLUE}${BOLD}Select desired free space overhead:${RESET}"
                echo -e "1. Standard (10%)"
                echo -e "2. Recommended (15%)"
                echo -e "3. Generous (20%)"
                echo -e "4. Custom"
                read -p "Enter your choice [1-4, default: 2]: " overhead_choice

                case $overhead_choice in
                    1) EXT4_OVERHEAD_PERCENT=10 ;;
                    3) EXT4_OVERHEAD_PERCENT=20 ;;
                    4) read -rp "$(echo -e ${BLUE}"Enter custom percentage (e.g., 25): "${RESET})" EXT4_OVERHEAD_PERCENT
                       if ! [[ "$EXT4_OVERHEAD_PERCENT" =~ ^[0-9]+$ ]]; then
                           echo -e "${RED}Invalid input. Defaulting to 15%.${RESET}"
                           EXT4_OVERHEAD_PERCENT=15
                       fi ;;
                    *) EXT4_OVERHEAD_PERCENT=15 ;;
                esac
            fi

            create_ext4_flexible "$EXTRACT_DIR" "$OUTPUT_IMG" "$MOUNT_POINT" "$EXT4_OVERHEAD_PERCENT"

        else # Strict mode
            if [ "$FILESYSTEM_TYPE" != "ext4" ]; then
                echo -e "\n${RED}${BOLD}Error: Strict mode is only available when the source image is also ext4.${RESET}"; exit 1
            fi
            echo -e "\n${GREEN}${BOLD}Strict mode: Cloning original filesystem structure...${RESET}"

            if [ "$ORIGINAL_HAS_SHARED_BLOCKS" == "true" ]; then
                echo -e "\n${YELLOW}${BOLD}Special 'shared_blocks' feature detected. Creating optimized mountable image.${RESET}\n"

                target_blocks=$(calculate_optimal_ext4_size "$EXTRACT_DIR" 10)
                features_for_mkfs=$(prepare_ext4_features "$(echo "$ORIGINAL_FEATURES" | sed 's/shared_blocks//g')")

                echo -e "${BLUE}  - Creating temporary well-sized image...${RESET}"
                create_ext4_image_strict "$OUTPUT_IMG" "4096" "$target_blocks" "$features_for_mkfs"
                mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"

            else
                # Original strict mode logic for images without shared_blocks
                features_for_mkfs=$(prepare_ext4_features "$ORIGINAL_FEATURES")
                create_ext4_image_strict "$OUTPUT_IMG" "$ORIGINAL_BLOCK_SIZE" "$ORIGINAL_BLOCK_COUNT" "$features_for_mkfs"
                mount -o loop,rw,seclabel "$OUTPUT_IMG" "$MOUNT_POINT"
            fi
        fi

        echo -e "\n${BLUE}Copying files to final image...${RESET}"
        tar_log_file=$(mktemp)
        set +e  # Disable exit on error to catch copy failures
        (cd "$EXTRACT_DIR" && tar --exclude=.repack_info -cf - .) 2>>"$tar_log_file" | (cd "$MOUNT_POINT" && tar -xf -) 2>>"$tar_log_file" &
        tar_pid=$!
        show_copy_progress "$EXTRACT_DIR" "$MOUNT_POINT"
        wait $tar_pid
        copy_exit_code=$?
        set -e  # Re-enable exit on error

        # Check if copy failed due to space issues
        copy_failed=false
        if check_tar_space_error "$copy_exit_code" "$tar_log_file"; then
            copy_failed=true
        fi

        # If strict mode copy failed due to space, fall back to resize approach
        if [ "$copy_failed" = true ] && [ "$EXT4_MODE" == "strict" ] && [ "$ORIGINAL_HAS_SHARED_BLOCKS" != "true" ]; then
            echo -e "\n${YELLOW}${BOLD}Warning: Copy failed due to insufficient space in strict mode.${RESET}"
            echo -e "${YELLOW}This can happen due to block allocation differences. Falling back to resize approach...${RESET}\n"

            # Unmount and remove the failed image
            sync && umount "$MOUNT_POINT" 2>/dev/null || true
            rm -f "$OUTPUT_IMG"

            # Use the shared_blocks approach: create larger image, copy, then resize
            target_blocks=$(calculate_optimal_ext4_size "$EXTRACT_DIR" 10)
            features_for_mkfs=$(prepare_ext4_features "$ORIGINAL_FEATURES")

            echo -e "${BLUE}  - Creating temporary well-sized image...${RESET}"
            create_ext4_image_strict "$OUTPUT_IMG" "4096" "$target_blocks" "$features_for_mkfs"
            mount -o loop,rw,seclabel "$OUTPUT_IMG" "$MOUNT_POINT"

            # Retry copying with the larger image
            echo -e "${BLUE}  - Copying files to temporary image...${RESET}"
            set +e  # Disable exit on error to check result
            (cd "$EXTRACT_DIR" && tar --exclude=.repack_info -cf - .) 2>/dev/null | (cd "$MOUNT_POINT" && tar -xf -) 2>/dev/null &
            fallback_tar_pid=$!
            show_copy_progress "$EXTRACT_DIR" "$MOUNT_POINT"
            wait $fallback_tar_pid
            fallback_copy_exit=$?
            set -e  # Re-enable exit on error

            if [ $fallback_copy_exit -ne 0 ]; then
                echo -e "\n${RED}${BOLD}Error: Copy failed even with larger image.${RESET}"
                umount "$MOUNT_POINT" 2>/dev/null || true
                rm -f "$OUTPUT_IMG" "$tar_log_file"
                exit 1
            fi
        elif [ "$copy_exit_code" -ne 0 ] && [ "$copy_failed" != true ]; then
            # Other error (not space-related)
            echo -e "\n${RED}${BOLD}Error: Copy failed.${RESET}"
            if [ -f "$tar_log_file" ]; then
                echo -e "${RED}Error details:${RESET}"
                tail -20 "$tar_log_file"
            fi
            umount "$MOUNT_POINT" 2>/dev/null || true
            rm -f "$OUTPUT_IMG" "$tar_log_file"
            exit 1
        fi

        # Cleanup temp log file
        rm -f "$tar_log_file"

        # Verify and restore attributes (for both successful first try and fallback)
        verify_modifications "$MOUNT_POINT"
        restore_attributes "$MOUNT_POINT"
        remove_repack_info "$MOUNT_POINT"

        echo -e "${BLUE}Unmounting image...${RESET}"
        sync && umount "$MOUNT_POINT"

        # Resize if we used the fallback approach or if shared_blocks mode
        if [ "$EXT4_MODE" == "strict" ]; then
            if [ "$ORIGINAL_HAS_SHARED_BLOCKS" == "true" ] || [ "$copy_failed" = true ]; then
                echo -e "${BLUE}  - Finalizing optimized image...${RESET}"
                e2fsck -fy "$OUTPUT_IMG" >/dev/null 2>&1
                echo -e "${BLUE}  - Resizing filesystem to minimum possible size...${RESET}"
                resize2fs -M "$OUTPUT_IMG" >/dev/null 2>&1
            fi
        fi

        set +e  # Disable exit on error for final e2fsck
        e2fsck -yf "$OUTPUT_IMG" >/dev/null 2>&1
        set -e  # Re-enable exit on error
        [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"

        echo -e "\n${GREEN}${BOLD}Successfully created EXT4 image: $OUTPUT_IMG${RESET}"
        echo -e "${BLUE}Image size: $(stat -c %s "$OUTPUT_IMG" | numfmt --to=iec-i --suffix=B)${RESET}"
        ;;

    *)
        echo -e "${RED}Invalid choice. Exiting.${RESET}"
        exit 1
        ;;
esac

# Transfer ownership back to actual user
if [ -n "$SUDO_USER" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"
fi

# Disable the trap for a clean, successful exit
trap - INT TERM EXIT
cleanup

if [ "$NO_BANNER" = false ]; then
    echo -e "\n${GREEN}${BOLD}Done!${RESET}"
fi
