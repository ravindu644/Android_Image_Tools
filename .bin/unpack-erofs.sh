
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$SCRIPT_DIR/.tmp"

# Banner function
print_banner() {
  echo -e "${BOLD}${GREEN}"
  echo "┌───────────────────────────────────────────┐"
  echo "│         Unpack EROFS - by @ravindu644     │"
  echo "└───────────────────────────────────────────┘"
  echo -e "${RESET}"
}

# Initialize variables
IMAGE_FILE=""
OUTPUT_DIR_OVERRIDE=""
INTERACTIVE_MODE=true
QUIET=false

# Manual parsing loop
while (( "$#" )); do
  case "$1" in
    --no-banner)
      INTERACTIVE_MODE=false
      shift
      ;;
    --quiet)
      QUIET=true
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

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"
  exit 1
fi

# Save original SELinux status and set to permissive for proper context extraction
ORIGINAL_SELINUX=$(getenforce 2>/dev/null || echo "Disabled")
if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
    setenforce 0
fi

# Check if an image file was provided in the arguments
if [ -z "$IMAGE_FILE" ]; then
  echo -e "${YELLOW}Usage: $0 <image_file> [output_directory]${RESET}"
  echo -e "Example: $0 vendor.img"
  exit 1
fi

PARTITION_NAME=$(basename "$IMAGE_FILE" .img)
if [ -n "$OUTPUT_DIR_OVERRIDE" ]; then
  EXTRACT_DIR="$OUTPUT_DIR_OVERRIDE"
else
  EXTRACT_DIR="extracted_${PARTITION_NAME}"
fi
MOUNT_DIR="$TMP_DIR/${PARTITION_NAME}_mount"
REPACK_INFO="${EXTRACT_DIR}/.repack_info"
RAW_IMAGE=""
FS_CONFIG_FILE="${REPACK_INFO}/fs-config.txt"
FILE_CONTEXTS_FILE="${REPACK_INFO}/file_contexts.txt"

# Check if image file exists
if [ ! -f "$IMAGE_FILE" ]; then
  echo -e "${RED}Error: Image file '$IMAGE_FILE' not found.${RESET}"
  exit 1
fi

# Check if image is empty (0 bytes or all zeros)
if [ "$(stat -c%s "$IMAGE_FILE" 2>/dev/null)" -eq 0 ] || file "$IMAGE_FILE" 2>/dev/null | grep -q "empty"; then
  echo -e "${YELLOW}${BOLD}Warning: Image file '$IMAGE_FILE' is empty (0 bytes).${RESET}"
  echo -e "${YELLOW}Empty partitions cannot be unpacked. Skipping...${RESET}"
  mkdir -p "$EXTRACT_DIR" "$REPACK_INFO"
  {
    echo "UNPACK_TIME=$(date +%s)"
    echo "SOURCE_IMAGE=$IMAGE_FILE"
    echo "FILESYSTEM_TYPE=empty"
    echo "MOUNT_METHOD=none"
    echo "IS_EMPTY_PARTITION=true"
  } > "${REPACK_INFO}/metadata.txt"

  # Strip <none> values from metadata file (replace =<none> with =)
  sed -i 's/=<none>$/=/' "${REPACK_INFO}/metadata.txt"

  [ "$INTERACTIVE_MODE" = true ] && echo -e "${GREEN}${BOLD}[✓] Empty partition marker created.${RESET}"
  exit 0
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

    echo -e "\r\033[K"
}

