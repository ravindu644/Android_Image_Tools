#!/bin/bash
# Android Image Tools - by @ravindu644
#
# A comprehensive, stable wrapper for unpacking and repacking Android images.

# --- Global Settings & Color Codes ---
trap 'cleanup_and_exit' INT TERM EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
UNPACK_SCRIPT_PATH="${SCRIPT_DIR}/unpack-erofs.sh"
REPACK_SCRIPT_PATH="${SCRIPT_DIR}/repack-erofs.sh"

WORKSPACE_DIRS=("INPUT_IMAGES" "EXTRACTED_IMAGES" "REPACKED_IMAGES")

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"
AIT_CHOICE_INDEX=0; AIT_SELECTED_ITEM=""

# --- Core Functions ---
print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌──────────────────────────────────────────────────┐"
    echo "│     Android Image Tools - by @ravindu644         │"
    echo "└──────────────────────────────────────────────────┘"
    echo -e "${RESET}"
}

cleanup_and_exit() {
    tput cnorm # Ensure cursor is always visible on exit
    echo -e "\n${YELLOW}Exiting Android Image Tools.${RESET}"
    exit 130 # Standard exit code for Ctrl+C
}

check_distro() {
    if ! command -v dpkg &>/dev/null || ! command -v apt &>/dev/null; then
        echo -e "\n${RED}${BOLD}Error: Unsupported Operating System Detected.${RESET}"
        echo -e "${YELLOW}This script is designed specifically for Debian-based distributions (like Ubuntu)${RESET}"
        echo -e "${YELLOW}which use 'apt' and 'dpkg' for package management.${RESET}"
        echo -e "\nThis is to ensure proper handling of SELinux contexts, which can be inconsistent"
        echo -e "on other distributions (e.g., Arch, Fedora), leading to repacking errors."
        exit 1
    fi
}

