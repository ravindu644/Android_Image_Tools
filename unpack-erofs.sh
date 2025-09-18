#!/bin/bash
# EROFS Image Unpacker Script with File Attribute Preservation

# --- Argument Parsing ---
IMAGE_FILE="$1"
EXTRACT_DIR="$2"
NO_BANNER=false
if [[ "$3" == "--no-banner" ]]; then
    NO_BANNER=true
fi

set -e

# --- Script Body ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"

print_banner() {
  if [ "$NO_BANNER" = false ]; then
    echo -e "${BOLD}${GREEN}"
    echo "┌───────────────────────────────────────────┐"
    echo "│         Unpack EROFS - by @ravindu644     │"
    echo "└───────────────────────────────────────────┘"
    echo -e "${RESET}"
  fi
}

print_banner

if [ "$EUID" -ne 0 ]; then echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"; exit 1; fi
if [ -z "$IMAGE_FILE" ]; then echo -e "${YELLOW}Usage: $0 <image_file> [output_directory]${RESET}"; exit 1; fi

PARTITION_NAME=$(basename "$IMAGE_FILE" .img)
MOUNT_DIR="/tmp/${PARTITION_NAME}_mount"
[ -z "$EXTRACT_DIR" ] && EXTRACT_DIR="extracted_${PARTITION_NAME}"
REPACK_INFO="${EXTRACT_DIR}/.repack_info"
RAW_IMAGE=""
FS_CONFIG_FILE="${REPACK_INFO}/fs-config.txt"
FILE_CONTEXTS_FILE="${REPACK_INFO}/file_contexts.txt"

if [ ! -f "$IMAGE_FILE" ]; then echo -e "${RED}Error: Image file '$IMAGE_FILE' not found.${RESET}"; exit 1; fi

show_progress() {
    local pid=$1; local target=$2; local total=$3; local spin=0; local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    while kill -0 $pid 2>/dev/null; do
        current_size=$(du -sb "$target" | cut -f1); percentage=$((current_size * 100 / total))
        current_hr=$(numfmt --to=iec-i --suffix=B "$current_size"); total_hr=$(numfmt --to=iec-i --suffix=B "$total")
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Copying: ${percentage}% (${current_hr}/${total_hr})${RESET}"; sleep 0.1
    done
    echo -e "\r\033[K${GREEN}[✓] Files copied successfully with SELinux contexts${RESET}"
}

cleanup() {
  if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then umount "$MOUNT_DIR" 2>/dev/null || true; fi
  if [ -n "$RAW_IMAGE" ] && [ -f "$RAW_IMAGE" ]; then rm -f "$RAW_IMAGE" 2>/dev/null || true; fi
  if [ -d "$MOUNT_DIR" ]; then rm -rf "$MOUNT_DIR" 2>/dev/null || true; fi
}

handle_journal_recovery() {
    local image_file="$1"
    if file "$image_file" 2>/dev/null | grep -q "needs journal recovery"; then
        echo -e "${YELLOW}Warning: Filesystem needs journal recovery.${RESET}"
        if ! e2fsck -fy "$image_file" >/dev/null 2>&1 && [ $? -gt 2 ]; then
            echo -e "${RED}Error: Failed to replay journal (e2fsck exit code: $?).${RESET}"; exit 1
        fi
        echo -e "${GREEN}[✓] Journal replayed successfully.${RESET}"
    fi
}

handle_shared_blocks() {
    local image_file="$1"
    if tune2fs -l "$image_file" 2>/dev/null | grep -q "shared_blocks"; then
        echo -e "\n${YELLOW}Warning: Incompatible 'shared_blocks' feature detected.${RESET}"
        if e2fsck -E unshare_blocks -fy "$image_file" >/dev/null 2>&1; then
            e2fsck -fy "$image_file" >/dev/null 2>&1
            echo -e "${GREEN}[✓] 'shared_blocks' feature disabled successfully.${RESET}"
        else echo -e "${RED}Error: Failed to unshare blocks.${RESET}"; exit 1; fi
    fi
}

trap cleanup EXIT INT TERM

[ -d "$MOUNT_DIR" ] && rm -rf "$MOUNT_DIR"; mkdir -p "$MOUNT_DIR"
[ -d "$EXTRACT_DIR" ] && { echo -e "${YELLOW}Removing existing extraction directory: ${EXTRACT_DIR}${RESET}\n"; rm -rf "$EXTRACT_DIR"; }
mkdir -p "$EXTRACT_DIR"; mkdir -p "$REPACK_INFO"

handle_journal_recovery "$IMAGE_FILE"; handle_shared_blocks "$IMAGE_FILE"