# Function to clean up mount point and temporary files
cleanup() {
  echo -e "\n${YELLOW}Cleaning up...${RESET}"
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
    echo -e "Unmounting ${MOUNT_DIR}..."

    # Try different unmount methods in order of preference
    if [ "$MOUNT_METHOD" = "fuse" ]; then
      # For FUSE mounts, try fusermount first, then fallback to umount
      fusermount -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR" 2>/dev/null || true
    else
      # For kernel mounts, try umount first, then fallback to fusermount
      umount "$MOUNT_DIR" 2>/dev/null || fusermount -u "$MOUNT_DIR" 2>/dev/null || true
    fi
  fi

  # Remove raw image if it was created
  if [ -n "$RAW_IMAGE" ] && [ -f "$RAW_IMAGE" ]; then
    echo -e "Removing temporary raw image..."
    rm -f "$RAW_IMAGE" 2>/dev/null || true
  fi

  # Remove mount directory and all contents
  if [ -d "$MOUNT_DIR" ]; then
    echo -e "Removing mount directory..."
    # Use a more aggressive approach to handle stubborn files
    if ! rm -rf "$MOUNT_DIR" 2>/dev/null; then
      echo -e "${YELLOW}Warning: Some files in mount directory may still be in use${RESET}"
      # Try to kill any processes using the mount point
      fuser -km "$MOUNT_DIR" 2>/dev/null || true
      # Wait a moment then try again
      sleep 1
      rm -rf "$MOUNT_DIR" 2>/dev/null || true
    fi
  fi

  # Restore original SELinux status
  if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
    setenforce 1 2>/dev/null || true
  fi

  echo -e "${GREEN}Cleanup completed.${RESET}"
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

        # Record that this feature existed before we remove it.
        # We'll create a temporary marker file that the metadata section can check later.
        touch "${REPACK_INFO}/.has_shared_blocks"

        echo -e "${YELLOW}${BOLD}Warning: Incompatible 'shared_blocks' feature detected.${RESET}\n"

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

# Function to get original filesystem parameters (robust and universal)
get_fs_param() {
    # This robustly extracts the value after the colon, trims whitespace,
    # and takes the first "word", which is the actual numerical value or keyword.
    tune2fs -l "$1" 2>/dev/null | grep -E "^$2:" | awk -F':' '{print $2}' | xargs | awk '{print $1}'
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

# Handle special cases like journal recovery and 'shared_blocks' before attempting to mount
handle_journal_recovery "$IMAGE_FILE"
handle_shared_blocks "$IMAGE_FILE"

# Function to detect if an image is sparse
is_sparse_image() {
    # Primary method: Use 'file' command for reliable detection (works with all sparse image versions)
    if file "$1" 2>/dev/null | grep -qi "Android sparse image"; then
        return 0
    fi

    # Fallback method: Check magic header bytes (3aff26ed)
    # Read first 4 bytes and check for sparse image magic header
    local header
    header=$(hexdump -n 4 -e '4/1 "%02x"' "$1" 2>/dev/null)
    [ "$header" == "3aff26ed" ]
}

# Function to prepare image for mounting (handle sparse images)
prepare_image_for_mount() {
    local input="$1"

    if is_sparse_image "$input"; then
        echo -e "${YELLOW}Detected sparse image format${RESET}" >&2
        # Ensure TMP_DIR exists
        mkdir -p "$TMP_DIR"
        RAW_IMAGE="$TMP_DIR/$(basename "$input" .img)_raw.img"
        echo -e "${BLUE}Converting to raw image as ${BOLD}$RAW_IMAGE${RESET}" >&2
        if simg2img "$input" "$RAW_IMAGE"; then
            echo -e "${GREEN}Successfully converted sparse image${RESET}" >&2
            echo "$RAW_IMAGE"
            return 0
        else
            local exit_code=$?
            echo -e "${RED}Failed to convert sparse image (exit code: $exit_code). Check if simg2img is installed.${RESET}" >&2
            return 1
        fi
    fi

    # Not a sparse image, return original
    echo "$input"
    return 0
}

# Function to detect filesystem type
detect_filesystem() {
    local image="$1"
    local fs_type

    # Try blkid first (most reliable)
    fs_type=$(blkid -o value -s TYPE "$image" 2>/dev/null)

    if [ -n "$fs_type" ]; then
        echo "$fs_type"
        return 0
    fi

    # Fallback to file command
    if file "$image" | grep -qi "ext[234]"; then
        echo "ext4"
    elif file "$image" | grep -qi "erofs"; then
        echo "erofs"
    elif file "$image" | grep -qi "f2fs"; then
        echo "f2fs"
    else
        echo "unknown"
    fi
}

# Function to attempt FUSE mounting for supported filesystems
mount_with_fuse() {
    local image="$1"
    local mount_point="$2"
    local fs_type="$3"

    case "$fs_type" in
        ext4|ext3|ext2)
            if command -v fuse2fs >/dev/null; then
                echo -e "${RED}Trying fuse2fs...${RESET}"
                fuse2fs "$image" "$mount_point" >/dev/null 2>&1
                return $?
            else
                echo -e "${RED}${BOLD}[✗] fuse2fs not found. Install e2fsprogs package.${RESET}"
                return 1
            fi
            ;;
        erofs)
            if command -v erofsfuse >/dev/null; then
                echo -e "${RED}Trying erofsfuse...${RESET}"
                erofsfuse "$image" "$mount_point" >/dev/null 2>&1
                return $?
            else
                echo -e "${RED}${BOLD}[✗] erofsfuse not found. Rebuild erofs-utils with FUSE support.${RESET}"
                return 1
            fi
            ;;
        f2fs)
            echo -e "${RED}${BOLD}[✗] F2FS FUSE mounting not available. F2FS requires kernel support.${RESET}"
            echo -e "${YELLOW}Install f2fs-tools package for kernel F2FS support.${RESET}"
            return 1
            ;;
        *)
            echo -e "${RED}${BOLD}[✗] Unsupported filesystem for FUSE mounting: $fs_type${RESET}"
            return 1
            ;;
    esac
}