check_dependencies() {
    local missing_pkgs=()
    local erofs_utils_missing=false
    local REQUIRED_PACKAGES=("android-sdk-libsparse-utils" "build-essential" "automake" "autoconf" "libtool" "git" "fuse3" "e2fsprogs" "pv" "liblz4-dev" "uuid-dev" "libfuse3-dev")
    
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    if ! command -v mkfs.erofs &>/dev/null; then
        erofs_utils_missing=true
    fi
    
    if [ ${#missing_pkgs[@]} -eq 0 ] && [ "$erofs_utils_missing" = false ]; then
        return 0 # All dependencies are present, exit silently
    fi
    
    # If we reach here, some dependencies are missing.
    clear
    print_banner
    echo -e "\n${RED}${BOLD}Warning: Missing required dependencies.${RESET}"
    
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}The following packages are missing:${RESET}"
        echo "  - ${missing_pkgs[*]}"
    fi

    if [ "$erofs_utils_missing" = true ]; then
        echo -e "\n${YELLOW}The 'erofs-utils' build tools are also missing.${RESET}"
    fi

    read -rp "$(echo -e "\n${BLUE}Do you want to attempt automatic installation? (y/N): ${RESET}")" choice
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}Starting automatic installation...${RESET}"
        set -e
        
        if [ ${#missing_pkgs[@]} -gt 0 ]; then
            local unique_pkgs=$(echo "${missing_pkgs[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')
            echo -e "\n${BLUE}Updating package lists...${RESET}"
            sudo apt update
            echo -e "\n${BLUE}Installing required packages: $unique_pkgs${RESET}"
            sudo apt install -y $unique_pkgs
        fi

        if [ "$erofs_utils_missing" = true ]; then
            echo -e "\n${BLUE}Cloning and compiling 'erofs-utils'...${RESET}"
            local erofs_tmp_dir
            erofs_tmp_dir=$(mktemp -d)
            git clone https://github.com/erofs/erofs-utils.git "$erofs_tmp_dir"
            cd "$erofs_tmp_dir"
            ./autogen.sh
            ./configure --enable-fuse
            make
            sudo make install
            cd "$SCRIPT_DIR"
            rm -rf "$erofs_tmp_dir"
            echo -e "${GREEN}'erofs-utils' installed successfully.${RESET}"
        fi
        
        set +e
        echo -e "\n${GREEN}${BOLD}[✓] All dependencies should now be installed.${RESET}"
        read -rp "Press Enter to continue..."
    else
        echo -e "\n${YELLOW}Automatic installation declined.${RESET}"
        echo -e "Please install the dependencies manually and re-run the script."
        exit 1
    fi
}

create_workspace() {
    local ALL_DIRS=("${WORKSPACE_DIRS[@]}" "CONFIGS")
    for dir in "${ALL_DIRS[@]}"; do
        mkdir -p "$dir"
        if [ -n "$SUDO_USER" ]; then
            chown -R "$SUDO_USER:${SUDO_GROUP:-$SUDO_USER}" "$dir"
        fi
    done
}

generate_config_file() {
    local config_path="default.conf"
    echo -e "\n${BLUE}Generating fully documented configuration file at '${config_path}'...${RESET}"
    cat > "$config_path" <<'EOF'
# --- Android Image Tools Configuration File ---
# USAGE: sudo ./android_image_tools.sh --conf=your_config.conf
#
# --- [DOCUMENTATION] ---
# ACTION: "unpack" or "repack". (Mandatory)
# INPUT_IMAGE: Image in 'INPUT_IMAGES' to unpack.
# EXTRACT_DIR: Directory name for extracted files in 'EXTRACTED_IMAGES'.
# SOURCE_DIR: Source directory in 'EXTRACTED_IMAGES' to repack.
# OUTPUT_IMAGE: Output filename in 'REPACKED_IMAGES'.
# FILESYSTEM: "ext4" or "erofs".
# CREATE_SPARSE_IMAGE: "true" to create a flashable .sparse.img, "false" for raw .img.
# COMPRESSION_MODE: For erofs - "none", "lz4", "lz4hc", "deflate".
# COMPRESSION_LEVEL: For erofs lz4hc(0-12) or deflate(0-9).
# MODE: For ext4 - "flexible" (recommended) or "strict".

# --- Default Settings Begin Here ---
ACTION=repack
INPUT_IMAGE=system.img
EXTRACT_DIR=extracted_system
SOURCE_DIR=extracted_system
OUTPUT_IMAGE=system_new.img
FILESYSTEM=ext4
CREATE_SPARSE_IMAGE=true
COMPRESSION_MODE=lz4
COMPRESSION_LEVEL=9
MODE=flexible
EOF
    echo -e "\n${GREEN}${BOLD}[✓] Configuration file generated successfully.${RESET}"
}

display_final_image_size() {
    local image_path="$1"
    if [ ! -f "$image_path" ]; then
        return
    fi
    
    local file_size
    file_size=$(du -h "$image_path" | awk '{print $1}')
    echo -e "\n${GREEN}${BOLD}Final Image Size: ${file_size}${RESET}"
}

# --- Interactive Menu Functions ---
select_option() {
    local header="$1"
    shift
    local no_clear=false
    local options
    if [[ "${!#}" == "--no-clear" ]]; then
        no_clear=true
        options=("${@:1:$#-1}")
    else
        options=("$@")
    fi

    local current=0
    local is_first_iteration=true
    local options_height=${#options[@]}
    
    tput civis
    if [ "$no_clear" = false ]; then
        clear
        print_banner
    fi
    echo -e "\n${BOLD}${header}${RESET}\n"
    
    while true; do
        if [ "$is_first_iteration" = false ]; then
            tput cuu "$options_height"
        fi
        
        for i in "${!options[@]}"; do
            tput el
            local option_text="${options[$i]}"
            local is_danger=false
            if [[ "$option_text" == "Cleanup Workspace" || "$option_text" == "Yes, DELETE EVERYTHING" ]]; then
                is_danger=true
            fi
            
            if [ $i -eq $current ]; then
                if [ "$is_danger" = true ]; then
                    echo -e "  ${RED}▶ $option_text${RESET}"
                else
                    echo -e "  ${GREEN}▶ $option_text${RESET}"
                fi
            else
                echo -e "    $option_text"
            fi
        done
        
        is_first_iteration=false
        read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') current=$(( (current - 1 + ${#options[@]}) % ${#options[@]} )) ;;
                '[B') current=$(( (current + 1) % ${#options[@]} )) ;;
            esac
        elif [[ "$key" == "" ]]; then
            break
        fi
    done
    
    tput cnorm
    AIT_CHOICE_INDEX=$current
}

select_item() {
    local header="$1"; local search_path="$2"; local item_type="$3"; local items=(); local find_args=()
    case "$item_type" in
        file) find_args=(-type f) ;;
        dir) find_args=(-type d) ;;
        *) find_args=\( -type f -o -type d \) ;;
    esac
    
    while IFS= read -r item; do
        items+=("$(basename "$item")")
    done < <(find "$search_path" -mindepth 1 -maxdepth 1 "${find_args[@]}" 2>/dev/null)
    
    if [ ${#items[@]} -eq 0 ]; then
        clear; print_banner; echo -e "\n${YELLOW}Warning: No items found in '${search_path}'.${RESET}"; read -rp $'\nPress Enter to return...'; return 1
    fi
    
    items+=("Back to Main Menu")
    select_option "$header" "${items[@]}"
    
    if [ "$AIT_CHOICE_INDEX" -eq $((${#items[@]} - 1)) ]; then
        return 1
    fi
    
    AIT_SELECTED_ITEM="${search_path}/${items[$AIT_CHOICE_INDEX]}"
    return 0
}

export_repack_config() {
    local source_dir="$1"; local output_image="$2"; local fs="$3"; local repack_mode="$4"; local erofs_comp="$5"; local erofs_level="$6"; local create_sparse="$7"
    
    mkdir -p "CONFIGS"
    clear; print_banner
    
    local partition_name
    partition_name=$(basename "$source_dir" | sed 's/^extracted_//')
    local default_conf_name="${partition_name}_repack.conf"
    
    read -rp "$(echo -e ${BLUE}"Enter a filename for the preset [${BOLD}${default_conf_name}${BLUE}]: "${RESET})" conf_filename
    conf_filename=${conf_filename:-$default_conf_name}
    
    local final_conf_path="CONFIGS/$conf_filename"
    local full_source_path
    full_source_path=$(realpath "$source_dir")
    local full_output_path
    full_output_path="$(realpath "$(dirname "$output_image")")/$(basename "$output_image")"
    
    cat > "$final_conf_path" <<EOF
# --- Android Image Tools Repack Configuration ---
# Generated on $(date)
# USAGE: sudo ./android_image_tools.sh --conf=$final_conf_path
ACTION=repack
SOURCE_DIR=$full_source_path
OUTPUT_IMAGE=$full_output_path
FILESYSTEM=$fs
CREATE_SPARSE_IMAGE=$create_sparse
EOF

    if [ "$fs" == "erofs" ]; then
        cat >> "$final_conf_path" <<EOF
# --- EROFS Settings ---
COMPRESSION_MODE=${erofs_comp:-none}
COMPRESSION_LEVEL=${erofs_level:-9}
EOF
    else
        cat >> "$final_conf_path" <<EOF
# --- EXT4 Settings ---
MODE=${repack_mode:-flexible}
EOF
    fi
    
    echo -e "\n${GREEN}${BOLD}[✓] Settings successfully exported to '${final_conf_path}'.${RESET}"
    read -rp $'\nPress Enter to return to the summary...'
}

cleanup_workspace() {
    clear; print_banner
    
    local total_bytes=0
    local dirs_to_scan=("${WORKSPACE_DIRS[@]}" "CONFIGS")
    local workspace_bytes
    workspace_bytes=$(du -sb "${dirs_to_scan[@]}" 2>/dev/null | awk '{s+=$1} END {print s}')
    total_bytes=$((total_bytes + ${workspace_bytes:-0}))
    
    local temp_files_list
    temp_files_list=$(find /tmp -mindepth 1 -maxdepth 1 \( -name "repack-*" -o -name "*_mount" -o -name "*_raw.img" \) 2>/dev/null)
    if [ -n "$temp_files_list" ]; then
        local temp_bytes
        temp_bytes=$(echo "$temp_files_list" | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s}')
        total_bytes=$((total_bytes + ${temp_bytes:-0}))
    fi
    
    local total_size
    total_size=$(numfmt --to=iec-i --suffix=B --padding=7 "$total_bytes")
    
    echo -e "\n${RED}${BOLD}WARNING: IRREVERSIBLE ACTION${RESET}"
    echo -e "${YELLOW}You are about to permanently delete all files in the workspace and all related temporary files.${RESET}"
    echo -e "\n  - ${BOLD}Total space to be reclaimed: ${YELLOW}$total_size${RESET}"
    
    select_option "Are you sure you want to proceed?" "Yes, DELETE EVERYTHING" "No, take me back" --no-clear
    
    if [ "$AIT_CHOICE_INDEX" -ne 0 ]; then
        echo -e "\n${GREEN}Cleanup cancelled.${RESET}"; sleep 1; return
    fi
    
    echo -e "\n${BLUE}Cleaning workspace directories...${RESET}"
    for dir in "${dirs_to_scan[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "  - Deleting contents of ${BOLD}$dir${RESET} (excluding .gitkeep)..."
            find "$dir" -mindepth 1 -not -name '.gitkeep' -delete
        fi
    done
    
    echo -e "\n${BLUE}Cleaning temporary system files...${RESET}"
    if [ -n "$temp_files_list" ]; then
        echo "$temp_files_list" | xargs rm -rf
        echo -e "  - Deleted temporary files."
    else
        echo -e "  - No temporary files found."
    fi
    
    echo -e "\n${GREEN}${BOLD}[✓] Workspace and temporary files have been cleaned.${RESET}"
    read -rp $'\nPress Enter to return to the main menu...'
}

run_unpack_interactive() {
    local input_image output_dir; local step=1
    while true; do
        case $step in
            1)
                select_item "Step 1: Select image to unpack:" "INPUT_IMAGES" "file"; if [ $? -ne 0 ]; then return; fi
                input_image="$AIT_SELECTED_ITEM"; step=2;;
            2)
                local default_output_dir="EXTRACTED_IMAGES/extracted_$(basename "$input_image" .img)"; clear; print_banner; echo
                read -rp "$(echo -e ${BLUE}"Step 2: Enter output directory path [${BOLD}${default_output_dir}${BLUE}]: "${RESET})" output_dir
                output_dir=${output_dir:-$default_output_dir}; step=3;;
            3)
                clear; print_banner; echo -e "\n${BOLD}Unpack Operation Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Output Directory:${RESET} $output_dir"
                select_option "Proceed with this operation?" "Proceed" "Back" --no-clear
                if [ "$AIT_CHOICE_INDEX" -eq 1 ]; then step=1; continue; fi
                echo -e "\n${RED}${BOLD}Starting unpack. DO NOT INTERRUPT...${RESET}"; trap '' INT
                set -e; bash "$UNPACK_SCRIPT_PATH" "$input_image" "$output_dir" --no-banner; set +e
                trap 'cleanup_and_exit' INT TERM EXIT
                echo -e "\n${GREEN}${BOLD}Unpack successful. Files are in: $output_dir${RESET}"
                read -rp $'\nPress Enter to return...'; break;;
        esac
    done
}

run_repack_interactive() {
    local source_dir output_image fs repack_mode erofs_comp erofs_level create_sparse; local step=1
    while true; do
        case $step in
            1)
                select_item "Step 1: Select directory to repack:" "EXTRACTED_IMAGES" "dir"; if [ $? -ne 0 ]; then return; fi
                source_dir="$AIT_SELECTED_ITEM"; step=2;;
            2)
                local partition_name=$(basename "$source_dir" | sed 's/^extracted_//'); local default_output_image="REPACKED_IMAGES/${partition_name}_repacked.img"; clear; print_banner; echo
                read -rp "$(echo -e ${BLUE}"Step 2: Enter output image path [${BOLD}${default_output_image}${BLUE}]: "${RESET})" output_image
                output_image=${output_image:-$default_output_image}; step=3;;
            3)
                local fs_options=("EROFS" "EXT4" "Back"); select_option "Step 3: Select filesystem:" "${fs_options[@]}";
                case $AIT_CHOICE_INDEX in 0) fs="erofs"; step=4;; 1) fs="ext4"; step=4;; 2) step=1; continue;; esac;;
            4)
                if [ "$fs" == "erofs" ]; then
                    local erofs_options=("none" "lz4" "lz4hc" "deflate" "Back"); select_option "Step 4: Select EROFS compression:" "${erofs_options[@]}"; if [ "$AIT_CHOICE_INDEX" -eq 4 ]; then step=3; continue; fi
                    erofs_comp=${erofs_options[$AIT_CHOICE_INDEX]}; erofs_level=""; if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then clear; print_banner; read -rp "$(echo -e ${BLUE}"Step 4a: Level (lz4hc 0-12, deflate 0-9): "${RESET})" erofs_level; fi
                else
                    local ext4_options=("Flexible (Recommended)" "Strict" "Back"); select_option "Step 4: Select EXT4 repack mode:" "${ext4_options[@]}"; if [ "$AIT_CHOICE_INDEX" -eq 2 ]; then step=3; continue; fi
                    [ "$AIT_CHOICE_INDEX" -eq 0 ] && repack_mode="flexible" || repack_mode="strict"
                fi; step=5;;
            5)
                local sparse_options=("Yes" "No" "Back"); select_option "Step 5: Create a flashable sparse image?" "${sparse_options[@]}";
                case $AIT_CHOICE_INDEX in 0) create_sparse="true"; step=6;; 1) create_sparse="false"; step=6;; 2) step=4; continue;; esac;;
            6)
                clear; print_banner; echo -e "\n${BOLD}Repack Operation Summary:${RESET}\n  - ${YELLOW}Source Directory:${RESET} $source_dir\n  - ${YELLOW}Output Image:${RESET}     $output_image\n  - ${YELLOW}Filesystem:${RESET}       $fs"
                if [ "$fs" == "erofs" ]; then echo -e "  - ${YELLOW}EROFS Compression:${RESET}  $erofs_comp"; if [ -n "$erofs_level" ]; then echo -e "  - ${YELLOW}EROFS Level:${RESET}        ${erofs_level:-default}"; fi; else echo -e "  - ${YELLOW}EXT4 Mode:${RESET}        $repack_mode"; fi
                echo -e "  - ${YELLOW}Create Sparse IMG:${RESET}  $create_sparse"; select_option "What would you like to do?" "Proceed" "Export settings" "Back" --no-clear;
                case $AIT_CHOICE_INDEX in 0) ;; 1) export_repack_config "$source_dir" "$output_image" "$fs" "$repack_mode" "$erofs_comp" "$erofs_level" "$create_sparse"; step=6; continue;; 2) step=5; continue;; esac
                
                echo -e "\n${RED}${BOLD}Starting repack. DO NOT INTERRUPT...${RESET}"; trap '' INT; local repack_args=("--fs" "$fs")
                if [ "$fs" == "erofs" ]; then repack_args+=("--erofs-compression" "$erofs_comp"); if [ -n "$erofs_level" ]; then repack_args+=("--erofs-level" "$erofs_level"); fi; else repack_args+=("--ext4-mode" "$repack_mode"); fi
                
                set -e; bash "$REPACK_SCRIPT_PATH" "$source_dir" "$output_image" "${repack_args[@]}" --no-banner; set +e; trap 'cleanup_and_exit' INT TERM EXIT; echo
                
                local final_image_path="$output_image"
                if [ -f "$output_image" ]; then
                    if [ "$create_sparse" = true ]; then
                        local sparse_output="${output_image%.img}.sparse.img"; echo -e "\n${BLUE}Converting to sparse image...${RESET}"; set -e; img2simg "$output_image" "$sparse_output"; set +e; rm -f "$output_image"; final_image_path="$sparse_output"
                    fi
                    echo -e "\n${GREEN}${BOLD}Repack successful. Final image created at: ${final_image_path}${RESET}"
                    display_final_image_size "$final_image_path"
                else echo -e "\n${RED}${BOLD}Repack failed.${RESET}"; fi
                read -rp $'\nPress Enter to return...'; break;;
        esac
    done
}