echo -e "Attempting to mount ${BOLD}$IMAGE_FILE${RESET}..."
if ! (mount -o loop "$IMAGE_FILE" "$MOUNT_DIR" 2>/dev/null && mount -o remount,ro "$MOUNT_DIR" 2>/dev/null); then
  echo -e "${YELLOW}Direct mounting failed. Trying to convert image...${RESET}"
  IMAGE_TYPE=$(file "$IMAGE_FILE" | grep -o -E 'Android.*|Linux.*|EROFS.*|data')
  if [ -n "$IMAGE_TYPE" ]; then
    echo -e "${BLUE}Detected image type: ${BOLD}$IMAGE_TYPE${RESET}"
    RAW_IMAGE="/tmp/${PARTITION_NAME}_raw.img"
    if command -v simg2img &> /dev/null; then simg2img "$IMAGE_FILE" "$RAW_IMAGE"; else cp "$IMAGE_FILE" "$RAW_IMAGE"; fi
    if ! (mount -o loop "$RAW_IMAGE" "$MOUNT_DIR" 2>/dev/null && mount -o remount,ro "$MOUNT_DIR" 2>/dev/null); then
      echo -e "${RED}Failed to mount converted image.${RESET}"; exit 1
    fi; echo -e "${GREEN}Successfully mounted raw image.${RESET}"
  else echo -e "${RED}Failed to identify image type.${RESET}"; exit 1; fi
else echo -e "${GREEN}Successfully mounted original image.${RESET}"; fi

echo -e "\n${BLUE}Capturing root directory attributes...${RESET}"
ROOT_CONTEXT=$(ls -dZ "$MOUNT_DIR" | awk '{print $1}'); ROOT_STATS=$(stat -c "%u %g %a" "$MOUNT_DIR")
echo "# FS config extracted from $IMAGE_FILE on $(date)" > "$FS_CONFIG_FILE"; echo "/ $ROOT_STATS" >> "$FS_CONFIG_FILE"
echo "# File contexts extracted from $IMAGE_FILE on $(date)" > "$FILE_CONTEXTS_FILE"; echo "/ $ROOT_CONTEXT" >> "$FILE_CONTEXTS_FILE"

echo -e "\n${BLUE}Extracting file attributes...${RESET}"
total_items=$(find "$MOUNT_DIR" -mindepth 1 | wc -l); processed=0; spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' ); spin=0
SYMLINK_INFO="${REPACK_INFO}/symlink_info.txt"; echo "# Symlink info extracted from $IMAGE_FILE on $(date)" > "$SYMLINK_INFO"
find "$MOUNT_DIR" -mindepth 1 | while read -r item; do
    processed=$((processed + 1)); percentage=$((processed * 100 / total_items))
    if [ $((processed % 50)) -eq 0 ]; then echo -ne "\r${BLUE}[${spinner[$((spin++ % 10))]}] Processing: ${percentage}%${RESET}"; fi
    rel_path=${item#$MOUNT_DIR}
    if [ -L "$item" ]; then
        target=$(readlink "$item"); stats=$(stat -c "%u g %a" "$item" 2>/dev/null); context=$(ls -dZ "$item" 2>/dev/null | awk '{print $1}')
        echo "$rel_path $target $stats $context" >> "$SYMLINK_INFO"
    else
        stats=$(stat -c "%u g %a" "$item" 2>/dev/null); context=$(ls -dZ "$item" 2>/dev/null | awk '{print $1}')
        [ -n "$stats" ] && echo "$rel_path $stats" >> "$FS_CONFIG_FILE"
        [ -n "$context" ] && [ "$context" != "?" ] && echo "$rel_path $context" >> "$FILE_CONTEXTS_FILE"
    fi
done
echo -e "\r${GREEN}[✓] Attributes extracted successfully${RESET}\n"

echo -e "${BLUE}Calculating original file checksums...${RESET}"
(cd "$MOUNT_DIR" && find . -type f -exec sha256sum {} \;) > "${REPACK_INFO}/original_checksums.txt" &
spin=0; while kill -0 $! 2>/dev/null; do echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Generating checksums${RESET}"; sleep 0.1; done
echo -e "\r\033[K${GREEN}[✓] Checksums generated${RESET}\n"

echo -e "${BLUE}Copying files with preserved attributes...${RESET}"
echo -e "┌─ Source: ${MOUNT_DIR}"
echo -e "└─ Target: ${EXTRACT_DIR}\n"
total_size=$(du -sb "$MOUNT_DIR" | cut -f1)

# FIX: Removed the pv logic completely for a consistent UI. Always use show_progress.
(cd "$MOUNT_DIR" && tar --selinux -cf - .) | (cd "$EXTRACT_DIR" && tar --selinux -xf -) &
show_progress $! "$EXTRACT_DIR" "$total_size"
wait $!

if [ $? -ne 0 ]; then
    echo -e "\n${RED}[!] Error occurred during copy${RESET}"; exit 1
fi

echo "UNPACK_TIME=$(date +%s)" > "${REPACK_INFO}/metadata.txt"
echo "SOURCE_IMAGE=$(realpath "$IMAGE_FILE")" >> "${REPACK_INFO}/metadata.txt"
SOURCE_FS_TYPE=$(findmnt -n -o FSTYPE --target "$MOUNT_DIR")
echo "FILESYSTEM_TYPE=$SOURCE_FS_TYPE" >> "${REPACK_INFO}/metadata.txt"

echo -e "\n${GREEN}Extraction completed successfully.${RESET}"
echo -e "${BOLD}Files extracted to: ${EXTRACT_DIR}${RESET}"
echo -e "${BOLD}Repack info stored in: ${REPACK_INFO}${RESET}"

if [ -n "$SUDO_USER" ]; then chown -R "$SUDO_USER:$SUDO_USER" "$EXTRACT_DIR"; fi
if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then umount "$MOUNT_DIR"; echo -e "\n${GREEN}Image unmounted successfully.${RESET}"; fi

echo
