#!/bin/bash
# EROFS Image Unpacker Script with File Attribute Preservation
# Usage: ./unpack_erofs.sh <image_file> [output_directory] [--no-banner]

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

# --- Start of Custom Tweaks ---
# Argument parsing to handle calls from the wrapper script and enable a quiet mode.

# Initialize variables
IMAGE_FILE=""
OUTPUT_DIR_OVERRIDE=""
# This flag controls all interactive elements (banner, progress bars)
INTERACTIVE_MODE=true

# Manual parsing loop
while (( "$#" )); do
  case "$1" in
    --no-banner)
      INTERACTIVE_MODE=false
      shift
      ;;
    -*) # Catch any unexpected flags
      echo -e "${RED}Error: Unknown option $1${RESET}" >&2
      echo -e "${YELLOW}Usage: $0 <image_file> [output_directory] [--no-banner]${RESET}"
      exit 1
      ;;
    *) # Handle positional arguments
      if [ -z "$IMAGE_FILE" ]; then
        IMAGE_FILE="$1"
      elif [ -z "$OUTPUT_DIR_OVERRIDE" ]; then
        OUTPUT_DIR_OVERRIDE="$1"
      else
        echo -e "${RED}Error: Too many arguments. Unexpected: $1${RESET}" >&2
        echo -e "${YELLOW}Usage: $0 <image_file> [output_directory] [--no-banner]${RESET}"
        exit 1
      fi
      shift
      ;;
  esac
done

if [ "$INTERACTIVE_MODE" = true ]; then
    print_banner
fi
# --- End of Custom Tweaks ---

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"
  exit 1
fi

# Check if an image file was provided in the arguments
if [ -z "$IMAGE_FILE" ]; then
  echo -e "${YELLOW}Usage: $0 <image_file> [output_directory]${RESET}"
  echo -e "Example: $0 vendor.img"
  exit 1
fi

PARTITION_NAME=$(basename "$IMAGE_FILE" .img)
# --- Start of Custom Tweaks ---
# Use the override if provided, otherwise use the default
if [ -n "$OUTPUT_DIR_OVERRIDE" ]; then
  EXTRACT_DIR="$OUTPUT_DIR_OVERRIDE"
else
  EXTRACT_DIR="extracted_${PARTITION_NAME}"
fi
# --- End of Custom Tweaks ---
MOUNT_DIR="/tmp/${PARTITION_NAME}_mount"
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
    
    # --- Start of Custom Tweaks ---
    # REFINED: Clear the line on completion but DO NOT print a success message here.
    # The final verification block is the single source of truth for success.
    echo -e "\r\033[K"
    # --- End of Custom Tweaks ---
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

# Function to explicitly handle 'needs journal recovery' state
handle_journal_recovery() {
    local image_file="$1"
    # Silently check if the state exists using the 'file' command.
    if file "$image_file" 2>/dev/null | grep -q "needs journal recovery"; then
        echo -e "${YELLOW}${BOLD}Warning: Filesystem needs journal recovery.${RESET}\n"

        # when e2fsck returns 1 (which means success with corrections).
        if e2fsck -fy "$image_file" >/dev/null 2>&1; then
            echo -e "${GREEN}${BOLD}[✓] Journal replayed successfully. Filesystem is clean.${RESET}"
        else
            # Exit code was non-zero. We must check if it was a success code (1 or 2).
            local exit_code=$?
            if [ $exit_code -le 2 ]; then
                echo -e "${GREEN}${BOLD}[✓] Journal replayed successfully. Filesystem is clean.${RESET}\n"
            else
                echo -e "${RED}${BOLD}Error: Failed to replay journal. The image may be corrupt (e2fsck exit code: $exit_code).${RESET}"
                exit 1
            fi
        fi
    fi
}

# Function to detect and disable the 'shared_blocks' feature on ext images
handle_shared_blocks() {
    local image_file="$1"
    # Silently check if the feature exists. This is the main condition.
    if tune2fs -l "$image_file" 2>/dev/null | grep -q "shared_blocks"; then
        echo -e "\n${YELLOW}${BOLD}Warning: Incompatible 'shared_blocks' feature detected.${RESET}\n"
        
        # Use the correct e2fsck command to unshare the blocks. Suppress verbose output.
        if e2fsck -E unshare_blocks -fy "$image_file" >/dev/null 2>&1; then
            e2fsck -fy "$image_file" >/dev/null 2>&1
            echo -e "${GREEN}${BOLD}[✓] 'shared_blocks' feature disabled and filesystem repaired successfully.${RESET}\n"
        else
            echo -e "${RED}${BOLD}Error: Failed to unshare blocks. The image may be corrupt.${RESET}"
            exit 1
        fi
    fi
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
  echo -e "${YELLOW}Removing existing extraction directory: ${EXTRACT_DIR}${RESET}\n"
  rm -rf "$EXTRACT_DIR"
fi
mkdir -p "$EXTRACT_DIR"
mkdir -p "$REPACK_INFO"

# Handle special cases like journal recovery and 'shared_blocks' before attempting to mount
handle_journal_recovery "$IMAGE_FILE"
handle_shared_blocks "$IMAGE_FILE"

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

# --- Start of Custom Tweaks ---
# REFINED: Logic to select copy method based on INTERACTIVE_MODE.
if [ "$INTERACTIVE_MODE" = true ] && command -v pv >/dev/null 2>&1; then
    # Interactive mode with pv: Show progress bar.
    (cd "$MOUNT_DIR" && tar --selinux -cf - .) | \
    pv -s "$total_size" -N "Copying" | \
    (cd "$EXTRACT_DIR" && tar --selinux -xf -)
elif [ "$INTERACTIVE_MODE" = true ]; then
    # Interactive mode without pv: Use custom spinner.
    (cd "$MOUNT_DIR" && tar --selinux -cf - .) | \
    (cd "$EXTRACT_DIR" && tar --selinux -xf -) & 
    show_progress $! "$EXTRACT_DIR" "$total_size"
    wait $!
else
    # Non-interactive (quiet) mode: No progress indicators.
    (cd "$MOUNT_DIR" && tar --selinux -cf - .) | (cd "$EXTRACT_DIR" && tar --selinux -xf -)
fi
# --- End of Custom Tweaks ---

# Verify copy succeeded
if [ $? -eq 0 ]; then
    # REFINED: This is now the SINGLE source of the success message, preventing duplication.
    echo -e "${GREEN}[✓] Files copied successfully with SELinux contexts${RESET}"
else
    echo -e "\n${RED}[!] Error occurred during copy${RESET}"
    exit 1
fi

# Store timestamp, filesystem type and metadata location for repacking
echo "UNPACK_TIME=$(date +%s)" > "${REPACK_INFO}/metadata.txt"
echo "SOURCE_IMAGE=$IMAGE_FILE" >> "${REPACK_INFO}/metadata.txt"

SOURCE_FS_TYPE=$(findmnt -n -o FSTYPE --target "$MOUNT_DIR")
echo "FILESYSTEM_TYPE=$SOURCE_FS_TYPE" >> "${REPACK_INFO}/metadata.txt"

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