run_non_interactive() {
    set -e; local config_file="$1"; echo -e "\n${BLUE}Running non-interactive with: ${BOLD}$config_file${RESET}"; declare -A CONFIG
    while IFS='=' read -r key value; do if [[ ! "$key" =~ ^\# && -n "$key" ]]; then CONFIG["$key"]="$value"; fi; done < "$config_file"
    ACTION="${CONFIG[ACTION]}"; if [ -z "$ACTION" ]; then echo -e "${RED}Error: 'ACTION' not defined.${RESET}"; exit 1; fi
    trap '' INT

    if [ "$ACTION" == "unpack" ]; then
        local input_image="${CONFIG[INPUT_IMAGE]}"; local extract_dir="${CONFIG[EXTRACT_DIR]}"
        if [[ "$input_image" != /* ]]; then input_image="INPUT_IMAGES/$input_image"; fi
        if [[ "$extract_dir" != /* ]]; then extract_dir="EXTRACTED_IMAGES/$extract_dir"; fi
        if [ -z "$input_image" ] || [ -z "$extract_dir" ]; then echo -e "${RED}Error: INPUT_IMAGE/EXTRACT_DIR not set.${RESET}"; exit 1; fi
        
        echo -e "\n${BOLD}Unpack Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Output Directory:${RESET} $extract_dir"
        echo -e "\n${RED}${BOLD}Starting unpack. DO NOT INTERRUPT...${RESET}"; bash "$UNPACK_SCRIPT_PATH" "$input_image" "$extract_dir" --no-banner
        echo -e "\n${GREEN}${BOLD}Success: Image unpacked to $extract_dir${RESET}"

    elif [ "$ACTION" == "repack" ]; then
        local source_dir="${CONFIG[SOURCE_DIR]}"; local output_image="${CONFIG[OUTPUT_IMAGE]}"; local fs="${CONFIG[FILESYSTEM]}"
        if [[ "$source_dir" != /* ]]; then source_dir="EXTRACTED_IMAGES/$source_dir"; fi
        if [[ "$output_image" != /* ]]; then output_image="REPACKED_IMAGES/$output_image"; fi
        if [ -z "$source_dir" ] || [ -z "$output_image" ] || [ -z "$fs" ]; then echo -e "${RED}Error: SOURCE_DIR/OUTPUT_IMAGE/FILESYSTEM not set.${RESET}"; exit 1; fi
        
        local repack_args=("--fs" "$fs"); local create_sparse="${CONFIG[CREATE_SPARSE_IMAGE]:-false}"; local erofs_comp="${CONFIG[COMPRESSION_MODE]:-none}"; local erofs_level="${CONFIG[COMPRESSION_LEVEL]}"; local ext4_mode="${CONFIG[MODE]:-flexible}"
        if [ "$fs" == "erofs" ]; then repack_args+=("--erofs-compression" "$erofs_comp"); repack_args+=("--erofs-level" "$erofs_level"); elif [ "$fs" == "ext4" ]; then repack_args+=("--ext4-mode" "$ext4_mode"); fi
        
        echo -e "\n${BOLD}Repack Summary:${RESET}\n  - ${YELLOW}Source Directory:${RESET} $source_dir\n  - ${YELLOW}Output Image:${RESET}     $output_image\n  - ${YELLOW}Filesystem:${RESET}       $fs"
        if [ "$fs" == "erofs" ]; then echo -e "  - ${YELLOW}EROFS Compression:${RESET}  $erofs_comp"; if [ -n "$erofs_level" ]; then echo -e "  - ${YELLOW}EROFS Level:${RESET}        $erofs_level"; fi; else echo -e "  - ${YELLOW}EXT4 Mode:${RESET}        $ext4_mode"; fi
        echo -e "  - ${YELLOW}Create Sparse IMG:${RESET}  $create_sparse"
        
        echo -e "\n${RED}${BOLD}Starting repack. DO NOT INTERRUPT...${RESET}"; bash "$REPACK_SCRIPT_PATH" "$source_dir" "$output_image" "${repack_args[@]}" --no-banner
        
        local final_image_path="$output_image"
        if [ -f "$output_image" ]; then
            if [ "$create_sparse" == "true" ]; then
                local sparse_output="${output_image%.img}.sparse.img"; echo -e "\n${BLUE}Creating sparse image...${RESET}"; img2simg "$output_image" "$sparse_output"; rm -f "$output_image"; final_image_path="$sparse_output"
            fi
            echo -e "\n${GREEN}${BOLD}Success: Final image created at: ${final_image_path}${RESET}"
            display_final_image_size "$final_image_path"
        else
            echo -e "\n${RED}${BOLD}Repack failed.${RESET}"
        fi
    else
        echo -e "${RED}Error: Invalid ACTION '${ACTION}'.${RESET}"; exit 1
    fi
    trap 'cleanup_and_exit' INT TERM EXIT
}

# --- Main Execution Logic ---
check_distro
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"; exit 1
fi

if [[ "$1" == "--conf="* ]]; then
    conf_file="${1#*=}"
    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}Error: Config file not found: '$conf_file'${RESET}"; exit 1
    fi
    print_banner
    check_dependencies
    create_workspace
    run_non_interactive "$conf_file"
    exit 0
fi

set +e
while true; do
    clear; print_banner
    if [ -z "$WORKSPACE_INITIALIZED" ]; then
        check_dependencies
        create_workspace
        WORKSPACE_INITIALIZED=true
    fi
    
    main_options=("Unpack an Android Image" "Repack a Directory" "Generate default.conf file" "Cleanup Workspace" "Exit")
    select_option "Select an action:" "${main_options[@]}"; choice=$AIT_CHOICE_INDEX
    
    case $choice in
        0) run_unpack_interactive;;
        1) run_repack_interactive;;
        2) generate_config_file; read -rp $'\nPress Enter to continue...';;
        3) cleanup_workspace;;
        4) break;;
    esac
done
