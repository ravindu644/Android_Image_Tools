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
    [ -d "$TEMP_ROOT" ] && rm -rf "$TEMP_ROOT"
    # In case script is interrupted during image creation
    [ -f "$OUTPUT_IMG.tmp" ] && rm -f "$OUTPUT_IMG.tmp"
    echo -e "${GREEN}Cleanup completed.${RESET}"
    # Only exit with error if called from trap
    [ "$1" = "ERROR" ] && exit 1 || exit 0
}

# Register cleanup for interrupts and errors
trap 'cleanup ERROR' INT TERM EXIT

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
    local type="$2"  # "file" or "dir"
    local extension=""
    
    if [ "$type" = "file" ]; then
        extension=$(echo "$path" | grep -o '\.[^.]*$' || echo "")
        if [ -n "$extension" ]; then
            # First try exact extension match
            pattern=$(grep "$extension " "$FS_CONFIG_FILE" | head -n1)
            if [ -n "$pattern" ]; then
                echo "$pattern"
                return
            fi
        fi
    fi
    
    # Get parent directory's attributes as fallback
    parent_dir=$(dirname "$path")
    parent_pattern=$(grep "^$parent_dir " "$FS_CONFIG_FILE" | head -n1)
    echo "$parent_pattern"
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
    
    # Get counts for progress display
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
        
        # Try to find matching attributes
        if ! grep -q "^$rel_path " "$FS_CONFIG_FILE" 2>/dev/null; then
            # New directory - find matching pattern
            pattern=$(find_matching_pattern "$rel_path" "dir")
            if [ -n "$pattern" ]; then
                uid=$(echo "$pattern" | awk '{print $2}')
                gid=$(echo "$pattern" | awk '{print $3}')
                mode=$(echo "$pattern" | awk '{print $4}')
            else
                # Default fallback
                uid=0; gid=0; mode=755
            fi
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            
            # Try to find matching context
            context=$(grep "^$(dirname "$rel_path") " "$FILE_CONTEXTS_FILE" | cut -d' ' -f2- | head -n1)
            [ -n "$context" ] && chcon "$context" "$item" 2>/dev/null || true
        else
            # Existing directory - restore original attributes
            stored_attrs=$(grep "^$rel_path " "$FS_CONFIG_FILE" | cut -d' ' -f2-)
            stored_context=$(grep "^$rel_path " "$FILE_CONTEXTS_FILE" | cut -d' ' -f2-)
            
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')
            
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        fi
        
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++))]}] Mapping contexts: ${percentage}% (${processed}/${DIR_COUNT})${RESET}"
        spin=$((spin % 10))
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
        
        # Try to find matching attributes
        if ! grep -q "^$rel_path " "$FS_CONFIG_FILE" 2>/dev/null; then
            # New file - find matching pattern
            pattern=$(find_matching_pattern "$rel_path" "file")
            if [ -n "$pattern" ]; then
                uid=$(echo "$pattern" | awk '{print $2}')
                gid=$(echo "$pattern" | awk '{print $3}')
                mode=$(echo "$pattern" | awk '{print $4}')
            else
                # Default fallback
                uid=0; gid=0; mode=644
            fi
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            
            # Try to find matching context
            ext=$(echo "$rel_path" | grep -o '\.[^.]*$' || echo "")
            if [ -n "$ext" ]; then
                context=$(grep "$ext" "$FILE_CONTEXTS_FILE" | head -n1 | cut -d' ' -f2-)
                [ -n "$context" ] && chcon "$context" "$item" 2>/dev/null || true
            fi
        else
            # Existing file - restore original attributes
            stored_attrs=$(grep "^$rel_path " "$FS_CONFIG_FILE" | cut -d' ' -f2-)
            stored_context=$(grep "^$rel_path " "$FILE_CONTEXTS_FILE" | cut -d' ' -f2-)
            
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')
            
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        fi

        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++))]}] Restoring contexts: ${percentage}% (${processed}/${FILE_COUNT})${RESET}"
        spin=$((spin % 10))
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
    echo -e "\r\033[K${GREEN}[✓] Files copied to work directory${RESET}\n"
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
        echo -e "\n${BLUE}Calculating image size...${RESET}"
        INPUT_SIZE=$(du -sb "$EXTRACT_DIR" | cut -f1)
        SIZE_WITH_OVERHEAD=$(echo "($INPUT_SIZE * 1.1 + 0.5)/1" | bc)
        BLOCK_COUNT=$(echo "($SIZE_WITH_OVERHEAD + 4095) / 4096" | bc)
        MOUNT_POINT="${TEMP_ROOT}/ext4_mount"
        
        # Create directories
        mkdir -p "$TEMP_ROOT"
        mkdir -p "$MOUNT_POINT"
        
        # Create and format image
        echo -e "${BLUE}Creating ext4 image...${RESET}"
        dd if=/dev/zero of="$OUTPUT_IMG" bs=4096 count="$BLOCK_COUNT" status=none
        
        mkfs.ext4 -q \
            -O ext_attr,dir_index,filetype,extent,sparse_super,large_file,huge_file,uninit_bg,dir_nlink,extra_isize \
            -O ^has_journal,^resize_inode,^64bit,^flex_bg,^metadata_csum "$OUTPUT_IMG"
        
        # Mount
        echo -e "${BLUE}Mounting image...${RESET}"
        mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"
        
        # Copy files
        echo -e "\n${BLUE}Copying files and setting attributes...${RESET}"
        (cd "$EXTRACT_DIR" && tar --selinux -cf - .) | (cd "$MOUNT_POINT" && tar --selinux -xf -) &
        show_copy_progress "$EXTRACT_DIR" "$MOUNT_POINT"
        wait $!
        
        # Verify and restore
        verify_modifications "$MOUNT_POINT"
        restore_attributes "$MOUNT_POINT"
        remove_repack_info "$MOUNT_POINT"
        
        # Unmount
        echo -e "${BLUE}Unmounting image...${RESET}"
        sync >/dev/null 2>&1
        umount "$MOUNT_POINT" >/dev/null 2>&1
        
        # Final filesystem check
        e2fsck -yf "$OUTPUT_IMG" >/dev/null 2>&1
        
        # Set permissions and cleanup
        [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"
        rm -rf "$MOUNT_POINT" >/dev/null 2>&1
        
        echo -e "\n${GREEN}${BOLD}Successfully created EXT4 image: $OUTPUT_IMG${RESET}"
        echo -e "${BLUE}Image size: $(du -h "$OUTPUT_IMG" | cut -f1)${RESET}"
        exit 0
        ;;
        
    *)
        echo -e "${RED}Invalid choice. Exiting.${RESET}"
        cleanup ERROR
        exit 1
        ;;
esac

# Transfer ownership back to actual user
if [ -n "$SUDO_USER" ]; then
    chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"
fi

# Clear trap before normal exit
trap - INT TERM EXIT
cleanup

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
