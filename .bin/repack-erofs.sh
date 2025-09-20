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
TEMP_ROOT="/tmp/repack-erofs"
WORK_DIR="${TEMP_ROOT}/${PARTITION_NAME}_work"
MOUNT_POINT=""

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

calculate_optimal_ext4_size() {
    local content_dir="$1"
    local overhead_percent="${2:-15}"
    
    # Send debug output to stderr so it doesn't interfere with return value
    echo -e "${BLUE}Calculating optimal image size...${RESET}" >&2
    
    # Step 1: Get actual content size (excluding .repack_info)
    local content_bytes=$(du -sb --exclude=.repack_info "$content_dir" | awk '{print $1}')
    echo -e "${BLUE}├─ Content size: $(numfmt --to=iec-i --suffix=B $content_bytes)${RESET}" >&2
    
    # Step 2: Calculate ext4 metadata overhead
    # Count files and directories for inode calculation
    local file_count=$(find "$content_dir" -not -path "*/.repack_info/*" | wc -l)
    local dir_count=$(find "$content_dir" -type d -not -path "*/.repack_info/*" | wc -l)
    
    # Calculate required inodes (files + dirs + some buffer for lost+found, etc.)
    local required_inodes=$((file_count + dir_count + 100))
    
    # Ext4 uses 1 inode per 16KB by default, but we'll be more precise
    local inode_size=256  # Default inode size
    local block_size=4096
    
    # Calculate minimum blocks needed for inodes
    local inode_table_blocks=$(( (required_inodes * inode_size + block_size - 1) / block_size ))
    
    # Calculate ext4 filesystem overhead (approximately 5-7% for metadata)
    local fs_metadata_overhead=$((content_bytes * 7 / 100))
    
    # Step 3: Calculate base filesystem size
    local base_fs_size=$((content_bytes + fs_metadata_overhead + inode_table_blocks * block_size))
    
    echo -e "${BLUE}├─ Metadata overhead: $(numfmt --to=iec-i --suffix=B $fs_metadata_overhead)${RESET}" >&2
    echo -e "${BLUE}├─ Required inodes: $required_inodes${RESET}" >&2
    
    # Step 4: Add user-specified overhead (using integer arithmetic)
    local user_overhead=$((base_fs_size * overhead_percent / 100))
    local final_size=$((base_fs_size + user_overhead))
    
    # Step 5: Round up to nearest block boundary
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
    
    # Get optimal size using our smart calculation
    local optimal_blocks=$(calculate_optimal_ext4_size "$extract_dir" "$overhead_percent")
    
    echo -e "\n${BLUE}Creating optimally sized ext4 image...${RESET}"
    
    # Create the image with calculated size
    dd if=/dev/zero of="$output_img" bs=4096 count="$optimal_blocks" status=none
    
    # Format with optimal settings
    if [ "$FILESYSTEM_TYPE" == "ext4" ] && [ -n "$ORIGINAL_UUID" ]; then
        # Preserve original filesystem characteristics when available
        mkfs.ext4 -q -b 4096 -I "$ORIGINAL_INODE_SIZE" -U "$ORIGINAL_UUID" -L "$ORIGINAL_VOLUME_NAME" -O "$ORIGINAL_FEATURES" "$output_img"
    else
        # Use optimized defaults for new filesystem
        mkfs.ext4 -q -b 4096 -i 16384 -m 1 -O ^has_journal,^resize_inode,dir_index,extent,sparse_super "$output_img"
    fi
    
    # Mount the new filesystem
    mkdir -p "$mount_point"
    mount -o loop,rw "$output_img" "$mount_point"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Failed to mount created image${RESET}"
        return 1
    fi
    
    echo -e "${GREEN}✓ Image created and mounted successfully${RESET}"
    
    # Verify we have enough space
    local available_space=$(df --output=avail -B1 "$mount_point" | tail -n1)
    local total_space=$(df --output=size -B1 "$mount_point" | tail -n1)
    local content_size=$(du -sb --exclude=.repack_info "$extract_dir" | awk '{print $1}')
    
    if [ "$available_space" -lt "$content_size" ]; then
        echo -e "${RED}Error: Insufficient space in created image${RESET}"
        umount "$mount_point"
        return 1
    fi
    
    local free_after_copy=$((available_space - content_size))
    local free_percentage=$(( free_after_copy * 100 / total_space ))
    echo -e "${BLUE}Available space: $(numfmt --to=iec-i --suffix=B $available_space) (~${free_percentage}% free after copy)${RESET}"
    
    return 0
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

# Add filesystem selection before any operations
if [ -z "$FS_CHOICE" ]; then
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
        MKFS_CMD="$MKFS_CMD $OUTPUT_IMG.tmp $WORK_DIR"

        echo -e "\n${BLUE}Executing command:${RESET}"
        echo -e "${BOLD}$MKFS_CMD${RESET}\n"

        echo -e "${BLUE}Creating EROFS image... This may take some time.${RESET}\n"
        eval $MKFS_CMD
        
        mv "$OUTPUT_IMG.tmp" "$OUTPUT_IMG"
        echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
        echo -e "${BLUE}Image size: $(stat -c %s "$OUTPUT_IMG" | numfmt --to=iec-i --suffix=B)${RESET}"
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
        
        # Source metadata first to get variables
        source "${REPACK_INFO}/metadata.txt"

        if [ -z "$ORIGINAL_BLOCK_COUNT" ]; then
            if [ -f "$SOURCE_IMAGE" ]; then
                ORIGINAL_BLOCK_COUNT=$(get_fs_param "$SOURCE_IMAGE" "Block count")
            else
                if [ "$EXT4_MODE" == "strict" ]; then
                    echo -e "${YELLOW}Warning: Original image not found. Forcing Flexible mode.${RESET}"
                    EXT4_MODE="flexible"
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
            
            # Use the new intelligent approach
            create_ext4_flexible "$EXTRACT_DIR" "$OUTPUT_IMG" "$MOUNT_POINT" "$EXT4_OVERHEAD_PERCENT"
            if [ $? -ne 0 ]; then
                echo -e "${RED}Failed to create flexible ext4 image${RESET}"
                exit 1
            fi

        else # Strict mode
            if [ "$FILESYSTEM_TYPE" != "ext4" ]; then
                echo -e "\n${RED}${BOLD}Error: Strict mode is only available when the source image is also ext4.${RESET}"; exit 1
            fi
            echo -e "\n${GREEN}${BOLD}Strict mode: Cloning original filesystem structure...${RESET}"
            dd if=/dev/zero of="$OUTPUT_IMG" bs=4096 count="$ORIGINAL_BLOCK_COUNT" status=none
            mkfs.ext4 -q -b 4096 -I "$ORIGINAL_INODE_SIZE" -N "$ORIGINAL_INODE_COUNT" -U "$ORIGINAL_UUID" -L "$ORIGINAL_VOLUME_NAME" -O "$ORIGINAL_FEATURES" "$OUTPUT_IMG"
            mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"
        fi
        
        echo -e "\n${BLUE}Copying files to final image...${RESET}"
        (cd "$EXTRACT_DIR" && tar --selinux --exclude=.repack_info -cf - .) | (cd "$MOUNT_POINT" && tar --selinux -xf -) &
        show_copy_progress "$EXTRACT_DIR" "$MOUNT_POINT"
        wait $!
        
        verify_modifications "$MOUNT_POINT"
        restore_attributes "$MOUNT_POINT"
        remove_repack_info "$MOUNT_POINT"
        
        echo -e "${BLUE}Unmounting image...${RESET}"
        sync && umount "$MOUNT_POINT"
        
        e2fsck -yf "$OUTPUT_IMG" >/dev/null 2>/dev/null
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
