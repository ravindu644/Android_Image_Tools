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
    exit 1
}

# Register cleanup for interrupts and errors
trap cleanup INT TERM EXIT

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

restore_attributes() {
    echo -e "\n${BLUE}Initializing permission restoration...${RESET}"
    echo -e "${BLUE}┌─ Analyzing filesystem structure...${RESET}"
    
    # Process symlinks first using the special symlink info file
    if [ -f "${REPACK_INFO}/symlink_info.txt" ]; then
        while read -r line; do
            # Skip comments
            [[ "$line" =~ ^#.*$ ]] && continue
            
            # Format: path target uid gid mode context
            path=$(echo "$line" | awk '{print $1}')
            target=$(echo "$line" | awk '{print $2}')
            uid=$(echo "$line" | awk '{print $3}')
            gid=$(echo "$line" | awk '{print $4}')
            mode=$(echo "$line" | awk '{print $5}')
            context=$(echo "$line" | awk '{print $6}')
            
            full_path="$1$path"
            
            # Recreate symlink if it doesn't exist
            if [ ! -L "$full_path" ]; then
                ln -sf "$target" "$full_path"
            fi
            
            # Set ownership and context
            chown -h "$uid:$gid" "$full_path" 2>/dev/null || true
            [ -n "$context" ] && chcon -h "$context" "$full_path" 2>/dev/null || true
        done < "${REPACK_INFO}/symlink_info.txt"
    fi
    
    # Get filesystem counts
    DIR_COUNT=$(find "$1" -type d | wc -l)
    FILE_COUNT=$(find "$1" -type f | wc -l)
    
    echo -e "${BLUE}├─ Found ${BOLD}$DIR_COUNT${RESET}${BLUE} directories${RESET}"
    echo -e "${BLUE}└─ Found ${BOLD}$FILE_COUNT${RESET}${BLUE} files${RESET}\n"

    # First process directories
    echo -e "${BLUE}Processing directory structure...${RESET}"
    processed=0
    spin=0
    spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    # Create list of new directories by comparing with fs-config
    find "$1" -type d | while read -r item; do
        processed=$((processed + 1))
        percentage=$((processed * 100 / DIR_COUNT))
        
        rel_path=${item#$1}
        [ -z "$rel_path" ] && rel_path="/"
        
        # Check if directory exists in original config
        stored_attrs=$(grep "^$rel_path " "$FS_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2-)
        stored_context=$(grep "^$rel_path " "$FILE_CONTEXTS_FILE" 2>/dev/null | cut -d' ' -f2-)
        
        if [ -n "$stored_attrs" ]; then
            # Restore original attributes
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
        else
            # New directory - apply default permissions from parent
            parent_dir=$(dirname "$rel_path")
            parent_attrs=$(grep "^$parent_dir " "$FS_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2-)
            parent_context=$(grep "^$parent_dir " "$FILE_CONTEXTS_FILE" 2>/dev/null | cut -d' ' -f2-)
            
            if [ -n "$parent_attrs" ]; then
                uid=$(echo "$parent_attrs" | awk '{print $1}')
                gid=$(echo "$parent_attrs" | awk '{print $2}')
                chown "$uid:$gid" "$item" 2>/dev/null || true
                chmod 755 "$item" 2>/dev/null || true
            fi
            [ -n "$parent_context" ] && chcon "$parent_context" "$item" 2>/dev/null || true
        fi
        
        [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++))]}] Mapping contexts: ${percentage}% (${processed}/${DIR_COUNT})${RESET}"
        spin=$((spin % 10))
    done
    echo -e "\r\033[K${GREEN}[✓] Directory attributes mapped${RESET}\n"

    # Then process files
    echo -e "${BLUE}Processing file permissions...${RESET}"
    processed=0
    spin=0

    find "$1" -type f | while read -r item; do
        processed=$((processed + 1))
        percentage=$((processed * 100 / FILE_COUNT))
        
        rel_path=${item#$1}
        stored_attrs=$(grep "^$rel_path " "$FS_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2-)
        stored_context=$(grep "^$rel_path " "$FILE_CONTEXTS_FILE" 2>/dev/null | cut -d' ' -f2-)
        
        if [ -n "$stored_attrs" ]; then
            # Restore original attributes
            uid=$(echo "$stored_attrs" | awk '{print $1}')
            gid=$(echo "$stored_attrs" | awk '{print $2}')
            mode=$(echo "$stored_attrs" | awk '{print $3}')
            chown "$uid:$gid" "$item" 2>/dev/null || true
            chmod "$mode" "$item" 2>/dev/null || true
        else
            # New file - apply default permissions from parent
            parent_dir=$(dirname "$rel_path")
            parent_attrs=$(grep "^$parent_dir " "$FS_CONFIG_FILE" 2>/dev/null | cut -d' ' -f2-)
            parent_context=$(grep "^$parent_dir " "$FILE_CONTEXTS_FILE" 2>/dev/null | cut -d' ' -f2-)
            
            if [ -n "$parent_attrs" ]; then
                uid=$(echo "$parent_attrs" | awk '{print $1}')
                gid=$(echo "$parent_attrs" | awk '{print $2}')
                chown "$uid:$gid" "$item" 2>/dev/null || true
                chmod 644 "$item" 2>/dev/null || true
            fi
            [ -n "$parent_context" ] && chcon "$parent_context" "$item" 2>/dev/null || true
        fi
        
        # Always try to restore original context if available
        [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true

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
        cleanup
    fi
    
    verify_modifications "$WORK_DIR"
    restore_attributes "$WORK_DIR"
}

# Start repacking process with better visuals
echo -e "\n${BLUE}${BOLD}Starting EROFS repacking process...${RESET}"
echo -e "${BLUE}┌─ Source directory: ${BOLD}$EXTRACT_DIR${RESET}"
echo -e "${BLUE}└─ Target image: ${BOLD}$OUTPUT_IMG${RESET}\n"

prepare_working_directory

# Ask for compression method
echo -e "\n${BLUE}${BOLD}Select compression method:${RESET}"
echo -e "1. none (default)"
echo -e "2. lz4"
echo -e "3. lz4hc"
read -p "Enter your choice [1-3]: " COMP_CHOICE

case $COMP_CHOICE in
  2)
    COMPRESSION="-zlz4"
    ;;
  3)
    COMPRESSION="-zlz4hc"
    ;;
  *)
    COMPRESSION=""
    echo -e "${BLUE}Using no compression.${RESET}"
    ;;
esac

# Ask for compression level if using compression
if [[ "$COMPRESSION" == *"lz4"* ]]; then
  echo -e "\n${BLUE}${BOLD}Select compression level:${RESET}"
  echo -e "For lz4: 1-9 (default: 6, higher = better compression but slower)"
  echo -e "For lz4hc: 1-12 (default: 9, higher = better compression but slower)"
  read -p "Enter compression level: " COMP_LEVEL
  
  # Validate compression level
  if [[ "$COMPRESSION" == "-zlz4" && "$COMP_LEVEL" =~ ^[1-9]$ ]]; then
    COMPRESSION="$COMPRESSION,level=$COMP_LEVEL"
  elif [[ "$COMPRESSION" == "-zlz4hc" && "$COMP_LEVEL" =~ ^([1-9]|1[0-2])$ ]]; then
    COMPRESSION="$COMPRESSION,level=$COMP_LEVEL"
  elif [[ -n "$COMP_LEVEL" ]]; then
    echo -e "${YELLOW}Invalid compression level. Using default level.${RESET}"
  fi
fi

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

# On success, move temp file to final location
if [ $? -eq 0 ]; then
    mv "$OUTPUT_IMG.tmp" "$OUTPUT_IMG"
    echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
    echo -e "${BLUE}Image size: $(du -h "$OUTPUT_IMG" | cut -f1)${RESET}"
    
    # Transfer ownership back to actual user
    if [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"
    fi

    # Clear trap before normal exit
    trap - INT TERM EXIT
    cleanup
else
    echo -e "\n${RED}Error occurred during image creation.${RESET}"
    cleanup
fi

# Clean up temporary files
cleanup

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
