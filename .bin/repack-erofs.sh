#!/bin/bash
# EROFS Image Repacker Script with Enhanced Attribute Restoration

# --- Argument Parsing ---
# This script can be run standalone or called by a wrapper.
# Standalone: ./repack-erofs.sh <extracted_folder_path>
# Wrapper:    ./repack-erofs.sh <dir> <out.img> --fs <type> [options] --no-banner

EXTRACT_DIR="$1"
OUTPUT_IMG="$2" # Can be a flag or positional

# Default values
FS_CHOICE=""
EXT4_MODE=""
EROFS_COMP=""
EROFS_LEVEL=""
NO_BANNER=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --fs) FS_CHOICE="$2"; shift; shift ;;
        --ext4-mode) EXT4_MODE="$2"; shift; shift ;;
        --erofs-compression) EROFS_COMP="$2"; shift; shift ;;
        --erofs-level) EROFS_LEVEL="$2"; shift; shift ;;
        --no-banner) NO_BANNER=true; shift ;;
        *) shift ;;
    esac
done

set -e

# --- Script Body ---
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"

print_banner() {
  if [ "$NO_BANNER" = false ]; then
    echo -e "${BOLD}${GREEN}"
    echo "┌───────────────────────────────────────────┐"
    echo "│         Repack EROFS - by @ravindu644     │"
    echo "└──────────────────────────────────────────┘"
    echo -e "${RESET}"
  fi
}

print_banner

if [ "$EUID" -ne 0 ]; then echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"; exit 1; fi
if ! command -v mkfs.erofs &> /dev/null; then echo -e "${RED}mkfs.erofs not found. Please install erofs-utils.${RESET}"; exit 1; fi

if [ -z "$EXTRACT_DIR" ]; then
    echo -e "${YELLOW}Usage: $0 <extracted_folder_path> [output_image.img] [options]${RESET}"; exit 1
fi

# If output image is a flag, it will be caught by the parser. If it's positional, it's $2.
# We reset it here if it's not a valid path.
if [[ "$OUTPUT_IMG" == --* || -z "$OUTPUT_IMG" ]]; then
    OUTPUT_IMG=""
fi

REPACK_INFO="${EXTRACT_DIR}/.repack_info"
PARTITION_NAME=$(basename "$EXTRACT_DIR" | sed 's/^extracted_//')
[ -z "$OUTPUT_IMG" ] && OUTPUT_IMG="${PARTITION_NAME}_repacked.img"
FS_CONFIG_FILE="${REPACK_INFO}/fs-config.txt"
FILE_CONTEXTS_FILE="${REPACK_INFO}/file_contexts.txt"

TEMP_ROOT="/tmp/repack-$(basename "$EXTRACT_DIR")"
WORK_DIR="${TEMP_ROOT}/${PARTITION_NAME}_work"
MOUNT_POINT="" # To be defined later

cleanup() {
    if [ "$NO_BANNER" = false ]; then echo -e "\n${YELLOW}Cleaning up temporary files...${RESET}"; fi
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sync
        umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null
    fi
    [ -d "$TEMP_ROOT" ] && rm -rf "$TEMP_ROOT"
    [ -f "${OUTPUT_IMG}.tmp" ] && rm -f "${OUTPUT_IMG}.tmp"
    if [ "$NO_BANNER" = false ]; then echo -e "${GREEN}Cleanup completed.${RESET}"; fi
}

trap 'cleanup; exit 1' INT TERM EXIT

if [ ! -d "$REPACK_INFO" ]; then echo -e "${RED}Error: Repack info not found at ${REPACK_INFO}${RESET}"; exit 1; fi
EXTRACT_DIR=${EXTRACT_DIR%/}
if [ ! -d "$EXTRACT_DIR" ]; then echo -e "${RED}Error: Directory '$EXTRACT_DIR' not found.${RESET}"; exit 1; fi

find_matching_pattern() {
    local path="$1"; local config_file="$2"; local pattern=""
    if [ "$path" = "/" ]; then echo "$(grep -E '^/ ' "$config_file" | head -n1)"; return; fi
    local parent_dir=$(dirname "$path")
    while true; do
        pattern=$(grep -E "^${parent_dir} " "$config_file" | head -n1)
        if [ -n "$pattern" ]; then echo "$pattern"; return; fi
        if [ "$parent_dir" = "/" ]; then break; fi
        parent_dir=$(dirname "$parent_dir")
    done
    echo "$(grep -E '^/ ' "$config_file" | head -n1)"
}

