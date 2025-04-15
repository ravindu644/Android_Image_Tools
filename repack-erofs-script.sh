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

# Remove trailing slash if present
EXTRACT_DIR=${EXTRACT_DIR%/}

# Check if extracted directory exists
if [ ! -d "$EXTRACT_DIR" ]; then
  echo -e "${RED}Error: Directory '$EXTRACT_DIR' not found.${RESET}"
  exit 1
fi

PARTITION_NAME=$(basename "$EXTRACT_DIR" | sed 's/^extracted_//')
OUTPUT_IMG="${PARTITION_NAME}_repacked.img"
FS_CONFIG_FILE="${EXTRACT_DIR}/fs-config.txt"
FILE_CONTEXTS_FILE="${EXTRACT_DIR}/file_contexts.txt"
SYMLINKS_FILE="${EXTRACT_DIR}/symlinks.txt"

# Check if file attribute files exist
if [ ! -f "$FS_CONFIG_FILE" ]; then
  echo -e "${YELLOW}Warning: FS config file not found at ${FS_CONFIG_FILE}.${RESET}"
  echo -e "${YELLOW}File permissions and ownership will not be applied.${RESET}"
fi

if [ ! -f "$FILE_CONTEXTS_FILE" ]; then
  echo -e "${YELLOW}Warning: File contexts file not found at ${FILE_CONTEXTS_FILE}.${RESET}"
  echo -e "${YELLOW}SELinux contexts will not be applied.${RESET}"
fi

restore_attributes() {
    echo -e "\n${BLUE}Initializing permission restoration...${RESET}"
    echo -e "${BLUE}┌─ Analyzing filesystem structure...${RESET}"
    
    # Count dirs and files
    DIR_COUNT=$(find "$EXTRACT_DIR" -type d | wc -l)
    FILE_COUNT=$(find "$EXTRACT_DIR" -type f | wc -l)
    
    echo -e "${BLUE}├─ Found ${BOLD}$DIR_COUNT${RESET}${BLUE} directories${RESET}"
    echo -e "${BLUE}└─ Found ${BOLD}$FILE_COUNT${RESET}${BLUE} files${RESET}\n"
    
    # Read reference timestamp (created during unpack)
    TIMESTAMP_FILE="${EXTRACT_DIR}/.unpack_timestamp"
    if [ ! -f "$TIMESTAMP_FILE" ]; then
        echo -e "${YELLOW}No timestamp reference found. Nothing to restore.${RESET}"
        return
    fi

    echo -e "${BLUE}Scanning for modified files...${RESET}"
    
    # Since we used tar --selinux during unpack, we only need to handle 
    # permissions/ownership for modified files
    MODIFIED_FILES=$(find "$EXTRACT_DIR" -type f -newer "$TIMESTAMP_FILE" 2>/dev/null | grep -v "/.unpack_timestamp$" || true)
    
    # Count changes
    MOD_FILES_COUNT=$(echo "$MODIFIED_FILES" | grep -c '^' || echo 0)
    
    echo -e "${BLUE}Found ${MOD_FILES_COUNT} modified files${RESET}\n"

    # Only restore attributes for modified files
    if [ "$MOD_FILES_COUNT" -gt 0 ]; then
        echo -e "${BLUE}Restoring attributes for modified files...${RESET}"
        spin=0
        processed=0
        
        echo "$MODIFIED_FILES" | while read -r file; do
            [ -z "$file" ] && continue
            processed=$((processed + 1))
            percentage=$((processed * 100 / MOD_FILES_COUNT))
            rel_path=${file#$EXTRACT_DIR}
            
            # Only need to handle fs_config for modified files
            # SELinux context was preserved by tar --selinux
            attrs=$(grep "^$rel_path " "$FS_CONFIG_FILE" | cut -d' ' -f2-)
            
            if [ -n "$attrs" ]; then
                uid=$(echo "$attrs" | awk '{print $1}' | tr -d '\n')
                gid=$(echo "$attrs" | awk '{print $2}' | tr -d '\n')
                mode=$(echo "$attrs" | awk '{print $3}' | tr -d '\n')
                
                if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]]; then
                    chown "$uid:$gid" "$file" 2>/dev/null || true
                    chmod "$mode" "$file" 2>/dev/null || true
                fi
            fi
            
            echo -ne "\r${BLUE}[${spinner[$((spin++))]}] Processing: ${percentage}% (${processed}/${MOD_FILES_COUNT})${RESET}"
            spin=$((spin % 10))
        done
        echo -e "\r${GREEN}[✓] File attributes restored${RESET}\n"
    else
        echo -e "${GREEN}No modified files to process.${RESET}\n"
    fi
}

# Start repacking process
restore_attributes

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

# Add compression if selected
if [ -n "$COMPRESSION" ]; then
  MKFS_CMD="$MKFS_CMD $COMPRESSION"
fi

# Add output and input paths
MKFS_CMD="$MKFS_CMD $OUTPUT_IMG $EXTRACT_DIR"

# Show the command
echo -e "\n${BLUE}Executing command:${RESET}"
echo -e "${BOLD}$MKFS_CMD${RESET}\n"

# Create the EROFS image
echo -e "${BLUE}Creating EROFS image... This may take some time.${RESET}\n"
eval $MKFS_CMD

# Check if image creation was successful
if [ $? -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
  echo -e "${BLUE}Image size: $(du -h "$OUTPUT_IMG" | cut -f1)${RESET}"
  
  # Transfer ownership back to actual user
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$EXTRACT_DIR"
    chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"
  fi
else
  echo -e "\n${RED}Error occurred during image creation.${RESET}"
  exit 1
fi

# Clean up temporary files
rm -f /tmp/all_files.txt /tmp/config_files.txt /tmp/new_files.txt
rm -f /tmp/all_dirs.txt /tmp/special_paths.txt /tmp/new_dirs.txt /tmp/new_dirs_sorted.txt

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