# Function to get the actual filesystem type, stripping FUSE prefixes
get_actual_fs_type() {
    local mount_point="$1"
    local detected_type="$2"

    # Get filesystem type from findmnt
    local mount_fs_type=$(findmnt -n -o FSTYPE --target "$mount_point" 2>/dev/null)

    # If it's a FUSE mount, extract the actual filesystem type
    if [[ "$mount_fs_type" =~ ^fuse\. ]]; then
        # For FUSE mounts like fuse.fuse2fs, fuse.erofsfuse, return the detected type
        echo "$detected_type"
    else
        # For kernel mounts, return the mount type
        echo "$mount_fs_type"
    fi
}

echo -e "Attempting to mount: ${BOLD}$IMAGE_FILE${RESET}\n"

# First, prepare the image (handle sparse conversion)
MOUNT_IMAGE=$(prepare_image_for_mount "$IMAGE_FILE")
if [ $? -ne 0 ]; then
    echo -e "${RED}${BOLD}Error: Failed to prepare image for mounting${RESET}"
    exit 1
fi

# Detect filesystem type
FS_TYPE=$(detect_filesystem "$MOUNT_IMAGE")
echo -e "${BLUE}Detected filesystem: ${BOLD}$FS_TYPE${RESET}"

# Initialize mount success flag
MOUNT_SUCCESS=false
MOUNT_METHOD=""

# Try traditional mount first
echo -e "${BLUE}Trying kernel mount...${RESET}"
if mount -o loop,seclabel "$MOUNT_IMAGE" "$MOUNT_DIR" 2>/dev/null; then
    echo -e "${GREEN}${BOLD}[✓] Successfully mounted using kernel driver${RESET}"
    MOUNT_SUCCESS=true
    MOUNT_METHOD="kernel"
else
    echo -e "\n${RED}${BOLD}[!] Traditional mount failed${RESET}"
    echo -e "${RED}Attempting FUSE mount...${RESET}"

    if mount_with_fuse "$MOUNT_IMAGE" "$MOUNT_DIR" "$FS_TYPE"; then
        echo -e "\n${GREEN}${BOLD}[✓] Successfully mounted using FUSE${RESET}"
        MOUNT_SUCCESS=true
        MOUNT_METHOD="fuse"

        # Warn about SELinux context issues on FUSE mounts
        if command -v getenforce >/dev/null 2>&1; then
            selinux_status=$(getenforce 2>/dev/null)
            if [ "$selinux_status" = "Enforcing" ] || [ "$selinux_status" = "Permissive" ]; then
                echo -e "\n${RED}${BOLD}WARNING: FUSE mount detected on SELinux-enabled system.${RESET}"
                echo -e "${RED}FUSE filesystems have limited SELinux context support.${RESET}"
                echo -e "${RED}Extracted SELinux contexts may be incorrect or 'unlabeled_t'.${RESET}"
                echo -e "${RED}Restoring bad contexts can cause bootloops or permission issues.${RESET}"
                echo -e "${RED}Consider using kernel mounts for better context preservation.${RESET}"
                echo -e "${RED}Proceed with caution!${RESET}\n"
            fi
        fi
    else
        echo -e "${RED}${BOLD}[✗] All mount attempts failed. Unable to proceed.${RESET}"
        exit 1
    fi
fi

# Verify mount succeeded
if [ "$MOUNT_SUCCESS" = false ]; then
    echo -e "${RED}${BOLD}[✗] Failed to mount the image${RESET}"
    exit 1
fi

echo ""

