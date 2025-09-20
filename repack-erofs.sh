#!/bin/bash
# EROFS Image Repacker Script with Enhanced Attribute Restoration
# Usage: ./repack_erofs.sh <extracted_folder_path>

set -e

# Define color codes
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

# Banner function
print_banner() {
  echo -e "${BOLD}${GREEN}"
  echo "┌───────────────────────────────────────────┐"
  echo "│         Repack EROFS - by @ravindu644     │"
  echo "└───────────────────────────────────────────┘"
  echo -e "${RESET}"
}

print_banner

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"
  exit 1
fi

# Check if mkfs.erofs is installed
if ! command -v mkfs.erofs &> /dev/null; then
  echo -e "${RED}mkfs.erofs command not found. Please install erofs-utils package.${RESET}"
  echo -e "For Ubuntu/Debian: sudo apt install erofs-utils"
  echo -e "For other distributions, check your package manager.${RESET}"
  exit 1
fi

# Check if extracted folder is provided
if [ $# -ne 1 ]; then
  echo -e "${YELLOW}Usage: $0 <extracted_folder_path>${RESET}"
  echo -e "Example: $0 extracted_vendor"
  exit 1
fi

EXTRACT_DIR="$1"
REPACK_INFO="${EXTRACT_DIR}/.repack_info"
PARTITION_NAME=$(basename "$EXTRACT_DIR" | sed 's/^extracted_//')
OUTPUT_IMG="${PARTITION_NAME}_repacked.img"
FS_CONFIG_FILE="${REPACK_INFO}/fs-config.txt"
FILE_CONTEXTS_FILE="${REPACK_INFO}/file_contexts.txt"

# Add temp directory definition and cleanup function
TEMP_ROOT="/tmp/repack-erofs"
WORK_DIR="${TEMP_ROOT}/${PARTITION_NAME}_work"

cleanup() {
    echo -e "\n${YELLOW}Cleaning up temporary files...${RESET}"

    # First unmount any mounted filesystems
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sync
        umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null
    fi
    
    # Then remove temporary files    
    [ -d "$TEMP_ROOT" ] && rm -rf "$TEMP_ROOT"
    [ -f "$OUTPUT_IMG.tmp" ] && rm -f "$OUTPUT_IMG.tmp"
    echo -e "${GREEN}Cleanup completed.${RESET}"
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
            [ -n "$context" ] && chcon -h "$context" "$full_path" 2>/dev/null || true
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
        [ -z "$rel_path" ] && rel_path="/"
        
        # Use awk for robust parsing
        stored_attrs=$(grep -E "^${rel_path} " "$FS_CONFIG_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        stored_context=$(grep -E "^${rel_path} " "$FILE_CONTEXTS_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')

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
            [ -n "$context" ] && chcon "$context" "$item" 2>/dev/null || true
        else
            # Existing directory: restore original attributes
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')
            
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        fi
        
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Mapping contexts: ${percentage}% (${processed}/${DIR_COUNT})${RESET}"
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
        
        stored_attrs=$(grep -E "^${rel_path} " "$FS_CONFIG_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        stored_context=$(grep -E "^${rel_path} " "$FILE_CONTEXTS_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')

        if [ -z "$stored_attrs" ]; then
            # New file: find ownership/context from the closest known ancestor
            pattern=$(find_matching_pattern "$rel_path" "$FS_CONFIG_FILE")
            uid=$(echo "$pattern" | awk '{print $2}')
            gid=$(echo "$pattern" | awk '{print $3}')

            chown "${uid:-0}:${gid:-0}" "$item" 2>/dev/null || true
            chmod 644 "$item" 2>/dev/null || true
            
            context_pattern=$(find_matching_pattern "$rel_path" "$FILE_CONTEXTS_FILE")
            context=$(echo "$context_pattern" | awk '{$1=""; print $0}' | sed 's/^ //')
            [ -n "$context" ] && chcon "$context" "$item" 2>/dev/null || true
        else
            # Existing file: restore original attributes
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')
            
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        fi

        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Restoring contexts: ${percentage}% (${processed}/${FILE_COUNT})${RESET}"
    done
    echo -e "\r\033[K${GREEN}[✓] File attributes restored${RESET}\n"
}

verify_modifications() {
    local src="$1"
    echo -e "\n${BLUE}Verifying modified files...${RESET}"
    
    # Generate current checksums excluding .repack_info
    local curr_sums="/tmp/current_checksums.txt"
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
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Analyzing files...${RESET}"
        
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
    local total_size=$(du -sb "$src" | cut -f1)
    local spin=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    while kill -0 $! 2>/dev/null; do
        current_size=$(du -sb "$dst" | cut -f1)
        percentage=$((current_size * 100 / total_size))
        current_hr=$(numfmt --to=iec-i --suffix=B "$current_size")
        total_hr=$(numfmt --to=iec-i --suffix=B "$total_size")
        
        # Clear entire line with \033[K before printing
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Copying to work directory: ${percentage}% (${current_hr}/${total_hr})${RESET}"
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
    (cd "$EXTRACT_DIR" && tar --selinux -cf - .) | (cd "$WORK_DIR" && tar --selinux -xf -) &
    show_copy_progress "$EXTRACT_DIR" "$WORK_DIR"
    wait $!
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to copy files with attributes${RESET}"
        cleanup ERROR
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
    mount -o loop,rw "$output" "$mount_point" 2>/dev/null
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
echo -e "\n${BLUE}${BOLD}Starting repacking process...${RESET}"
echo -e "${BLUE}┌─ Source directory: ${BOLD}$EXTRACT_DIR${RESET}"
echo -e "${BLUE}└─ Target image: ${BOLD}$OUTPUT_IMG${RESET}\n"

# Add filesystem selection before any operations
echo -e "\n${BLUE}${BOLD}Select filesystem type:${RESET}"
echo -e "1. EROFS"
echo -e "2. EXT4"
read -p "Enter your choice [1-2]: " FS_CHOICE

case $FS_CHOICE in
    1)
        # EROFS flow - prepare working directory first
        prepare_working_directory
        
        echo -e "\n${BLUE}${BOLD}Select compression method:${RESET}"
        echo -e "1. none (default)"
        echo -e "2. lz4"
        echo -e "3. lz4hc (level 0-12, default 9)"
        echo -e "4. deflate (level 0-9, default 1)"
        read -p "Enter your choice [1-4]: " COMP_CHOICE

        case $COMP_CHOICE in
          2)
            COMPRESSION="-zlz4"
            ;;
          3)
            echo -e "\n${BLUE}${BOLD}Select LZ4HC compression level (0-12):${RESET}"
            echo -e "Default: 9 (higher = better compression but slower)"
            read -p "Enter compression level: " COMP_LEVEL
            
            if [[ "$COMP_LEVEL" =~ ^([0-9]|1[0-2])$ ]]; then
              COMPRESSION="-zlz4hc,level=$COMP_LEVEL"
            else
              echo -e "${YELLOW}Invalid level. Using default level 9.${RESET}"
              COMPRESSION="-zlz4hc"
            fi
            ;;
          4)
            echo -e "\n${BLUE}${BOLD}Select DEFLATE compression level (0-9):${RESET}"
            echo -e "Default: 1 (higher = better compression but slower)"
            read -p "Enter compression level: " COMP_LEVEL
            
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
        
        # Create the EROFS image with simplest command
        MKFS_CMD="mkfs.erofs"
        if [ -n "$COMPRESSION" ]; then
            MKFS_CMD="$MKFS_CMD $COMPRESSION"
        fi
        MKFS_CMD="$MKFS_CMD $OUTPUT_IMG.tmp $WORK_DIR"

        # Show the command
        echo -e "\n${BLUE}Executing command:${RESET}"
        echo -e "${BOLD}$MKFS_CMD${RESET}\n"

        # Create the EROFS image
        echo -e "${BLUE}Creating EROFS image... This may take some time.${RESET}\n"
        eval $MKFS_CMD
        
        if [ $? -eq 0 ]; then
            mv "$OUTPUT_IMG.tmp" "$OUTPUT_IMG"
            echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
            echo -e "${BLUE}Image size: $(du -h "$OUTPUT_IMG" | cut -f1)${RESET}"
        fi
        ;;

    2)
        # EXT4 flow
        MOUNT_POINT="${TEMP_ROOT}/ext4_mount"
        mkdir -p "$MOUNT_POINT"

        echo -e "\n${BLUE}${BOLD}Select EXT4 Repack Mode:${RESET}"
        echo -e "1. Strict (clone original image structure exactly - for repair)"
        echo -e "2. Flexible (auto-resize if content is larger - for customization)"
        read -p "Enter your choice [1-2]: " REPACK_MODE

        if [ "$REPACK_MODE" == "1" ]; then
            EXT4_MODE="strict"
        else
            EXT4_MODE="flexible"
        fi
        
        source "${REPACK_INFO}/metadata.txt"

        if [ -z "$ORIGINAL_BLOCK_COUNT" ]; then
            if [ -f "$SOURCE_IMAGE" ]; then
                ORIGINAL_BLOCK_COUNT=$(get_fs_param "$SOURCE_IMAGE" "Block count")
            else
                EXT4_MODE="flexible"
                FILESYSTEM_TYPE="unknown"
            fi
        fi

        if [ "$FILESYSTEM_TYPE" == "ext4" ]; then
            ORIGINAL_CAPACITY=$((ORIGINAL_BLOCK_COUNT * 4096))
        fi
        CURRENT_CONTENT_SIZE=$(du -sb --exclude=.repack_info "$EXTRACT_DIR" | awk '{print $1}')
        
        # --- START OF ENHANCED AUTOSIZING LOGIC ---

        if [ "$EXT4_MODE" == "flexible" ]; then
            echo -e "\n${YELLOW}${BOLD}Flexible mode: Auto-calculating exact required image size...${RESET}\n"

            # 1. Dry Run: Create an oversized sparse file to determine minimum size.
            DRY_RUN_IMG="${TEMP_ROOT}/dry_run.img"
            DRY_RUN_MOUNT="${TEMP_ROOT}/dry_run_mount"
            mkdir -p "$DRY_RUN_MOUNT"
            OVERSIZED_BYTES=$((CURRENT_CONTENT_SIZE + 500*1024*1024))
            truncate -s "$OVERSIZED_BYTES" "$DRY_RUN_IMG"
            mkfs.ext4 -q -m 0 "$DRY_RUN_IMG"
            mount -o loop,rw "$DRY_RUN_IMG" "$DRY_RUN_MOUNT"
            (cd "$EXTRACT_DIR" && tar --selinux --exclude=.repack_info -cf - .) | (cd "$DRY_RUN_MOUNT" && tar --selinux -xf -) >/dev/null 2>&1
            sync && umount "$DRY_RUN_MOUNT"
            
            # 2. Shrink to find the absolute minimum required size.
            e2fsck -fy "$DRY_RUN_IMG" >/dev/null 2>&1
            resize2fs -M "$DRY_RUN_IMG" >/dev/null 2>&1
            min_block_count=$(dumpe2fs -h "$DRY_RUN_IMG" 2>/dev/null | grep 'Block count:' | awk '{print $3}')
            rm -rf "$DRY_RUN_IMG" "$DRY_RUN_MOUNT"
            
            # 3. Calculate the final size with a standard 10% overhead for free space.
            final_block_count=$(echo "($min_block_count * 1.10) / 1" | bc)
            
            echo -e "${BLUE}Minimum blocks required: ${min_block_count}${RESET}"
            echo -e "${BLUE}Final blocks with overhead: ${final_block_count}${RESET}"
            
            # 4. Create the final image with the calculated size.
            dd if=/dev/zero of="$OUTPUT_IMG" bs=4096 count="$final_block_count" status=none
            if [ "$FILESYSTEM_TYPE" == "ext4" ]; then
                 mkfs.ext4 -q -b 4096 -I "$ORIGINAL_INODE_SIZE" -U "$ORIGINAL_UUID" -L "$ORIGINAL_VOLUME_NAME" -O "$ORIGINAL_FEATURES" "$OUTPUT_IMG"
            else
                 mkfs.ext4 -q "$OUTPUT_IMG"
            fi
            mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"

        else # Strict mode or Flexible mode where content fits
            if [ "$EXT4_MODE" == "strict" ] && [ "$FILESYSTEM_TYPE" != "ext4" ]; then
                echo -e "\n${RED}${BOLD}Error: Strict mode is only available when the source image is also ext4.${RESET}"
                echo -e "${RED}The source for this project was '${FILESYSTEM_TYPE}'. Please choose Flexible mode.${RESET}"
                exit 1
            fi
            echo -e "\n${GREEN}${BOLD}Content fits original size. Cloning filesystem structure...${RESET}"
            dd if=/dev/zero of="$OUTPUT_IMG" bs=4096 count="$ORIGINAL_BLOCK_COUNT" status=none
            mkfs.ext4 -q -b 4096 -I "$ORIGINAL_INODE_SIZE" -N "$ORIGINAL_INODE_COUNT" -U "$ORIGINAL_UUID" -L "$ORIGINAL_VOLUME_NAME" -O "$ORIGINAL_FEATURES" "$OUTPUT_IMG"
            mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"
        fi
        # --- END OF ENHANCED AUTOSIZING LOGIC ---

        # --- Common part for all EXT4 paths: Refill and Finalize ---
        echo -e "\n${BLUE}Copying files to final image...${RESET}"
        (cd "$EXTRACT_DIR" && tar --selinux --exclude=.repack_info -cf - .) | (cd "$MOUNT_POINT" && tar --selinux -xf -) &
        show_copy_progress "$EXTRACT_DIR" "$MOUNT_POINT"
        wait $!
        
        verify_modifications "$MOUNT_POINT"
        restore_attributes "$MOUNT_POINT"
        remove_repack_info "$MOUNT_POINT"
        
        echo -e "${BLUE}Unmounting image...${RESET}"
        sync && umount "$MOUNT_POINT"
        
        e2fsck -yf "$OUTPUT_IMG" >/dev/null 2>&1
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

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