restore_attributes() {
    echo -e "\n${BLUE}Initializing permission restoration...${RESET}"
    echo -e "${BLUE}┌─ Analyzing filesystem structure...${RESET}"
    if [ -f "${REPACK_INFO}/symlink_info.txt" ]; then
        while IFS=' ' read -r path target uid gid mode context || [ -n "$path" ]; do
            [[ "$path" =~ ^#.*$ || -z "$path" ]] && continue
            full_path="$1$path"; [ ! -L "$full_path" ] && ln -sf "$target" "$full_path"
            chown -h "$uid:$gid" "$full_path" 2>/dev/null || true
            [ -n "$context" ] && chcon -h "$context" "$full_path" 2>/dev/null || true
        done < "${REPACK_INFO}/symlink_info.txt"
    fi
    DIR_COUNT=$(find "$1" -type d | wc -l); FILE_COUNT=$(find "$1" -type f | wc -l)
    echo -e "${BLUE}├─ Found ${BOLD}$DIR_COUNT${RESET}${BLUE} directories${RESET}"
    echo -e "${BLUE}└─ Found ${BOLD}$FILE_COUNT${RESET}${BLUE} files${RESET}\n"
    echo -e "${BLUE}Processing directory structure...${RESET}"
    processed=0; spin=0; spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    find "$1" -type d | while read -r item; do
        processed=$((processed + 1)); percentage=$((processed * 100 / DIR_COUNT)); rel_path=${item#$1}; [ -z "$rel_path" ] && rel_path="/"
        stored_attrs=$(grep -E "^${rel_path} " "$FS_CONFIG_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        stored_context=$(grep -E "^${rel_path} " "$FILE_CONTEXTS_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        if [ -z "$stored_attrs" ]; then
            pattern=$(find_matching_pattern "$rel_path" "$FS_CONFIG_FILE"); uid=$(echo "$pattern" | awk '{print $2}'); gid=$(echo "$pattern" | awk '{print $3}'); mode=$(echo "$pattern" | awk '{print $4}')
            chown "${uid:-0}:${gid:-0}" "$item" 2>/dev/null || true; chmod "${mode:-755}" "$item" 2>/dev/null || true
            context_pattern=$(find_matching_pattern "$rel_path" "$FILE_CONTEXTS_FILE"); context=$(echo "$context_pattern" | awk '{$1=""; print $0}' | sed 's/^ //')
            [ -n "$context" ] && chcon "$context" "$item" 2>/dev/null || true
        else
            uid=$(echo "$stored_attrs" | awk '{print $1}'); gid=$(echo "$stored_attrs" | awk '{print $2}'); mode=$(echo "$stored_attrs" | awk '{print $3}')
            chown "$uid:$gid" "$item" 2>/dev/null || true; chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        fi
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Mapping contexts: ${percentage}% (${processed}/${DIR_COUNT})${RESET}"
    done
    echo -e "\r\033[K${GREEN}[✓] Directory attributes mapped${RESET}\n"
    echo -e "${BLUE}Processing file permissions...${RESET}"; processed=0; spin=0
    find "$1" -type f | while read -r item; do
        processed=$((processed + 1)); percentage=$((processed * 100 / FILE_COUNT)); rel_path=${item#$1}
        stored_attrs=$(grep -E "^${rel_path} " "$FS_CONFIG_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        stored_context=$(grep -E "^${rel_path} " "$FILE_CONTEXTS_FILE" | head -n1 | awk '{$1=""; print $0}' | sed 's/^ //')
        if [ -z "$stored_attrs" ]; then
            pattern=$(find_matching_pattern "$rel_path" "$FS_CONFIG_FILE"); uid=$(echo "$pattern" | awk '{print $2}'); gid=$(echo "$pattern" | awk '{print $3}')
            chown "${uid:-0}:${gid:-0}" "$item" 2>/dev/null || true; chmod 644 "$item" 2>/dev/null || true
            context_pattern=$(find_matching_pattern "$rel_path" "$FILE_CONTEXTS_FILE"); context=$(echo "$context_pattern" | awk '{$1=""; print $0}' | sed 's/^ //')
            [ -n "$context" ] && chcon "$context" "$item" 2>/dev/null || true
        else
            uid=$(echo "$stored_attrs" | awk '{print $1}'); gid=$(echo "$stored_attrs" | awk '{print $2}'); mode=$(echo "$stored_attrs" | awk '{print $3}')
            chown "$uid:$gid" "$item" 2>/dev/null || true; chmod "$mode" "$item" 2>/dev/null || true
            [ -n "$stored_context" ] && chcon "$stored_context" "$item" 2>/dev/null || true
        fi
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Restoring contexts: ${percentage}% (${processed}/${FILE_COUNT})${RESET}"
    done
    echo -e "\r\033[K${GREEN}[✓] File attributes restored${RESET}\n"
}

verify_modifications() {
    local src="$1"; echo -e "\n${BLUE}Verifying modified files...${RESET}"
    local curr_sums="/tmp/current_checksums_$(basename "$src").txt"
    (cd "$src" && find . -type f -not -path "./.repack_info/*" -exec sha256sum {} \;) > "$curr_sums"
    echo -e "${BLUE}Analyzing changes...${RESET}"
    local modified_files=0; local total_files=0; local spin=0; local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    while IFS= read -r line; do
        total_files=$((total_files + 1)); checksum=$(echo "$line" | cut -d' ' -f1); file=$(echo "$line" | cut -d' ' -f3-)
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Analyzing files...${RESET}"
        if ! grep -q "$checksum.*$file" "${REPACK_INFO}/original_checksums.txt" 2>/dev/null; then
            modified_files=$((modified_files + 1)); echo -e "\r\033[K${YELLOW}Modified: $file${RESET}"
        fi
    done < "$curr_sums"
    echo -e "\r\033[K${BLUE}Found ${YELLOW}$modified_files${BLUE} modified files out of $total_files total files${RESET}"; rm -f "$curr_sums"
}

show_copy_progress() {
    local pid=$!
    local src="$1"; local dst="$2"; local total_size;
    total_size=$(du -sb --exclude=.repack_info "$src" | cut -f1)
    local spin=0; spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    while kill -0 $pid 2>/dev/null; do
        current_size=$(du -sb "$dst" | cut -f1); percentage=$((current_size * 100 / total_size))
        current_hr=$(numfmt --to=iec-i --suffix=B "$current_size"); total_hr=$(numfmt --to=iec-i --suffix=B "$total_size")
        echo -ne "\r\033[K${BLUE}[${spinner[$((spin++ % 10))]}] Copying to temp dir: ${percentage}% (${current_hr}/${total_hr})${RESET}"; sleep 0.1
    done
    echo -e "\r\033[K${GREEN}[✓] Files copied to temp dir${RESET}"
}

remove_repack_info() { rm -rf "${1}/.repack_info" 2>/dev/null; }

prepare_working_directory() {
    echo -e "\n${BLUE}Preparing working directory...${RESET}"; mkdir -p "$TEMP_ROOT"; [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"
    echo -e "${BLUE}Copying files to work directory...${RESET}"
    (cd "$EXTRACT_DIR" && tar --selinux --exclude=.repack_info -cf - .) | (cd "$WORK_DIR" && tar --selinux -xf -) &
    show_copy_progress "$EXTRACT_DIR" "$WORK_DIR"
    wait $!
    if [ $? -ne 0 ]; then echo -e "${RED}Error: Failed to copy files with attributes${RESET}"; cleanup; exit 1; fi
    verify_modifications "$WORK_DIR"; restore_attributes "$WORK_DIR"; remove_repack_info "$WORK_DIR"
}

get_fs_param() {
    local image_file="$1"; local param="$2"; [ ! -f "$image_file" ] && { echo ""; return; }
    tune2fs -l "$image_file" | grep -E "^${param}:" | awk -F':' '{print $2}' | awk '{print $1}'
}

# --- Main Logic ---
if [ "$NO_BANNER" = false ]; then
  echo -e "\n${BLUE}${BOLD}Starting repacking process...${RESET}"
  echo -e "${BLUE}┌─ Source directory: ${BOLD}$EXTRACT_DIR${RESET}"
  echo -e "${BLUE}└─ Target image: ${BOLD}$OUTPUT_IMG${RESET}\n"
fi

# Filesystem Selection
if [ -z "$FS_CHOICE" ]; then
    echo -e "\n${BLUE}${BOLD}Select filesystem type:${RESET}"
    echo -e "1. EROFS"
    echo -e "2. EXT4"
    read -p "Enter your choice [1-2]: " choice
    [ "$choice" == "1" ] && FS_CHOICE="erofs" || FS_CHOICE="ext4"
fi

case $FS_CHOICE in
    erofs)
        prepare_working_directory
        if [ -z "$EROFS_COMP" ]; then
            echo -e "\n${BLUE}${BOLD}Select compression method:${RESET}"
            options=("none" "lz4" "lz4hc" "deflate"); read -p "Choice (1-4): " c; EROFS_COMP=${options[$((c-1))]}
        fi
        COMPRESSION_ARG=""
        case $EROFS_COMP in
            lz4) COMPRESSION_ARG="-zlz4" ;;
            lz4hc)
                [ -z "$EROFS_LEVEL" ] && read -p "LZ4HC level (0-12) [9]: " EROFS_LEVEL
                COMPRESSION_ARG="-zlz4hc,level=${EROFS_LEVEL:-9}"
                ;;
            deflate)
                [ -z "$EROFS_LEVEL" ] && read -p "Deflate level (0-9) [1]: " EROFS_LEVEL
                COMPRESSION_ARG="-zdeflate,level=${EROFS_LEVEL:-1}"
                ;;
        esac
        MKFS_CMD="mkfs.erofs $COMPRESSION_ARG ${OUTPUT_IMG}.tmp $WORK_DIR"
        echo -e "\n${BLUE}Executing command:${RESET} ${BOLD}$MKFS_CMD${RESET}\n"
        eval "$MKFS_CMD"
        if [ $? -eq 0 ]; then
            mv "${OUTPUT_IMG}.tmp" "$OUTPUT_IMG"
            echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
        fi
        ;;
    ext4)
        MOUNT_POINT="${TEMP_ROOT}/ext4_mount"; mkdir -p "$MOUNT_POINT"
        if [ -z "$EXT4_MODE" ]; then
            echo -e "\n${BLUE}${BOLD}Select EXT4 Repack Mode:${RESET}"; echo "1. Strict"; echo "2. Flexible"
            read -p "Choice [1-2]: " choice; [ "$choice" == "1" ] && EXT4_MODE="strict" || EXT4_MODE="flexible"
        fi
        ORIGINAL_IMAGE=$(grep "SOURCE_IMAGE" "${REPACK_INFO}/metadata.txt" | awk -F'=' '{print $2}')
        ORIGINAL_FS_TYPE=$(grep "FILESYSTEM_TYPE" "${REPACK_INFO}/metadata.txt" | awk -F'=' '{print $2}')
        if [ "$ORIGINAL_FS_TYPE" == "ext4" ]; then
            ORIGINAL_BLOCK_COUNT=$(get_fs_param "$ORIGINAL_IMAGE" "Block count"); ORIGINAL_INODE_COUNT=$(get_fs_param "$ORIGINAL_IMAGE" "Inode count")
            ORIGINAL_CAPACITY=$((ORIGINAL_BLOCK_COUNT * 4096))
            CURRENT_INODE_COUNT=$(find "$EXTRACT_DIR" -path "${EXTRACT_DIR}/.repack_info" -prune -o -print | wc -l); CURRENT_INODE_COUNT=$((CURRENT_INODE_COUNT - 1))
            CURRENT_CONTENT_SIZE=$(du -sb --exclude=.repack_info "$EXTRACT_DIR" | awk '{print $1}')
        fi
        REPACK_LOGIC="create_new"
        if [ "$EXT4_MODE" == "strict" ]; then
            if [ "$ORIGINAL_FS_TYPE" != "ext4" ]; then echo -e "${RED}Strict mode requires original to be ext4.${RESET}"; exit 1; fi
            INODE_CHECK_COUNT=$((CURRENT_INODE_COUNT + 5))
            if [ "$CURRENT_CONTENT_SIZE" -gt "$ORIGINAL_CAPACITY" ] || [ "$INODE_CHECK_COUNT" -gt "$ORIGINAL_INODE_COUNT" ]; then
                echo -e "${RED}Content too large for strict mode. Use flexible mode.${RESET}"; exit 1
            fi
            REPACK_LOGIC="clone"
        elif [ "$ORIGINAL_FS_TYPE" == "ext4" ]; then # Flexible mode with ext4 original
            INODE_CHECK_COUNT=$((CURRENT_INODE_COUNT + 100))
            if [ "$CURRENT_CONTENT_SIZE" -le "$ORIGINAL_CAPACITY" ] && [ "$INODE_CHECK_COUNT" -le "$ORIGINAL_INODE_COUNT" ]; then
                REPACK_LOGIC="clone"
            fi
        fi

        if [ "$REPACK_LOGIC" == "clone" ]; then
            echo -e "${GREEN}Content fits. Cloning original structure for efficiency.${RESET}"
            cp "$ORIGINAL_IMAGE" "$OUTPUT_IMG"; mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"
            (cd "$MOUNT_POINT" && find . -mindepth 1 ! -name 'lost+found' -delete)
        else
            echo -e "${YELLOW}Creating new image...${RESET}"
            if [ "$ORIGINAL_FS_TYPE" == "ext4" ]; then
                UUID=$(get_fs_param "$ORIGINAL_IMAGE" "Filesystem UUID"); VOLUME_NAME=$(get_fs_param "$ORIGINAL_IMAGE" "Filesystem volume name"); INODE_SIZE=$(get_fs_param "$ORIGINAL_IMAGE" "Inode size")
                FEATURES=$(tune2fs -l "$ORIGINAL_IMAGE" | grep "Filesystem features:" | awk -F':' '{print $2}' | xargs | sed 's/ /,/g'); HASH_SEED=$(get_fs_param "$ORIGINAL_IMAGE" "Directory Hash Seed")
            fi
            SIZE_WITH_OVERHEAD=$(echo "($CURRENT_CONTENT_SIZE * 1.25) + (32 * 1024 * 1024)" | bc); BLOCK_COUNT=$(echo "($SIZE_WITH_OVERHEAD + 4095) / 4096" | bc)
            echo -e "${BLUE}New Block count: $BLOCK_COUNT${RESET}"; dd if=/dev/zero of="$OUTPUT_IMG" bs=4096 count="$BLOCK_COUNT" status=none
            mkfs.ext4 -q -b 4096 ${INODE_SIZE:+-I "$INODE_SIZE"} ${UUID:+-U "$UUID"} ${VOLUME_NAME:+-L "$VOLUME_NAME"} ${FEATURES:+-O "$FEATURES"} ${HASH_SEED:+-E "hash_seed=$HASH_SEED"} "$OUTPUT_IMG"
            mount -o loop,rw "$OUTPUT_IMG" "$MOUNT_POINT"
        fi
        echo -e "\n${BLUE}Copying files to image...${RESET}"
        (cd "$EXTRACT_DIR" && tar --selinux --exclude=.repack_info -cf - .) | (cd "$MOUNT_POINT" && tar --selinux -xf -) &
        show_copy_progress "$EXTRACT_DIR" "$MOUNT_POINT"
        wait $!
        verify_modifications "$MOUNT_POINT"; restore_attributes "$MOUNT_POINT"; remove_repack_info "$MOUNT_POINT"
        echo -e "${BLUE}Unmounting image...${RESET}"; sync && umount "$MOUNT_POINT"
        e2fsck -yf "$OUTPUT_IMG" >/dev/null 2>/dev/null
        echo -e "\n${GREEN}${BOLD}Successfully created EXT4 image: $OUTPUT_IMG${RESET}"
        ;;
    *) echo -e "${RED}Invalid choice. Exiting.${RESET}"; exit 1 ;;
esac

if [ -n "$SUDO_USER" ]; then chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"; fi
trap - INT TERM EXIT
cleanup
if [ "$NO_BANNER" = false ]; then echo -e "\n${GREEN}${BOLD}Done!${RESET}"; fi