# First get root directory context specifically
echo -e "${BLUE}Capturing root directory attributes...${RESET}"
ROOT_CONTEXT=$(getfattr -m - -d "$MOUNT_DIR" 2>/dev/null | grep '^security\.selinux=' | cut -d'"' -f2 || echo "")
ROOT_STATS=$(stat -c "%u %g %a" "$MOUNT_DIR")

# Create config files with root attributes first
echo "# FS config extracted from $IMAGE_FILE on $(date)" > "$FS_CONFIG_FILE"
echo "/ $ROOT_STATS" >> "$FS_CONFIG_FILE"

echo "# File contexts extracted from $IMAGE_FILE on $(date)" > "$FILE_CONTEXTS_FILE"
echo "/ $ROOT_CONTEXT" >> "$FILE_CONTEXTS_FILE"

# Extract metadata with progress
echo -e "${BLUE}Extracting file attributes...${RESET}"
total_items=$(find "$MOUNT_DIR" -mindepth 1 | wc -l)
processed=0
spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
spin=0

# Create a special file for symlink info
SYMLINK_INFO="${REPACK_INFO}/symlink_info.txt"
echo "# Symlink info extracted from $IMAGE_FILE on $(date)" > "$SYMLINK_INFO"

# Use find -print0 and a while-read loop for robust handling of all filenames.
# This prevents errors with filenames containing spaces, newlines, or other special characters.
find "$MOUNT_DIR" -mindepth 1 -print0 | while IFS= read -r -d $'\0' item; do
    processed=$((processed + 1))
    # Avoid division by zero if total_items is 0
    percentage=$((total_items > 0 ? processed * 100 / total_items : 0))

    # Update spinner progress indicator
    if [ $((processed % 50)) -eq 0 ] && [ "$QUIET" = false ]; then
        echo -ne "\r${BLUE}[${spinner[$((spin++ % 10))]}] Processing: ${percentage}% (${processed}/${total_items})${RESET}"
    fi

    rel_path=${item#$MOUNT_DIR}

    # Special handling for symlinks
    if [ -L "$item" ]; then
        # '|| true' prevents 'set -e' from exiting on broken symlinks or permission errors.
        target=$(readlink "$item" || true)
        stats=$(stat -c "%u %g %a" "$item" 2>/dev/null || true)
        # Using getfattr for SELinux context extraction with robust parsing.
        # Try multiple approaches to get symlink context
        context=""

        # Method 1: Try getfattr -h (recommended for symlinks)
        if context_output=$(getfattr -h -n security.selinux "$item" 2>/dev/null); then
            context=$(echo "$context_output" | grep '^# file: ' -A1 | tail -n1 | sed 's/^security\.selinux=//' | tr -d '"')
        fi

        # Method 2: Fallback to getfattr -d if method 1 failed
        if [ -z "$context" ] && context_output=$(getfattr -d -n security.selinux "$item" 2>/dev/null); then
            context=$(echo "$context_output" | grep '^# file: ' -A1 | tail -n1 | sed 's/^security\.selinux=//' | tr -d '"')
        fi

        # Method 3: Last resort - try getfattr with -m pattern matching
        if [ -z "$context" ]; then
            context=$(getfattr -m - -h "$item" 2>/dev/null | grep '^security\.selinux=' | head -n1 | cut -d'"' -f2 || echo "")
        fi

        # Clean up the context (remove any remaining quotes or spaces)
        context=$(echo "$context" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Only write to the info file if target and stats were retrieved.
        if [ -n "$target" ] && [ -n "$stats" ]; then
            echo "$rel_path $target $stats $context" >> "$SYMLINK_INFO"
        fi
    else
        # Handle regular files and directories.
        stats=$(stat -c "%u %g %a" "$item" 2>/dev/null || true)
        # Using getfattr for SELinux context extraction with robust parsing.
        context=""

        # Method 1: Try getfattr -n security.selinux (direct attribute access)
        if context_output=$(getfattr -n security.selinux "$item" 2>/dev/null); then
            context=$(echo "$context_output" | grep '^# file: ' -A1 | tail -n1 | sed 's/^security\.selinux=//' | tr -d '"')
        fi

        # Method 2: Fallback to getfattr -d if method 1 failed
        if [ -z "$context" ] && context_output=$(getfattr -d -n security.selinux "$item" 2>/dev/null); then
            context=$(echo "$context_output" | grep '^# file: ' -A1 | tail -n1 | sed 's/^security\.selinux=//' | tr -d '"')
        fi

        # Method 3: Last resort - try getfattr with -m pattern matching
        if [ -z "$context" ]; then
            context=$(getfattr -m - "$item" 2>/dev/null | grep '^security\.selinux=' | head -n1 | cut -d'"' -f2 || echo "")
        fi

        # Clean up the context (remove any remaining quotes or spaces)
        context=$(echo "$context" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

        # Write attributes to their respective config files if valid.
        [ -n "$stats" ] && echo "$rel_path $stats" >> "$FS_CONFIG_FILE"
        [ -n "$context" ] && [ "$context" != "?" ] && echo "$rel_path $context" >> "$FILE_CONTEXTS_FILE"
    fi
done
# Clear the progress line and print the completion message.
echo -e "\r\033[K${GREEN}[✓] Attributes extracted successfully${RESET}"

echo ""

# Calculate checksums with spinner
echo -e "${BLUE}Calculating original file checksums...${RESET}"
(cd "$MOUNT_DIR" && find . -type f -exec sha256sum {} \;) > "${REPACK_INFO}/original_checksums.txt" &
spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
spin=0
while [ "$QUIET" = false ] && kill -0 $! 2>/dev/null; do
    # Clear entire line first
    echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Generating checksums${RESET}"
    sleep 0.1
done

# Clear line and show completion
echo -e "\r\033[K${GREEN}[✓] Checksums generated${RESET}"

echo ""

# Copy files with SELinux contexts preserved
echo -e "${BLUE}Copying files with preserved attributes...${RESET}"
echo -e "${BLUE}┌─ Source: ${MOUNT_DIR}${RESET}"
echo -e "${BLUE}└─ Target: ${EXTRACT_DIR}${RESET}"

# Calculate total size for progress
total_size=$(du -sb "$MOUNT_DIR" | cut -f1)

if [ "$INTERACTIVE_MODE" = true ] && command -v pv >/dev/null 2>&1; then
    # Interactive mode with pv: Show progress bar.
    (cd "$MOUNT_DIR" && tar -cf - .) | \
    pv -s "$total_size" -N "Copying" | \
    (cd "$EXTRACT_DIR" && tar -xf -)
elif [ "$INTERACTIVE_MODE" = true ]; then
    # Interactive mode without pv: Use custom spinner.
    (cd "$MOUNT_DIR" && tar -cf - .) | \
    (cd "$EXTRACT_DIR" && tar -xf -) &
    show_progress $! "$EXTRACT_DIR" "$total_size"
    wait $!
else
    # Non-interactive (quiet) mode: No progress indicators.
    (cd "$MOUNT_DIR" && tar -cf - .) | (cd "$EXTRACT_DIR" && tar -xf -)
fi

# Verify copy succeeded
if [ $? -eq 0 ]; then
    echo -e "${GREEN}[✓] Files copied successfully with SELinux contexts${RESET}"
else
    echo -e "\n${RED}[!] Error occurred during copy${RESET}"
    exit 1
fi

echo ""

# Store timestamp, filesystem type and metadata location for repacking
echo -e "${BLUE}Storing extraction metadata...${RESET}"
echo "UNPACK_TIME=$(date +%s)" > "${REPACK_INFO}/metadata.txt"
echo "SOURCE_IMAGE=$IMAGE_FILE" >> "${REPACK_INFO}/metadata.txt"

# Get the actual filesystem type (without FUSE prefix)
SOURCE_FS_TYPE=$(get_actual_fs_type "$MOUNT_DIR" "$FS_TYPE")
echo "FILESYSTEM_TYPE=$SOURCE_FS_TYPE" >> "${REPACK_INFO}/metadata.txt"
echo "MOUNT_METHOD=$MOUNT_METHOD" >> "${REPACK_INFO}/metadata.txt"

# Proactively save filesystem metadata for super image workflow
if [ "$SOURCE_FS_TYPE" == "ext4" ]; then

    # Check for the marker file we created in handle_shared_blocks().
    if [ -f "${REPACK_INFO}/.has_shared_blocks" ]; then
        echo "ORIGINAL_HAS_SHARED_BLOCKS=true" >> "${REPACK_INFO}/metadata.txt"
        rm -f "${REPACK_INFO}/.has_shared_blocks" # Clean up the marker
    fi

    mounted_image=$(findmnt -n -o SOURCE --target "$MOUNT_DIR")

    BLOCK_COUNT=$(get_fs_param "$mounted_image" "Block count")
    echo "ORIGINAL_BLOCK_COUNT=$BLOCK_COUNT" >> "${REPACK_INFO}/metadata.txt"
    echo "ORIGINAL_BLOCK_SIZE=$(get_fs_param "$mounted_image" "Block size")" >> "${REPACK_INFO}/metadata.txt"
    echo "ORIGINAL_INODE_COUNT=$(get_fs_param "$mounted_image" "Inode count")" >> "${REPACK_INFO}/metadata.txt"
    echo "ORIGINAL_UUID=$(get_fs_param "$mounted_image" "Filesystem UUID")" >> "${REPACK_INFO}/metadata.txt"
    echo "ORIGINAL_VOLUME_NAME=$(get_fs_param "$mounted_image" "Filesystem volume name")" >> "${REPACK_INFO}/metadata.txt"
    echo "ORIGINAL_INODE_SIZE=$(get_fs_param "$mounted_image" "Inode size")" >> "${REPACK_INFO}/metadata.txt"
    FEATURES=$(tune2fs -l "$mounted_image" 2>/dev/null | grep "Filesystem features:" | awk -F':' '{print $2}' | xargs | sed 's/ /,/g')
    echo "ORIGINAL_FEATURES=$FEATURES" >> "${REPACK_INFO}/metadata.txt"

    RESERVED_BLOCKS_COUNT=$(get_fs_param "$mounted_image" "Reserved block count")
    # Round up to the nearest integer percentage ( using the (a+b-1)/b formula to round up a/b in truncating arithmetic )
    RESERVED_BLOCKS_PERCENTAGE=$(awk -v r="$RESERVED_BLOCKS_COUNT" -v b="$BLOCK_COUNT" 'BEGIN { printf("%d", (100*r + b - 1) / b) }')
    echo "ORIGINAL_RESERVED_BLOCKS_PERCENTAGE=$RESERVED_BLOCKS_PERCENTAGE" >> "${REPACK_INFO}/metadata.txt"

    # Strip <none> values from metadata file (replace =<none> with =)
    sed -i 's/=<none>$/=/' "${REPACK_INFO}/metadata.txt"

elif [ "$SOURCE_FS_TYPE" == "erofs" ]; then
    # Extract EROFS metadata from file command output
    file_output=$(file "$IMAGE_FILE" 2>/dev/null)

    # Extract volume label and UUID using awk
    echo "$file_output" | awk -F'[, ]' '{
        for (i=1; i<=NF; i++) {
            if ($i ~ /^name=/) {
                gsub(/^name=/, "", $i)
                if ($i != "") print "ORIGINAL_VOLUME_NAME=" $i
            }
            if ($i ~ /^uuid=/) {
                gsub(/^uuid=/, "", $i)
                gsub(/-/, "", $i)
                $i = tolower($i)
                if (length($i) == 32) {
                    printf "ORIGINAL_UUID=%s-%s-%s-%s-%s\n",
                        substr($i,1,8), substr($i,9,4), substr($i,13,4),
                        substr($i,17,4), substr($i,21,12)
                }
            }
        }
    }' >> "${REPACK_INFO}/metadata.txt"

    # Strip <none> values from metadata file (replace =<none> with =)
    sed -i 's/=<none>$/=/' "${REPACK_INFO}/metadata.txt"
fi

echo ""

# Verify extraction
if [ $? -eq 0 ]; then
    echo -e "${GREEN}${BOLD}[✓] Extraction completed successfully${RESET}\n"
    echo -e "${BOLD}Files extracted to: $EXTRACT_DIR${RESET}"
    echo -e "${BOLD}Repack info stored in: $REPACK_INFO${RESET}"
    echo -e "${BOLD}File contexts saved to: $FILE_CONTEXTS_FILE${RESET}"
    echo -e "${BOLD}FS config saved to: $FS_CONFIG_FILE${RESET}"

  # Transfer ownership to actual user
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$EXTRACT_DIR" || true
  fi
else
  echo -e "${RED}${BOLD}[✗] Error occurred during extraction${RESET}"
  cleanup
  exit 1
fi

# Script completion
if [ "$INTERACTIVE_MODE" = true ]; then
    echo -e "\n${GREEN}${BOLD}Done!${RESET}"
fi
