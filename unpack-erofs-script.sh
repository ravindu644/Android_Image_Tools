#!/bin/bash
# EROFS Image Unpacker Script with File Attribute Preservation
# Usage: ./unpack_erofs.sh <image_file>

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
  echo "│         Unpack EROFS - by @ravindu644     │"
  echo "└───────────────────────────────────────────┘"
  echo -e "${RESET}"
}

print_banner

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"
  exit 1
fi

# Check if image file is provided
if [ $# -ne 1 ]; then
  echo -e "${YELLOW}Usage: $0 <image_file>${RESET}"
  echo -e "Example: $0 vendor.img"
  exit 1
fi

IMAGE_FILE="$1"
PARTITION_NAME=$(basename "$IMAGE_FILE" .img)
MOUNT_DIR="/tmp/${PARTITION_NAME}_mount"
EXTRACT_DIR="extracted_${PARTITION_NAME}"
REPACK_INFO="${EXTRACT_DIR}/.repack_info"
RAW_IMAGE=""
FS_CONFIG_FILE="${REPACK_INFO}/fs-config.txt"
FILE_CONTEXTS_FILE="${REPACK_INFO}/file_contexts.txt"

# Check if image file exists
if [ ! -f "$IMAGE_FILE" ]; then
  echo -e "${RED}Error: Image file '$IMAGE_FILE' not found.${RESET}"
  exit 1
fi

# Add show_progress function before cleanup()
show_progress() {
    local pid=$1
    local target=$2
    local total=$3
    local spin=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

    while kill -0 $pid 2>/dev/null; do
        current_size=$(du -sb "$target" | cut -f1)
        percentage=$((current_size * 100 / total))
        current_hr=$(numfmt --to=iec-i --suffix=B "$current_size")
        total_hr=$(numfmt --to=iec-i --suffix=B "$total")
        
        # Clear entire line before printing
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Copying: ${percentage}% (${current_hr}/${total_hr})${RESET}"
        sleep 0.1
    done
    
    # Clear line and show completion
    echo -e "\r\033[K${GREEN}[✓] Copy completed${RESET}\n"
}

# Function to clean up mount point and temporary files
cleanup() {
  echo -e "\n${YELLOW}Cleaning up...${RESET}"
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    echo -e "Unmounting ${MOUNT_DIR}..."
    umount "$MOUNT_DIR" 2>/dev/null || true
  fi
  
  # Remove raw image if it was created
  if [ -n "$RAW_IMAGE" ] && [ -f "$RAW_IMAGE" ]; then
    echo -e "Removing temporary raw image..."
    rm -f "$RAW_IMAGE" 2>/dev/null || true
  fi
  
  # Remove mount directory
  if [ -d "$MOUNT_DIR" ]; then
    echo -e "Removing mount directory..."
    rm -rf "$MOUNT_DIR" 2>/dev/null || true
  fi
  
  echo -e "Cleanup completed."
}

# Register cleanup function to run on script exit or interrupt
trap cleanup EXIT INT TERM

# Create or recreate mount directory
if [ -d "$MOUNT_DIR" ]; then
  echo -e "${YELLOW}Removing existing mount directory...${RESET}"
  rm -rf "$MOUNT_DIR"
fi
mkdir -p "$MOUNT_DIR"

# Create extraction and repack info directories
if [ -d "$EXTRACT_DIR" ]; then
  echo -e "${YELLOW}Removing existing extraction directory: ${EXTRACT_DIR}${RESET}"
  rm -rf "$EXTRACT_DIR"
fi
mkdir -p "$EXTRACT_DIR"
mkdir -p "$REPACK_INFO"

# Try to mount the image
echo -e "Attempting to mount ${BOLD}$IMAGE_FILE${RESET}..."

# First, try a read-write mount to handle journal recovery, then immediately remount as read-only.
if ! (mount -o loop "$IMAGE_FILE" "$MOUNT_DIR" 2>/dev/null && mount -o remount,ro "$MOUNT_DIR" 2>/dev/null); then
  echo -e "${YELLOW}Direct mounting failed. Trying to convert image...${RESET}"
  
  # Try to determine image format
  IMAGE_TYPE=$(file "$IMAGE_FILE" | grep -o -E 'Android.*|Linux.*|EROFS.*|data')
  
  if [ -n "$IMAGE_TYPE" ]; then
    echo -e "${BLUE}Detected image type: ${BOLD}$IMAGE_TYPE${RESET}"
    
    # Create a raw copy to try mounting
    RAW_IMAGE="${IMAGE_FILE%.img}_raw.img"
    echo -e "${BLUE}Creating raw image as ${BOLD}$RAW_IMAGE${RESET}${BLUE}...${RESET}"
    
    # Try using simg2img for sparse images
    if command -v simg2img &> /dev/null; then
      echo -e "${BLUE}Converting with simg2img...${RESET}"
      simg2img "$IMAGE_FILE" "$RAW_IMAGE"
    else
      # Simple copy as fallback
      echo -e "${YELLOW}simg2img not found, creating direct copy...${RESET}"
      cp "$IMAGE_FILE" "$RAW_IMAGE"
    fi
    
    echo -e "${BLUE}Attempting to mount raw image...${RESET}"
    if ! (mount -o loop "$RAW_IMAGE" "$MOUNT_DIR" 2>/dev/null && mount -o remount,ro "$MOUNT_DIR" 2>/dev/null); then
      echo -e "${RED}Failed to mount even after conversion. No luck with this image.${RESET}"
      exit 1
    fi
    
    echo -e "${GREEN}Successfully mounted raw image.${RESET}"
  else
    echo -e "${RED}Failed to identify image type for conversion. No luck with this image.${RESET}"
    exit 1
  fi
else
  echo -e "${GREEN}Successfully mounted original image.${RESET}"
fi

# First get root directory context specifically
echo -e "\n${BLUE}Capturing root directory attributes...${RESET}"
ROOT_CONTEXT=$(ls -dZ "$MOUNT_DIR" | awk '{print $1}')
ROOT_STATS=$(stat -c "%u %g %a" "$MOUNT_DIR")

# Create config files with root attributes first
echo "# FS config extracted from $IMAGE_FILE on $(date)" > "$FS_CONFIG_FILE"
echo "/ $ROOT_STATS" >> "$FS_CONFIG_FILE"

echo "# File contexts extracted from $IMAGE_FILE on $(date)" > "$FILE_CONTEXTS_FILE"
echo "/ $ROOT_CONTEXT" >> "$FILE_CONTEXTS_FILE"

# Extract metadata with progress
echo -e "\n${BLUE}Extracting file attributes...${RESET}"
total_items=$(find "$MOUNT_DIR" -mindepth 1 | wc -l)
processed=0
spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
spin=0

# Create a special file for symlink info
SYMLINK_INFO="${REPACK_INFO}/symlink_info.txt"
echo "# Symlink info extracted from $IMAGE_FILE on $(date)" > "$SYMLINK_INFO"

find "$MOUNT_DIR" -mindepth 1 | while read -r item; do
    processed=$((processed + 1))
    percentage=$((processed * 100 / total_items))
    
    if [ $((processed % 50)) -eq 0 ]; then
        echo -ne "\r${BLUE}[${spinner[$((spin++ % 10))]}] Processing: ${percentage}% (${processed}/${total_items})${RESET}"
    fi
    
    rel_path=${item#$MOUNT_DIR}
    
    # Special handling for symlinks
    if [ -L "$item" ]; then
        target=$(readlink "$item")
        stats=$(stat -c "%u %g %a" "$item" 2>/dev/null)
        context=$(ls -dZ "$item" 2>/dev/null | awk '{print $1}')
        echo "$rel_path $target $stats $context" >> "$SYMLINK_INFO"
    else
        # Get basic attributes and context
        stats=$(stat -c "%u %g %a" "$item" 2>/dev/null)
        context=$(ls -dZ "$item" 2>/dev/null | awk '{print $1}')
        
        [ -n "$stats" ] && echo "$rel_path $stats" >> "$FS_CONFIG_FILE"
        [ -n "$context" ] && [ "$context" != "?" ] && echo "$rel_path $context" >> "$FILE_CONTEXTS_FILE"
    fi
done
echo -e "\r${GREEN}[✓] Attributes extracted successfully${RESET}\n"

# Calculate checksums with spinner
echo -e "${BLUE}Calculating original file checksums...${RESET}"
(cd "$MOUNT_DIR" && find . -type f -exec sha256sum {} \;) > "${REPACK_INFO}/original_checksums.txt" &
spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
spin=0
while kill -0 $! 2>/dev/null; do
    # Clear entire line first
    echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Generating checksums${RESET}"
    sleep 0.1
done

# Clear line and show completion
echo -e "\r\033[K${GREEN}[✓] Checksums generated${RESET}\n"

# Copy files with SELinux contexts preserved
echo -e "${BLUE}Copying files with preserved attributes...${RESET}"
echo -e "${BLUE}┌─ Source: ${MOUNT_DIR}${RESET}"
echo -e "${BLUE}└─ Target: ${EXTRACT_DIR}${RESET}\n"

# Calculate total size for progress
total_size=$(du -sb "$MOUNT_DIR" | cut -f1)

# Use tar with selinux flag for proper context preservation
if command -v pv >/dev/null 2>&1; then
    (cd "$MOUNT_DIR" && tar --selinux -cf - .) | \
    pv -s "$total_size" -N "Copying" | \
    (cd "$EXTRACT_DIR" && tar --selinux -xf -)
    echo -e "\n${GREEN}[✓] Files copied successfully with SELinux contexts${RESET}"
else
    # Use custom progress display
    (cd "$MOUNT_DIR" && tar --selinux -cf - .) | \
    (cd "$EXTRACT_DIR" && tar --selinux -xf -) & 
    show_progress $! "$EXTRACT_DIR" "$total_size"
    wait $!
    # No need for another success message as show_progress already prints one
fi

# Verify copy succeeded
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[✓] Files copied successfully with SELinux contexts${RESET}"
else
    echo -e "\n${RED}[!] Error occurred during copy${RESET}"
    exit 1
fi

# Store timestamp and metadata location for repacking
echo "UNPACK_TIME=$(date +%s)" > "${REPACK_INFO}/metadata.txt"
echo "SOURCE_IMAGE=$IMAGE_FILE" >> "${REPACK_INFO}/metadata.txt"

# Verify extraction
if [ $? -eq 0 ]; then
  echo -e "\n${GREEN}Extraction completed successfully.${RESET}"
  echo -e "${BOLD}Files extracted to: ${EXTRACT_DIR}${RESET}"
  echo -e "${BOLD}Repack info stored in: ${REPACK_INFO}${RESET}"
  echo -e "${BOLD}File contexts saved to: ${FILE_CONTEXTS_FILE}${RESET}"
  echo -e "${BOLD}FS config saved to: ${FS_CONFIG_FILE}${RESET}\n"

  # Transfer ownership to actual user
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$EXTRACT_DIR"
  fi
else
  echo -e "${RED}Error occurred during extraction.${RESET}"
  exit 1
fi

# Unmount the image
if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
  umount "$MOUNT_DIR"
  echo -e "\n${GREEN}Image unmounted successfully.${RESET}"
fi

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
