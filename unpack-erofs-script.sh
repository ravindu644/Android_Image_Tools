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

# Extract SELinux contexts
echo -e "\n${BLUE}Extracting file contexts...${RESET}"
echo "# File contexts extracted from $IMAGE_FILE on $(date)" > "$FILE_CONTEXTS_FILE"
echo "# Format: <path> <user>:<role>:<type>:<range>" >> "$FILE_CONTEXTS_FILE"

# Extract FS config info (ownership and permissions)
echo -e "${BLUE}Extracting file ownership and permissions...${RESET}"
echo "# FS config extracted from $IMAGE_FILE on $(date)" > "$FS_CONFIG_FILE"
echo "# Format: <path> <uid> <gid> <mode> capabilities=<cap>" >> "$FS_CONFIG_FILE"

# Copy files with preservation of permissions
echo -e "\nExtracting files with preserved attributes..."
echo -e "This may take some time depending on the size of the image...\n"

# First copy all the files
(cd "$MOUNT_DIR" && tar --preserve-permissions -cf - .) | (cd "$EXTRACT_DIR" && tar -xf -)

# Extract SELinux contexts - using a better approach for selinux
echo -e "${BLUE}Extracting SELinux contexts...${RESET}"
if command -v ls &> /dev/null; then
  # We'll use find to get all files and then ls -Z to get their contexts
  find "$MOUNT_DIR" -type f -o -type d -o -type b -o -type c | while read -r item; do
    if [ -e "$item" ]; then
      # Get relative path
      rel_path=${item#$MOUNT_DIR/}
      if [ -z "$rel_path" ]; then
        rel_path="/"
      fi
      
      # Get SELinux context using ls -Z
      context=$(ls -dZ "$item" 2>/dev/null | awk '{print $1}')
      
      if [ -n "$context" ] && [ "$context" != "?" ]; then
        echo "$rel_path $context" >> "$FILE_CONTEXTS_FILE"
      fi
    fi
  done
fi

# Extract ownership and permissions
echo -e "${BLUE}Extracting ownership and permissions...${RESET}"
find "$MOUNT_DIR" -type f -o -type d -o -type b -o -type c | while read -r item; do
  if [ -e "$item" ]; then
    # Get relative path
    rel_path=${item#$MOUNT_DIR/}
    if [ -z "$rel_path" ]; then
      rel_path="/"
    fi
    
    # Get file stats
    stats=$(stat -c "%u %g %a" "$item" 2>/dev/null)
    if [ -n "$stats" ]; then
      uid=$(echo "$stats" | cut -d' ' -f1)
      gid=$(echo "$stats" | cut -d' ' -f2)
      mode=$(echo "$stats" | cut -d' ' -f3)
      echo "$rel_path $uid $gid $mode capabilities=0x0" >> "$FS_CONFIG_FILE"
    fi
  fi
done

# Special handling for symlinks
echo -e "${BLUE}Processing symlinks...${RESET}"
echo "# Symlinks extracted from $IMAGE_FILE on $(date)" > "${EXTRACT_DIR}/symlinks.txt"
echo "# Format: <path> -> <target>" >> "${EXTRACT_DIR}/symlinks.txt"

find "$MOUNT_DIR" -type l | while read -r link; do
  rel_path=${link#$MOUNT_DIR/}
  target=$(readlink "$link")
  echo "$rel_path -> $target" >> "${EXTRACT_DIR}/symlinks.txt"
done

# Verify extraction
if [ $? -eq 0 ]; then
  echo -e "${GREEN}Extraction completed successfully.${RESET}\n"
  echo -e "${BOLD}Files extracted to: ${EXTRACT_DIR}${RESET}"
  echo -e "${BOLD}File contexts saved to: ${FILE_CONTEXTS_FILE}${RESET}"
  echo -e "${BOLD}FS config saved to: ${FS_CONFIG_FILE}${RESET}\n"
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
