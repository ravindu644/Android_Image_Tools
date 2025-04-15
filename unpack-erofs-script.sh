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
RAW_IMAGE=""
FS_CONFIG_FILE="${EXTRACT_DIR}/fs-config.txt"
FILE_CONTEXTS_FILE="${EXTRACT_DIR}/file_contexts.txt"

# Check if image file exists
if [ ! -f "$IMAGE_FILE" ]; then
  echo -e "${RED}Error: Image file '$IMAGE_FILE' not found.${RESET}"
  exit 1
fi

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
  echo -e "${YELLOW}Removing existing mount directory...${RESET}\n"
  rm -rf "$MOUNT_DIR"
fi
mkdir -p "$MOUNT_DIR"

# Remove extraction directory if it exists
if [ -d "$EXTRACT_DIR" ]; then
  echo -e "${YELLOW}Removing existing extraction directory: ${EXTRACT_DIR}${RESET}"
  rm -rf "$EXTRACT_DIR"
fi
mkdir -p "$EXTRACT_DIR"

# Try to mount the image
echo -e "Attempting to mount ${BOLD}$IMAGE_FILE${RESET}..."
if ! mount -o loop,ro "$IMAGE_FILE" "$MOUNT_DIR" 2>/dev/null; then
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
    if ! mount -o loop,ro "$RAW_IMAGE" "$MOUNT_DIR" 2>/dev/null; then
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

# Copy files with preservation of permissions
echo -e "\n${BLUE}Extracting files from image...${RESET}"
echo -e "This may take some time depending on the size of the image...\n"

# Count total files for progress
total_files=$(find "$MOUNT_DIR" -type f,d,l | wc -l)
current=0

# Use tar with progress through a pipeline
(cd "$MOUNT_DIR" && tar --preserve-permissions -cf - .) | \
(cd "$EXTRACT_DIR" && tar -xf -) & 

# Show spinner while tar is running
spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
spin=0
while kill -0 $! 2>/dev/null; do
  current_files=$(find "$EXTRACT_DIR" -type f,d,l 2>/dev/null | wc -l)
  percentage=$((current_files * 100 / total_files))
  echo -ne "\r${BLUE}[${spinner[$((spin++))]}] Progress: ${percentage}% (${current_files}/${total_files} files)${RESET}"
  spin=$((spin % 10))
  sleep 0.1
done
echo -e "\r${GREEN}[✓] Extraction complete: ${total_files} files copied      ${RESET}\n"

# Extract metadata (contexts, permissions, symlinks) with progress
echo -e "${BLUE}Extracting file metadata...${RESET}"

# Extract SELinux contexts and permissions in a single pass
echo "# File contexts extracted from $IMAGE_FILE on $(date)" > "$FILE_CONTEXTS_FILE"
echo "# FS config extracted from $IMAGE_FILE on $(date)" > "$FS_CONFIG_FILE"
echo "# Symlinks extracted from $IMAGE_FILE on $(date)" > "${EXTRACT_DIR}/symlinks.txt"

total_items=$(find "$MOUNT_DIR" | wc -l)
current=0

find "$MOUNT_DIR" \( -type f -o -type d -o -type b -o -type c -o -type l \) | while read -r item; do
  current=$((current + 1))
  percentage=$((current * 100 / total_items))
  
  # Show progress every 100 items
  if [ $((current % 100)) -eq 0 ]; then
    echo -ne "\r${BLUE}Processing: ${percentage}% (${current}/${total_items})${RESET}"
  fi
  
  if [ -e "$item" ] || [ -L "$item" ]; then
    # Get relative path
    rel_path=${item#$MOUNT_DIR/}
    [ -z "$rel_path" ] && rel_path="/"
    
    if [ -L "$item" ]; then
      # Handle symlink
      target=$(readlink "$item")
      echo "$rel_path -> $target" >> "${EXTRACT_DIR}/symlinks.txt"
    else
      # Get SELinux context
      context=$(ls -dZ "$item" 2>/dev/null | awk '{print $1}')
      [ -n "$context" ] && [ "$context" != "?" ] && \
        echo "$rel_path $context" >> "$FILE_CONTEXTS_FILE"
      
      # Get permissions
      stats=$(stat -c "%u %g %a" "$item" 2>/dev/null)
      [ -n "$stats" ] && \
        echo "$rel_path $stats capabilities=0x0" >> "$FS_CONFIG_FILE"
    fi
  fi
done
echo -e "\r${GREEN}[✓] Metadata extraction complete                ${RESET}\n"

# Verify extraction
if [ $? -eq 0 ]; then
  echo -e "${GREEN}Extraction completed successfully.${RESET}\n"
  echo -e "${BOLD}Files extracted to: ${EXTRACT_DIR}${RESET}"
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
  echo -e "${GREEN}Image unmounted successfully.${RESET}"
fi

echo -e "${GREEN}${BOLD}Done!${RESET}"
