#!/bin/bash
# Android Image Tools - by @ravindu644
#
# A comprehensive, stable wrapper for unpacking and repacking Android images.

# --- Global Settings & Color Codes ---
trap 'cleanup_and_exit' INT TERM EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/.bin/util-functions.sh" || { echo -e "${RED}Error: util-functions.sh not found${RESET}"; exit 1; }
TMP_DIR="$SCRIPT_DIR/.tmp"

# Save original SELinux status and set to permissive for proper operations
ORIGINAL_SELINUX=$(getenforce 2>/dev/null || echo "Disabled")
if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
    setenforce 0
fi
UNPACK_SCRIPT_PATH="${SCRIPT_DIR}/.bin/unpack-erofs.sh"
REPACK_SCRIPT_PATH="${SCRIPT_DIR}/.bin/repack-erofs.sh"
SUPER_SCRIPT_PATH="${SCRIPT_DIR}/.bin/super-tools.sh"

WORKSPACE_DIRS=("INPUT_IMAGES" "EXTRACTED_IMAGES" "REPACKED_IMAGES" "SUPER_TOOLS")

AIT_CHOICE_INDEX=0; AIT_SELECTED_ITEM=""

# --- Core Functions ---

print_usage() {
    if [ -n "$1" ]; then echo -e "\n${RED}${BOLD}Error: Invalid argument '$1'${RESET}"; fi
    local script_name
    script_name=$(basename "$0")
    echo -e "\n${YELLOW}Usage:${RESET}"
    echo -e "  Interactive Mode: ${BOLD}sudo ./${script_name}${RESET}"
    echo -e "  Non-Interactive:  ${BOLD}sudo ./${script_name} --conf=<path_to_config_file>${RESET}"
    exit 1
}

sudo_cleanup_temp_dirs() {
    if [ -d "$TMP_DIR" ]; then
        sudo rm -rf "$TMP_DIR"
    fi
}

cleanup_and_exit() {
    tput cnorm
    sudo_cleanup_temp_dirs

    # Restore original SELinux status
    if [ "$ORIGINAL_SELINUX" = "Enforcing" ]; then
        setenforce 1 2>/dev/null || true
    fi

    echo -e "\n${YELLOW}Exiting Android Image Tools.${RESET}"
    exit 130
}

create_workspace() {
    local ALL_DIRS=("${WORKSPACE_DIRS[@]}" "CONFIGS" ".tmp")
    for dir in "${ALL_DIRS[@]}"; do
        mkdir -p "$SCRIPT_DIR/$dir"
        if [ -n "$SUDO_USER" ]; then
            chown -R "$SUDO_USER:${SUDO_GROUP:-$SUDO_USER}" "$SCRIPT_DIR/$dir"
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
# ACTION: "unpack", "repack", "super_unpack", or "super_repack". (Mandatory)
#
# == For single partitions ==
# INPUT_IMAGE: Image in 'INPUT_IMAGES' to unpack.
# EXTRACT_DIR: Directory name for extracted files in 'EXTRACTED_IMAGES'.
# SOURCE_DIR: Source directory in 'EXTRACTED_IMAGES' to repack.
# OUTPUT_IMAGE: Output filename in 'REPACKED_IMAGES'.
#
# == For super partitions ==
# PROJECT_NAME: The name of the project folder inside 'SUPER_TOOLS'.
#   - For super_unpack: The name of the project to create.
#   - For super_repack: The name of the existing project to repack.
#
# == General Repack Settings ==
# FILESYSTEM: "ext4" or "erofs".
# CREATE_SPARSE_IMAGE: "true" to create a flashable .sparse.img, "false" for raw .img.
# COMPRESSION_MODE: For erofs - "none", "lz4", "lz4hc", "deflate".
# COMPRESSION_LEVEL: For erofs lz4hc(0-12) or deflate(0-9).
# MODE: For ext4 - "flexible" or "strict".
#
# == EXT4 Flexible Mode Settings (Optional) ==
# EXT4_OVERHEAD_PERCENT: Percentage of free space to add. Default is "5".

# --- Default Settings Begin Here ---
ACTION=repack
INPUT_IMAGE=system.img
EXTRACT_DIR=extracted_system
SOURCE_DIR=extracted_system
OUTPUT_IMAGE=system_new.img
FILESYSTEM=ext4
CREATE_SPARSE_IMAGE=true
MODE=flexible
EXT4_OVERHEAD_PERCENT=5
EOF
    echo -e "\n${GREEN}${BOLD}[✓] Configuration file generated successfully.${RESET}"
}

display_final_image_size() {
    local image_path="$1"
    if [ ! -f "$image_path" ]; then return; fi
    local file_size
    file_size=$(stat -c %s "$image_path" | numfmt --to=iec-i --suffix=B --padding=7)
    echo -e "\n${GREEN}${BOLD}Final Image Size: ${file_size}${RESET}"
}

is_empty_partition() {
    local image_path="$1"
    [ ! -f "$image_path" ] && return 1

    local file_size
    file_size=$(stat -c%s "$image_path" 2>/dev/null)

    # 0-byte files are definitely empty
    [ "$file_size" -eq 0 ] && return 0

    # Files reported as "empty" by the file command
    file "$image_path" 2>/dev/null | grep -q "empty" && return 0

    # For small files (<= 4096 bytes), check if they are all zeros
    if [ "$file_size" -le 4096 ]; then
        local temp_zero
        temp_zero=$(mktemp)
        dd if=/dev/zero of="$temp_zero" bs=1 count="$file_size" 2>/dev/null
        if cmp -s "$image_path" "$temp_zero" 2>/dev/null; then
            rm -f "$temp_zero"
            return 0
        fi
        rm -f "$temp_zero"
    fi
    return 1
}

# Safely load metadata from file (handles values like <none>)
load_metadata() {
    local metadata_file="$1"
    [ ! -f "$metadata_file" ] && return
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        export "${key}"="${value}"
    done < "$metadata_file"
}

# Read empty partitions list into array
read_empty_partitions() {
    local empty_partitions_file="$1"
    local -n empty_array="$2"
    empty_array=()
    [ ! -f "$empty_partitions_file" ] && return
    while IFS= read -r empty_part; do
        [ -n "$empty_part" ] && empty_array+=("$empty_part")
    done < "$empty_partitions_file"
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
    local header="$1"
    local search_path="$SCRIPT_DIR/$2"
    local item_type="$3"
    local add_back_option=true
    if [[ "$4" == "--no-back" ]]; then
        add_back_option=false
    fi
    local items=()
    local find_args=()

    case "$item_type" in

        # This one specifically excludes any file containing 'super' in the name
        single_partition_image)
            find_args=(-type f \( -name '*.img' -o -name '*.img.raw' \) ! -name '*super*')
            ;;
        # This one is for finding ONLY super images (files with 'super' in the name)
        image_file)
            find_args=(-type f \( -name '*super*.img' -o -name '*super*.img.raw' \))
            ;;
        dir)
            find_args=(-type d)
            ;;
        *)
            find_args=\( -type f -o -type d \)
            ;;
    esac

    while IFS= read -r item; do
        items+=("$(basename "$item")")
    done < <(find "$search_path" -mindepth 1 -maxdepth 1 "${find_args[@]}" 2>/dev/null)

    if [ ${#items[@]} -eq 0 ]; then
        clear; print_banner
        echo -e "\n${YELLOW}Warning: No items of type '${item_type}' found in '${search_path}'.${RESET}"
        read -rp $'\nPress Enter to return...'
        return 1
    fi

    if [ "$add_back_option" = true ]; then
        items+=("Back")
    fi
    select_option "$header" "${items[@]}"

    if [ "$add_back_option" = true ] && [ "$AIT_CHOICE_INDEX" -eq $((${#items[@]} - 1)) ]; then
        return 1
    fi

    AIT_SELECTED_ITEM="${search_path}/${items[$AIT_CHOICE_INDEX]}"
    return 0
}

export_repack_config() {
    local source_dir="$1" output_image="$2" fs="$3" repack_mode="$4" erofs_comp="$5" erofs_level="$6" create_sparse="$7" overhead_percent="$8"

    mkdir -p "$SCRIPT_DIR/CONFIGS"
    clear; print_banner

    local partition_name
    partition_name=$(basename "$source_dir" | sed 's/^extracted_//')
    local default_conf_name="${partition_name}_repack.conf"

    read -rp "$(echo -e ${BLUE}"Enter filename for preset [${BOLD}${default_conf_name}${BLUE}]: "${RESET})" conf_filename
    conf_filename=${conf_filename:-$default_conf_name}

    local final_conf_path="$SCRIPT_DIR/CONFIGS/$conf_filename"
    local full_source_path
    full_source_path=$(realpath "$source_dir")
    local full_output_path
    full_output_path="$(realpath "$(dirname "$output_image")")/$(basename "$output_image")"

    {
        echo "# --- Android Image Tools Repack Configuration ---"
        echo "ACTION=repack"
        echo "SOURCE_DIR=$full_source_path"
        echo "OUTPUT_IMAGE=$full_output_path"
        echo "FILESYSTEM=$fs"
        echo "CREATE_SPARSE_IMAGE=$create_sparse"

        if [ "$fs" == "erofs" ]; then
            echo "COMPRESSION_MODE=${erofs_comp:-none}"
            if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then
                echo "COMPRESSION_LEVEL=${erofs_level:-9}"
            fi
        else
            echo "MODE=${repack_mode:-flexible}"
            if [ "$repack_mode" == "flexible" ]; then
                echo "EXT4_OVERHEAD_PERCENT=${overhead_percent:-5}"
            fi
        fi
    } > "$final_conf_path"

    echo -e "\n${GREEN}${BOLD}[✓] Settings successfully exported to '${final_conf_path}'.${RESET}"
    read -rp $'\nPress Enter to return to the summary...'
}

export_unpack_config() {
    local input_image="$1" output_dir="$2"

    mkdir -p "$SCRIPT_DIR/CONFIGS"
    clear; print_banner

    local image_name
    image_name=$(basename "$input_image" .img)
    local default_conf_name="${image_name}_unpack.conf"

    read -rp "$(echo -e ${BLUE}"Enter filename for preset [${BOLD}${default_conf_name}${BLUE}]: "${RESET})" conf_filename
    conf_filename=${conf_filename:-$default_conf_name}

    local final_conf_path="$SCRIPT_DIR/CONFIGS/$conf_filename"
    local full_input_path
    full_input_path=$(realpath "$input_image")
    local full_output_path
    full_output_path=$(realpath "$output_dir")

    {
        echo "# --- Android Image Tools Unpack Configuration ---"
        echo "ACTION=unpack"
        echo "INPUT_IMAGE=$(basename "$full_input_path")"
        echo "EXTRACT_DIR=$(basename "$full_output_path")"
    } > "$final_conf_path"

    echo -e "\n${GREEN}${BOLD}[✓] Settings successfully exported to '${final_conf_path}'.${RESET}"
    read -rp $'\nPress Enter to return to the summary...'
}

export_super_unpack_config() {
    local super_image="$1" project_name="$2"

    mkdir -p "$SCRIPT_DIR/CONFIGS"
    clear; print_banner

    local image_name
    image_name=$(basename "$super_image" .img)
    local default_conf_name="${image_name}_${project_name}_unpack.conf"

    read -rp "$(echo -e ${BLUE}"Enter filename for preset [${BOLD}${default_conf_name}${BLUE}]: "${RESET})" conf_filename
    conf_filename=${conf_filename:-$default_conf_name}

    local final_conf_path="$SCRIPT_DIR/CONFIGS/$conf_filename"
    local full_input_path
    full_input_path=$(realpath "$super_image")

    {
        echo "# --- Android Image Tools Super Unpack Configuration ---"
        echo "ACTION=super_unpack"
        echo "INPUT_IMAGE=$(basename "$full_input_path")"
        echo "PROJECT_NAME=$project_name"
    } > "$final_conf_path"

    echo -e "\n${GREEN}${BOLD}[✓] Settings successfully exported to '${final_conf_path}'.${RESET}"
    read -rp $'\nPress Enter to return to the summary...'
}

cleanup_workspace() {
    clear; print_banner

    local total_bytes=0
    local dirs_to_scan=("${WORKSPACE_DIRS[@]}" "CONFIGS" ".tmp")
    local workspace_bytes
    workspace_bytes=$(du -sb "${dirs_to_scan[@]/#/$SCRIPT_DIR/}" 2>/dev/null | awk '{s+=$1} END {print s}')
    total_bytes=$((total_bytes + ${workspace_bytes:-0}))

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
        if [ -d "$SCRIPT_DIR/$dir" ]; then
            echo -e "  - Deleting contents of ${BOLD}$SCRIPT_DIR/$dir${RESET}"
            find "$SCRIPT_DIR/$dir" -mindepth 1 -not -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
        fi
    done

    echo -e "\n${GREEN}${BOLD}[✓] Workspace and temporary files have been cleaned.${RESET}"
    read -rp $'\nPress Enter to return to the main menu...'
}

# --- Single Image Tools ---
run_unpack_interactive() {
    local quiet_mode="$1"
    local input_image
    local output_dir
    local step=1

    while true; do
        case $step in
            1)
                # Safer item type to hide super.img
                select_item "Step 1: Select image to unpack:" "INPUT_IMAGES" "single_partition_image"
                if [ $? -ne 0 ]; then
                    return
                fi

                input_image="$AIT_SELECTED_ITEM"
                step=2
                ;;
            2)
                local default_output_dir="$SCRIPT_DIR/EXTRACTED_IMAGES/extracted_$(basename "$input_image" .img)"
                clear; print_banner; echo
                read -rp "$(echo -e ${BLUE}"Step 2: Enter output directory path [${BOLD}${default_output_dir}${BLUE}]: "${RESET})" output_dir
                output_dir="$(echo "$output_dir" | tr -d "\"'")"
                output_dir="${output_dir:-$default_output_dir}"
                step=3
                ;;
            3)
                clear; print_banner
                echo -e "\n${BOLD}Unpack Operation Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Output Directory:${RESET} $output_dir"
                select_option "Proceed with this operation?" "Proceed" "Export selected settings" "Back" --no-clear
                if [ "$AIT_CHOICE_INDEX" -eq 1 ]; then
                    export_unpack_config "$input_image" "$output_dir"
                    step=3
                    continue
                elif [ "$AIT_CHOICE_INDEX" -eq 2 ]; then
                    step=1
                    continue
                fi

                echo -e "\n${RED}${BOLD}Starting unpack. DO NOT INTERRUPT...${RESET}\n"
                trap '' INT
                local quiet_flag=""
                [ "$quiet_mode" = true ] && quiet_flag="--quiet"
                set +e  # Disable exit on error to check exit code
                bash "$UNPACK_SCRIPT_PATH" "$input_image" "$output_dir" --no-banner $quiet_flag
                local unpack_exit_code=$?
                set -e  # Re-enable exit on error
                trap 'cleanup_and_exit' INT TERM EXIT

                if [ $unpack_exit_code -ne 0 ]; then
                    echo -e "\n${RED}${BOLD}Unpack failed. Please check the errors above.${RESET}"
                else
                    echo -e "\n${GREEN}${BOLD}Unpack successful. Files are in: $output_dir${RESET}"
                fi
                read -rp $'\nPress Enter to return...'
                break
                ;;
        esac
    done
}

run_repack_interactive() {
    local quiet_mode="$1"
    local source_dir output_image fs repack_mode erofs_comp erofs_level create_sparse overhead_percent
    local step=1
    while true; do
        case $step in
            1)
                select_item "Step 1: Select directory to repack:" "EXTRACTED_IMAGES" "dir"; if [ $? -ne 0 ]; then return; fi
                source_dir="$AIT_SELECTED_ITEM"; step=2;;
            2)
                local partition_name=$(basename "$source_dir" | sed 's/^extracted_//'); local default_output_image="$SCRIPT_DIR/REPACKED_IMAGES/${partition_name}_repacked.img"; clear; print_banner; echo
                read -rp "$(echo -e ${BLUE}"Step 2: Enter output image path [${BOLD}${default_output_image}${BLUE}]: "${RESET})" output_image
                output_image="$(echo "$output_image" | tr -d "\"'")"
                output_image=${output_image:-$default_output_image}; step=3;;
            3)
                local mount_method=""
                load_metadata "${source_dir}/.repack_info/metadata.txt"
                mount_method="${MOUNT_METHOD}"

                if [ "$mount_method" == "fuse" ]; then
                    clear; print_banner
                    echo -e "\n${RED}${BOLD}WARNING: FUSE-based unpacking detected for this source directory.${RESET}"
                    echo -e "${RED}${BOLD}Repacking as EXT4 is not supported for images unpacked with FUSE.${RESET}"
                    echo -e "${RED}${BOLD}Only EROFS repacking is available.${RESET}"
                    read -rp $'\nPress Enter to continue with EROFS...'
                    fs="erofs"
                    step=4
                else
                    local fs_options=("EROFS" "EXT4" "Back"); select_option "Step 3: Select filesystem:" "${fs_options[@]}";
                    case $AIT_CHOICE_INDEX in 0) fs="erofs"; step=4;; 1) fs="ext4"; step=4;; 2) step=1; continue;; esac
                fi;;
            4)
                if [ "$fs" == "erofs" ]; then
                    local erofs_options=("none" "lz4" "lz4hc" "deflate" "Back"); select_option "Step 4: Select EROFS compression:" "${erofs_options[@]}"; if [ "$AIT_CHOICE_INDEX" -eq 4 ]; then step=3; continue; fi
                    erofs_comp=${erofs_options[$AIT_CHOICE_INDEX]}; erofs_level=""; if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then read -rp "$(echo -e ${BLUE}"Step 4a: Level (lz4hc 0-12, deflate 0-9): "${RESET})" erofs_level; erofs_level="$(echo "$erofs_level" | tr -d "\"'")"; fi
                else
                    local ext4_options=("Strict (clone original)" "Flexible (auto-resize)" "Back"); select_option "Step 4: Select EXT4 repack mode:" "${ext4_options[@]}"; if [ "$AIT_CHOICE_INDEX" -eq 2 ]; then step=3; continue; fi
                    if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
                        repack_mode="strict"
                    else
                        repack_mode="flexible"
                        select_option "Select Flexible Overhead:" "Minimal (10%)" "Standard (15%)" "Generous (20%)" "Custom"
                        case $AIT_CHOICE_INDEX in
                            0) overhead_percent=10 ;;
                            2) overhead_percent=20 ;;
                            3) read -rp "$(echo -e ${BLUE}"Enter custom percentage: "${RESET})" overhead_percent; overhead_percent="$(echo "$overhead_percent" | tr -d "\"'")" ;;
                            *) overhead_percent=15 ;;
                        esac
                        overhead_percent=${overhead_percent:-15}
                    fi
                fi; step=5;;
            5)
                local sparse_options=("Yes" "No" "Back"); select_option "Step 5: Create a flashable sparse image?" "${sparse_options[@]}";
                case $AIT_CHOICE_INDEX in 0) create_sparse="true"; step=6;; 1) create_sparse="false"; step=6;; 2) step=4; continue;; esac;;
            6)
                clear; print_banner; echo -e "\n${BOLD}Repack Operation Summary:${RESET}\n  - ${YELLOW}Source Directory:${RESET} $source_dir\n  - ${YELLOW}Output Image:${RESET}     $output_image\n  - ${YELLOW}Filesystem:${RESET}       $fs"
                if [ "$fs" == "erofs" ]; then echo -e "  - ${YELLOW}EROFS Compression:${RESET}  $erofs_comp"; if [ -n "$erofs_level" ]; then echo -e "  - ${YELLOW}EROFS Level:${RESET}        ${erofs_level:-default}"; fi; else echo -e "  - ${YELLOW}EXT4 Mode:${RESET}        $repack_mode"; if [ "$repack_mode" == "flexible" ]; then echo -e "  - ${YELLOW}EXT4 Overhead:${RESET}      ${overhead_percent}%"; fi; fi
                echo -e "  - ${YELLOW}Create Sparse IMG:${RESET}  $create_sparse"; select_option "What would you like to do?" "Proceed" "Export selected settings" "Back" --no-clear;
                case $AIT_CHOICE_INDEX in 0) ;; 1) export_repack_config "$source_dir" "$output_image" "$fs" "$repack_mode" "$erofs_comp" "$erofs_level" "$create_sparse" "$overhead_percent"; step=6; continue;; 2) step=5; continue;; esac

                echo -e "\n${RED}${BOLD}Starting repack. DO NOT INTERRUPT...${RESET}"; trap '' INT; local repack_args=("--fs" "$fs")
                if [ "$fs" == "erofs" ]; then repack_args+=("--erofs-compression" "$erofs_comp"); if [ -n "$erofs_level" ]; then repack_args+=("--erofs-level" "$erofs_level"); fi; else repack_args+=("--ext4-mode" "$repack_mode"); if [ "$repack_mode" == "flexible" ]; then repack_args+=("--ext4-overhead-percent" "$overhead_percent"); fi; fi

                local quiet_flag=""
                [ "$quiet_mode" = true ] && quiet_flag="--quiet"
                set +e  # Disable exit on error to check exit code
                bash "$REPACK_SCRIPT_PATH" "$source_dir" "$output_image" "${repack_args[@]}" --no-banner $quiet_flag
                local repack_exit_code=$?
                set -e  # Re-enable exit on error
                trap 'cleanup_and_exit' INT TERM EXIT

                local final_image_path="$output_image"
                if [ $repack_exit_code -eq 0 ] && [ -f "$output_image" ]; then
                    if [ "$create_sparse" = true ]; then
                        local sparse_output="${output_image%.img}.sparse.img"
                        echo -e "\n${BLUE}Converting to sparse image...${RESET}"
                        set +e  # Disable exit on error for sparse conversion
                        img2simg "$output_image" "$sparse_output"
                        local sparse_exit_code=$?
                        set -e  # Re-enable exit on error
                        if [ $sparse_exit_code -eq 0 ]; then
                            rm -f "$output_image"
                            final_image_path="$sparse_output"
                            # Transfer ownership to actual user
                            [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$final_image_path"
                        else
                            echo -e "${YELLOW}Warning: Sparse conversion failed, keeping raw image.${RESET}"
                        fi
                    fi
                    # Ensure ownership is correct even if sparse conversion was skipped
                    [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$final_image_path"
                    echo -e "${GREEN}${BOLD}Repack successful. Final image created at: ${final_image_path}${RESET}"
                    display_final_image_size "$final_image_path"
                else
                    echo -e "\n${RED}${BOLD}Repack failed. Please check the errors above.${RESET}"
                fi
                read -rp $'\nPress Enter to return...'; break;;
        esac
    done
}

# --- Super Kitchen Functions ---
run_super_unpack_interactive() {
    local quiet_mode="$1"
    local super_image session_name project_dir metadata_dir logical_dir extracted_dir

    select_item "Select super image to unpack:" "INPUT_IMAGES" "image_file"
    if [ $? -ne 0 ]; then return; fi
    super_image="$AIT_SELECTED_ITEM"

    clear; print_banner; echo
    read -rp "$(echo -e ${BLUE}"Enter a project name: "${RESET})" session_name
    session_name="$(echo "$session_name" | tr -d "\"'" | tr ' ' '_')"
    if [ -z "$session_name" ]; then
        echo -e "\n${RED}Error: Project name cannot be empty.${RESET}"; sleep 2; return
    fi

    # Ask for config export right after project name
    select_option "Would you like to export these settings to a config file for easy re-running?" "Yes" "No"

    if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
        export_super_unpack_config "$super_image" "$session_name"
    fi

    # Clear screen to remove config export prompt from output
    clear; print_banner

    project_dir="$SCRIPT_DIR/SUPER_TOOLS/$session_name"
    metadata_dir="$project_dir/.metadata"
    logical_dir="$project_dir/logical_partitions"
    extracted_dir="$project_dir/extracted_content"

    if [ -d "$project_dir" ]; then
        echo -e "\n${RED}Error: A project named '$session_name' already exists.${RESET}"; sleep 2; return
    fi

    mkdir -p "$project_dir" "$metadata_dir" "$logical_dir" "$extracted_dir"

    echo -e "${RED}${BOLD}Starting full super unpack. DO NOT INTERRUPT...${RESET}"
    trap '' INT
    set -e

    # Step 1: Run the initial part of super-tools to get metadata and convert to raw.
    # This is quick and the output is useful, so we show it directly.
    bash "$SUPER_SCRIPT_PATH" unpack "$super_image" "$logical_dir" --no-banner

    set +e # Disable exit on error for the loop
    local partition_list_file="${metadata_dir}/partition_list.txt"
    local empty_partitions_file="${metadata_dir}/empty_partitions.txt"
    touch "$partition_list_file" "$empty_partitions_file"

    # Check if this is a virtual-AB image
    local is_virtual_ab=false
    if [ -f "${metadata_dir}/super_repack_info.txt" ]; then
        load_metadata "${metadata_dir}/super_repack_info.txt"
        [ "${VIRTUAL_AB:-false}" = "true" ] && is_virtual_ab=true
    fi

    # Detect empty partitions and separate them from partitions to unpack
    local all_partitions=()
    local partitions_to_unpack=()
    local empty_partitions=()

    while IFS= read -r item; do
        all_partitions+=("$item")
        local part_img="${logical_dir}/${item}.img"
        if is_empty_partition "$part_img"; then
            empty_partitions+=("$item")
            echo "$item" >> "$empty_partitions_file"
            # Don't spam individual messages - will show summary below
        else
            partitions_to_unpack+=("$item")
        fi
    done < <(find "$logical_dir" -maxdepth 1 -type f -name '*.img' ! -name 'super.raw.img' -exec basename {} .img \;)

    # Add all partitions (including empty ones) to partition_list.txt for tracking
    for part_name in "${all_partitions[@]}"; do
        echo "$part_name" >> "$partition_list_file"
    done

    local total=${#partitions_to_unpack[@]}
    local empty_count=${#empty_partitions[@]}
    local current=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local all_successful=true

    # Show concise message about empty partitions
    if [ "$empty_count" -gt 0 ]; then
        if [ "$is_virtual_ab" = true ]; then
            echo -e "${BLUE}Detected virtual A/B layout with ${BOLD}${empty_count}${RESET} empty slot partitions (normal for virtual-AB).${RESET}\n"
        else
            echo -e "${BLUE}Found ${BOLD}${empty_count}${RESET} empty partition(s). They will be skipped during unpack and recreated during repack.${RESET}\n"
        fi
    fi

    if [ "$total" -eq 0 ]; then
        echo -e "\n${YELLOW}No non-empty partitions to unpack.${RESET}"
    else
        echo -e "${BLUE}--- Extracting content from logical partitions ---${RESET}"
        for part_name in "${partitions_to_unpack[@]}"; do
            current=$((current + 1))
            local spin=0

            # Run the unpack in the background so we can show a spinner
            # We redirect output to /dev/null because we only care about success or failure.
            local quiet_flag=""
            [ "$quiet_mode" = true ] && quiet_flag="--quiet"
            bash "$UNPACK_SCRIPT_PATH" "${logical_dir}/${part_name}.img" "${extracted_dir}/${part_name}" --no-banner $quiet_flag >/dev/null 2>&1 &
            local pid=$!

            while kill -0 $pid 2>/dev/null; do
                echo -ne "\r\033[K${YELLOW}(${current}/${total}) Extracting: ${BOLD}${part_name}${RESET}... ${spinner[$((spin++ % 10))]}"
                sleep 0.1
            done

            wait $pid
            if [ $? -ne 0 ]; then
                echo -e "\r\033[K${RED}(${current}/${total}) FAILED to extract: ${BOLD}${part_name}${RESET} [✗]"
                all_successful=false
                break
            else
                echo -e "\r\033[K${GREEN}(${current}/${total}) Extracted: ${BOLD}${part_name}${RESET} [✓]"
            fi
        done
    fi

    if [ "$all_successful" = false ]; then
        trap 'cleanup_and_exit' INT TERM EXIT
        read -rp $'\nPress Enter to return...'
        return
    fi

    local logical_size
    logical_size=$(du -sh "$logical_dir" | awk '{print $1}')
    echo -e "\n${BLUE}The intermediate logical partitions (${logical_size}) can be removed to save space.${RESET}"
    select_option "Delete intermediate logical partitions?" "Yes (Recommended)" "No (Keep for reference)" --no-clear

    if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
        rm -rf "$logical_dir"
        echo -e "\n${GREEN}[✓] Intermediate files removed.${RESET}"
    fi

    trap 'cleanup_and_exit' INT TERM EXIT
    echo -e "\n${GREEN}${BOLD}Super unpack successful!${RESET}"
    echo -e "  - Project created at: ${BOLD}${project_dir}${RESET}"
    local total_partitions=$((${#partitions_to_unpack[@]} + ${#empty_partitions[@]}))
    echo -e "  - Total Partitions: ${BOLD}${total_partitions}${RESET} (${#partitions_to_unpack[@]} extracted, ${#empty_partitions[@]} empty)"
    if [ ${#empty_partitions[@]} -gt 0 ]; then
        echo -e "  - Empty Partitions: ${YELLOW}${empty_partitions[*]}${RESET}"
    fi
    read -rp $'\nPress Enter to return...'
}

run_super_create_config_interactive() {

    local project_dir metadata_dir final_config_file

    select_item "Select project to finalize configuration:" "SUPER_TOOLS" "dir"
    if [ $? -ne 0 ]; then return; fi
    project_dir="$AIT_SELECTED_ITEM"

    metadata_dir="${project_dir}/.metadata"
    final_config_file="${project_dir}/project.conf"

    if [ ! -f "${metadata_dir}/partition_list.txt" ] || [ ! -f "${metadata_dir}/super_repack_info.txt" ]; then
        echo -e "\n${RED}Error: Core metadata is missing for this project. Cannot configure.${RESET}"; sleep 2; return
    fi

    local partition_list
    readarray -t partition_list < "${metadata_dir}/partition_list.txt"

    # Read empty partitions list if it exists
    local empty_partitions_file="${metadata_dir}/empty_partitions.txt"
    local empty_partitions=()
    read_empty_partitions "$empty_partitions_file" empty_partitions

    # Build associative array for O(1) lookup
    local -A empty_map
    for empty_part in "${empty_partitions[@]}"; do
        empty_map["$empty_part"]=1
    done

    # Filter out empty partitions from configuration
    local partitions_to_configure=()
    for part_name in "${partition_list[@]}"; do
        [ -z "${empty_map[$part_name]}" ] && partitions_to_configure+=("$part_name")
    done

    if [ ${#empty_partitions[@]} -gt 0 ]; then
        echo -e "\n${BLUE}Found ${BOLD}${#empty_partitions[@]}${RESET} empty partition(s): ${YELLOW}${empty_partitions[*]}${RESET}"
        echo -e "${BLUE}Empty partitions will be skipped during configuration (they don't need filesystem settings).${RESET}"
        read -rp $'\nPress Enter to continue...'
    fi

    declare -A config_lines

    local current_index=0
    while [ "$current_index" -lt "${#partitions_to_configure[@]}" ]; do
        local part_name=${partitions_to_configure[$current_index]}

        local mount_method=""
        load_metadata "${project_dir}/extracted_content/${part_name}/.repack_info/metadata.txt"
        mount_method="$MOUNT_METHOD"

        local fs
        clear; print_banner
        echo -e "\n${BOLD}Configuring partition ($((current_index + 1))/${#partitions_to_configure[@]}): [ ${YELLOW}$part_name${BOLD} ]${RESET}"

        if [ "$mount_method" == "fuse" ]; then
            echo -e "\n${YELLOW}Note: FUSE-unpack detected for '${part_name}', only EROFS is available.${RESET}"
            local menu_options=("EROFS (Forced due to FUSE unpack)")
            if [ "$current_index" -gt 0 ]; then menu_options+=("Back to previous partition"); fi
            select_option "Select filesystem for '${part_name}':" "${menu_options[@]}"

            if [ "$current_index" -gt 0 ] && [ "$AIT_CHOICE_INDEX" -eq 1 ]; then
                current_index=$((current_index - 1))
                continue
            fi
            fs="erofs"
        else
            local menu_options=("EROFS" "EXT4")
            if [ "$current_index" -gt 0 ]; then menu_options+=("Back to previous partition"); fi
            select_option "Select filesystem for '${part_name}':" "${menu_options[@]}"

            if [ "$current_index" -gt 0 ] && [ "$AIT_CHOICE_INDEX" -eq 2 ]; then
                current_index=$((current_index - 1))
                continue
            fi
            [ "$AIT_CHOICE_INDEX" -eq 0 ] && fs="erofs" || fs="ext4"
        fi
        config_lines["${part_name^^}_FS"]="$fs"

        unset "config_lines[${part_name^^}_EROFS_COMPRESSION]" "config_lines[${part_name^^}_EROFS_LEVEL]" "config_lines[${part_name^^}_EXT4_MODE]" "config_lines[${part_name^^}_EXT4_OVERHEAD_TYPE]" "config_lines[${part_name^^}_EXT4_OVERHEAD_VAL]"

        while true; do
            clear; print_banner
            echo -e "\n${BOLD}Configuring partition ($((current_index + 1))/${#partitions_to_configure[@]}): [ ${YELLOW}$part_name${BOLD} ]${RESET}"
            echo -e "  - Filesystem: ${GREEN}${fs}${RESET}"

            if [ "$fs" == "erofs" ]; then
                select_option "Select EROFS compression:" "none" "lz4" "lz4hc" "deflate" "Back"
                if [ "$AIT_CHOICE_INDEX" -eq 4 ]; then break; fi
                local erofs_comp_options=("none" "lz4" "lz4hc" "deflate")
                local erofs_comp=${erofs_comp_options[$AIT_CHOICE_INDEX]}
                config_lines["${part_name^^}_EROFS_COMPRESSION"]="$erofs_comp"
                if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then
                    read -rp "$(echo -e ${BLUE}"Enter level for ${erofs_comp} (lz4hc 0-12, deflate 0-9): "${RESET})" erofs_level
                    erofs_level="$(echo "$erofs_level" | tr -d "\"'")"
                    config_lines["${part_name^^}_EROFS_LEVEL"]="$erofs_level"
                fi
                current_index=$((current_index + 1)); break

            else # EXT4
                select_option "Select EXT4 repack mode:" "Flexible (auto-resize)" "Strict" "Back"
                if [ "$AIT_CHOICE_INDEX" -eq 2 ]; then break; fi
                local ext4_mode
                if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
                    ext4_mode="flexible"
                    config_lines["${part_name^^}_EXT4_MODE"]="$ext4_mode"
                    select_option "Select Flexible Overhead:" "Minimal (10%)" "Standard (15%)" "Generous (20%)" "Custom"
                    local overhead_percent
                    case $AIT_CHOICE_INDEX in
                        0) overhead_percent=10 ;;
                        2) overhead_percent=20 ;;
                        3) read -rp "$(echo -e ${BLUE}"Enter custom percentage: "${RESET})" overhead_percent; overhead_percent="$(echo "$overhead_percent" | tr -d "\"'")" ;;
                        *) overhead_percent=15 ;;
                    esac
                    config_lines["${part_name^^}_EXT4_OVERHEAD_PERCENT"]="${overhead_percent:-15}"
                else
                    ext4_mode="strict"
                    config_lines["${part_name^^}_EXT4_MODE"]="$ext4_mode"
                fi
                current_index=$((current_index + 1)); break
            fi
        done
    done

    clear; print_banner
    echo -e "\n${BOLD}Final Configuration Step${RESET}"
    select_option "Enable detailed, real-time logs during super repack?" \
        "Yes (Recommended for debugging)" \
        "No (Show a clean spinner)"

    local enable_verbose_logs="false"
    if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
        enable_verbose_logs="true"
    fi

    select_option "Create a flashable sparse image?" "Yes (Recommended)" "No (Raw Image)"

    local create_sparse_image="true"
    if [ "$AIT_CHOICE_INDEX" -eq 1 ]; then
        create_sparse_image="false"
    fi

    {
        echo "# --- Universal Repack Configuration ---"
        echo "# Project: $(basename "$project_dir")"
        echo "# Generated on $(date)"
        echo "# WARNING: Do NOT edit this file manually unless you know what you are doing."
        echo ""
        echo "# --- Repack Behavior Settings ---"
        echo "ENABLE_VERBOSE_LOGS=${enable_verbose_logs}"
        echo "CREATE_SPARSE_IMAGE=${create_sparse_image}"
        echo ""
        echo "# --- Super Partition Metadata ---"
        grep -v -E '^(#|$)' "${metadata_dir}/super_repack_info.txt"
        echo ""
        echo "# --- Logical Partition Repack Settings ---"
        echo "PARTITION_LIST=\"${partition_list[*]}\""
        echo ""

    # Write filesystem config only for non-empty partitions that were configured
    for part_name in "${partitions_to_configure[@]}"; do
        echo "# Settings for ${part_name}"
        echo "${part_name^^}_FS=\"${config_lines[${part_name^^}_FS]}\""
        if [ "${config_lines[${part_name^^}_FS]}" == "erofs" ]; then
            echo "${part_name^^}_EROFS_COMPRESSION=\"${config_lines[${part_name^^}_EROFS_COMPRESSION]}\""
            if [ -n "${config_lines[${part_name^^}_EROFS_LEVEL]}" ]; then echo "${part_name^^}_EROFS_LEVEL=\"${config_lines[${part_name^^}_EROFS_LEVEL]}\""; fi
        else
            echo "${part_name^^}_EXT4_MODE=\"${config_lines[${part_name^^}_EXT4_MODE]}\""
            if [ "${config_lines[${part_name^^}_EXT4_MODE]}" == "flexible" ]; then
                echo "${part_name^^}_EXT4_OVERHEAD_PERCENT=\"${config_lines[${part_name^^}_EXT4_OVERHEAD_PERCENT]}\""
            fi
        fi
        echo ""
    done

    # Add comment for empty partitions if any exist
    if [ ${#empty_partitions[@]} -gt 0 ]; then
        echo "# Empty partitions (will be recreated as empty files during repack):"
        for empty_part in "${empty_partitions[@]}"; do
            echo "#   - ${empty_part}"
        done
        echo ""
    fi
    } > "$final_config_file"

    # Strip <none> values from config file (replace =<none> with =)
    sed -i 's/=<none>$/=/' "$final_config_file"

    echo -e "\n${GREEN}${BOLD}[✓] Universal repack configuration saved to: ${RESET}${final_config_file}"
    read -rp $'\nPress Enter to return...'
}

run_super_repack_interactive() {

    local quiet_mode="$1"
    local project_dir metadata_dir part_config_file logical_dir extracted_dir

    select_item "Select project to repack:" "SUPER_TOOLS" "dir"
    if [ $? -ne 0 ]; then return; fi
    project_dir="$AIT_SELECTED_ITEM"

    metadata_dir="${project_dir}/.metadata"
    logical_dir="${project_dir}/logical_partitions"
    extracted_dir="${project_dir}/extracted_content"
    part_config_file="${project_dir}/project.conf"

    if [ ! -f "$part_config_file" ]; then
        echo -e "\n${RED}Error: Universal 'project.conf' not found!${RESET}"
        echo -e "Please run 'Finalize Project Configuration' for this project first."
        sleep 3; return
    fi

    source "$part_config_file"

    clear; print_banner
    local default_output_image="$SCRIPT_DIR/REPACKED_IMAGES/super_$(basename "$project_dir").img"
    read -rp "$(echo -e ${BLUE}"Enter path for final super image [${BOLD}${default_output_image}${BLUE}]: "${RESET})" output_image
    output_image="$(echo "$output_image" | tr -d "\"'")"
    output_image=${output_image:-$default_output_image}

    local sparse_flag=""
    [ "${CREATE_SPARSE_IMAGE:-true}" = "false" ] && sparse_flag="--raw"

    clear; print_banner

    echo -e "\n${RED}${BOLD}Starting full super repack. This will take a long time...${RESET}"
    trap '' INT
    set -e

    mkdir -p "$logical_dir"

    # Read empty partitions list if it exists
    local empty_partitions_file="${metadata_dir}/empty_partitions.txt"
    local empty_partitions=()
    read_empty_partitions "$empty_partitions_file" empty_partitions

    # Build associative array for O(1) lookup
    local -A empty_map
    for empty_part in "${empty_partitions[@]}"; do
        empty_map["$empty_part"]=1
    done

    set +e # Disable exit on error for the loop
    # Filter out empty partitions from PARTITION_LIST for repacking
    local partitions_to_repack=()
    for part_name in $PARTITION_LIST; do
        [ -z "${empty_map[$part_name]}" ] && partitions_to_repack+=("$part_name")
    done

    local total=${#partitions_to_repack[@]}
    local empty_count=${#empty_partitions[@]}
    local current=0
    local all_successful=true

    if [ "$empty_count" -gt 0 ]; then
        echo -e "\n${BLUE}Found ${BOLD}${empty_count}${RESET} empty partition(s): ${YELLOW}${empty_partitions[*]}${RESET}"
        echo -e "${BLUE}Empty partitions will be recreated as empty files before final assembly.${RESET}"
    fi

    if [ "$total" -eq 0 ]; then
        echo -e "\n${YELLOW}No non-empty partitions to repack.${RESET}"
    else
        echo -e "\n${BLUE}--- Repacking content into logical partitions ---${RESET}"

        for part_name in "${partitions_to_repack[@]}"; do
        current=$((current + 1))
        local fs_var="${part_name^^}_FS"; local fs="${!fs_var}"

        if [ -z "$fs" ]; then
            echo -e "\n${RED}${BOLD}ERROR: Filesystem not configured for partition '${part_name}'.${RESET}"
            echo -e "${RED}${BOLD}Please run 'Finalize Project Configuration' for this project.${RESET}"
            all_successful=false
            break
        fi

        # Check mount_method to prevent FUSE + EXT4 incompatibility
        local mount_method=""
        load_metadata "${project_dir}/extracted_content/${part_name}/.repack_info/metadata.txt"
        mount_method="${MOUNT_METHOD}"
        if [ "$mount_method" == "fuse" ] && [ "$fs" == "ext4" ]; then
            echo -e "\n${RED}${BOLD}ERROR: FUSE-based unpacking detected for partition '${part_name}'.${RESET}"
            echo -e "${RED}${BOLD}Repacking as EXT4 is not supported for images unpacked with FUSE.${RESET}"
            echo -e "${RED}${BOLD}Please re-run 'Finalize Project Configuration' or edit 'project.conf'.${RESET}"
            all_successful=false
            break
        fi

        local repack_args=("--fs" "$fs")
        if [ "$fs" == "erofs" ]; then
            local comp_var="${part_name^^}_EROFS_COMPRESSION"; local level_var="${part_name^^}_EROFS_LEVEL"
            [ -n "${!comp_var}" ] && repack_args+=("--erofs-compression" "${!comp_var}")
            [ -n "${!level_var}" ] && repack_args+=("--erofs-level" "${!level_var}")
        else
            local mode_var="${part_name^^}_EXT4_MODE"; [ -n "${!mode_var}" ] && repack_args+=("--ext4-mode" "${!mode_var}")
            if [ "${!mode_var}" == "flexible" ]; then
                local percent_var="${part_name^^}_EXT4_OVERHEAD_PERCENT"
                repack_args+=("--ext4-overhead-percent" "${!percent_var}")
            fi
        fi

        # Use project config ENABLE_VERBOSE_LOGS first, then fallback to command line quiet_mode
        local use_verbose_logs="${ENABLE_VERBOSE_LOGS:-false}"
        if [ "$use_verbose_logs" != "true" ] && [ "$quiet_mode" = true ]; then
            use_verbose_logs="false"
        fi

        if [ "$use_verbose_logs" == "true" ]; then
            # --- VERBOSE LOGGING PATH ---
            echo -e "\n${YELLOW}--- (${current}/${total}) Repacking: ${BOLD}${part_name}${RESET} ---${RESET}"
            bash "$REPACK_SCRIPT_PATH" "${project_dir}/extracted_content/${part_name}" "${logical_dir}/${part_name}.img" "${repack_args[@]}" --no-banner

            if [ $? -ne 0 ]; then
                echo -e "${RED}--- [✗] FAILED: ${BOLD}${part_name}${RESET} repack failed. See logs above. ---${RESET}"
                all_successful=false
                break
            else
                echo -e "${GREEN}--- [✓] Success: ${BOLD}${part_name}${RESET} repacked ---${RESET}"
            fi
        else
            # --- SILENT SPINNER PATH ---
            bash "$REPACK_SCRIPT_PATH" "${project_dir}/extracted_content/${part_name}" "${logical_dir}/${part_name}.img" "${repack_args[@]}" --no-banner >/dev/null 2>&1 &
            local pid=$!
            local spin=0
            local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )

            while kill -0 $pid 2>/dev/null; do
                echo -ne "\r\033[K${YELLOW}(${current}/${total}) Repacking: ${BOLD}${part_name}${RESET}... ${spinner[$((spin++ % 10))]}"
                sleep 0.1
            done

            wait $pid
            if [ $? -ne 0 ]; then
                echo -e "\r\033[K${RED}(${current}/${total}) FAILED to repack: ${BOLD}${part_name}${RESET} [✗]"
                all_successful=false
                break
            else
                echo -e "\r\033[K${GREEN}(${current}/${total}) Repacked:  ${BOLD}${part_name}${RESET} [✓]"
            fi
        fi
        done
    fi

    if [ "$all_successful" = false ]; then
        trap 'cleanup_and_exit' INT TERM EXIT
        read -rp $'\nPress Enter to return...'
        return
    fi

    # Create empty partition files before final assembly
    # Create 0-byte files - super-tools.sh will handle them correctly:
    # - For virtual-ab images: kept as 0 bytes
    # - For non-virtual-ab images: allocated at least 4096 bytes in lpmake
    if [ "$empty_count" -gt 0 ]; then
        echo -e "\n${BLUE}--- Creating empty partition files ---${RESET}"
        for empty_part in "${empty_partitions[@]}"; do
            # Create 0-byte file (handled appropriately by super-tools.sh based on virtual-ab flag)
            touch "${logical_dir}/${empty_part}.img"
            echo -e "${GREEN}[✓] Created empty file: ${BOLD}${empty_part}.img${RESET}"
        done
    fi

    echo -e "\n${BLUE}--- Assembling final super image ---${RESET}"

    # Keep set +e active to allow error checking
    bash "$SUPER_SCRIPT_PATH" repack "$logical_dir" "$output_image" "$sparse_flag" --no-banner
    local repack_exit_code=$?

    # Check the exit code explicitly
    if [ $repack_exit_code -ne 0 ]; then
        echo -e "\n${RED}${BOLD}FATAL: Failed to assemble the final super image. Please check the errors above.${RESET}"
        # Restore the original trap and exit
        trap 'cleanup_and_exit' INT TERM EXIT
        read -rp $'\nPress Enter to return...'
        return
    fi

    rm -rf "$logical_dir"
    trap 'cleanup_and_exit' INT TERM EXIT

    # Transfer ownership to actual user
    [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$output_image"

    echo -e "\n${GREEN}${BOLD}Super repack successful!${RESET}"
    echo -e "  - Final image: ${BOLD}$output_image${RESET}"
    display_final_image_size "$output_image"
    read -rp $'\nPress Enter to return...'
}

run_super_kitchen_menu() {
    while true; do
        clear; print_banner
        local kitchen_options=("Unpack a Super Image" "Finalize Project Configuration" "Repack a Project from Configuration" "Back to Main Menu")
        select_option "Super Image Kitchen:" "${kitchen_options[@]}"

        case $AIT_CHOICE_INDEX in
            0) run_super_unpack_interactive "$QUIET_MODE" ;;
            1) run_super_create_config_interactive ;;
            2) run_super_repack_interactive "$QUIET_MODE" ;;
            3) break ;;
        esac
    done
}

run_advanced_tools_menu() {
    while true; do
        clear; print_banner
        local advanced_options=("Super Image Kitchen" "Back to Main Menu")
        select_option "Advanced Tools:" "${advanced_options[@]}"

        case $AIT_CHOICE_INDEX in
            0) run_super_kitchen_menu ;;
            1) break ;;
        esac
    done
}

run_non_interactive() {
    set -e
    local config_file="$1"
    local quiet_mode="${2:-false}"
    echo -e "\n${BLUE}Running non-interactive with: ${BOLD}$config_file${RESET}"
    declare -A CONFIG
    while IFS='=' read -r key value; do if [[ ! "$key" =~ ^\# && -n "$key" ]]; then CONFIG["$key"]="$value"; fi; done < "$config_file"
    ACTION="${CONFIG[ACTION]}"
    if [ -z "$ACTION" ]; then echo -e "${RED}Error: 'ACTION' not defined.${RESET}"; exit 1; fi
    trap '' INT TERM EXIT

    if [ "$ACTION" == "unpack" ]; then
        local input_image="${CONFIG[INPUT_IMAGE]}"; local extract_dir="${CONFIG[EXTRACT_DIR]}"
        if [[ "$input_image" != /* ]]; then input_image="$SCRIPT_DIR/INPUT_IMAGES/$input_image"; fi
        if [[ "$extract_dir" != /* ]]; then extract_dir="$SCRIPT_DIR/EXTRACTED_IMAGES/$extract_dir"; fi
        if [ -z "$input_image" ] || [ -z "$extract_dir" ]; then echo -e "${RED}Error: INPUT_IMAGE/EXTRACT_DIR not set.${RESET}"; exit 1; fi

        echo -e "\n${BOLD}Unpack Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Output Directory:${RESET} $extract_dir"
        local quiet_flag=""
        [ "$quiet_mode" = true ] && quiet_flag="--quiet"
        echo -e "\n${RED}${BOLD}Starting unpack. DO NOT INTERRUPT...${RESET}\n"; bash "$UNPACK_SCRIPT_PATH" "$input_image" "$extract_dir" --no-banner $quiet_flag
        echo -e "\n${GREEN}${BOLD}Success: Image unpacked to $extract_dir${RESET}"

    elif [ "$ACTION" == "repack" ]; then
        local source_dir="${CONFIG[SOURCE_DIR]}"; local output_image="${CONFIG[OUTPUT_IMAGE]}"; local fs="${CONFIG[FILESYSTEM]}"
        if [[ "$source_dir" != /* ]]; then source_dir="$SCRIPT_DIR/EXTRACTED_IMAGES/$source_dir"; fi
        if [[ "$output_image" != /* ]]; then output_image="$SCRIPT_DIR/REPACKED_IMAGES/$output_image"; fi
        if [ -z "$source_dir" ] || [ -z "$output_image" ] || [ -z "$fs" ]; then echo -e "${RED}Error: SOURCE_DIR/OUTPUT_IMAGE/FILESYSTEM not set.${RESET}"; exit 1; fi

        local mount_method=""
        load_metadata "${source_dir}/.repack_info/metadata.txt"
        mount_method="${MOUNT_METHOD}"
        if [ "$mount_method" == "fuse" ] && [ "$fs" == "ext4" ]; then
            echo -e "\n${RED}${BOLD}ERROR: FUSE-based unpacking detected for '${source_dir}'.${RESET}" >&2
            echo -e "${RED}${BOLD}Repacking as EXT4 is not supported for images unpacked with FUSE.${RESET}" >&2
            echo -e "${RED}${BOLD}Please change FILESYSTEM to 'erofs' in your config file.${RESET}" >&2
            exit 1
        fi
        local repack_args=("--fs" "$fs"); local create_sparse="${CONFIG[CREATE_SPARSE_IMAGE]:-true}"; local erofs_comp="${CONFIG[COMPRESSION_MODE]}"; local erofs_level="${CONFIG[COMPRESSION_LEVEL]}"; local ext4_mode="${CONFIG[MODE]}"

        echo -e "\n${BOLD}Repack Summary:${RESET}\n  - ${YELLOW}Source Directory:${RESET} $source_dir\n  - ${YELLOW}Output Image:${RESET}     $output_image\n  - ${YELLOW}Filesystem:${RESET}       $fs"
        if [ "$fs" == "erofs" ]; then
            [ -n "$erofs_comp" ] && repack_args+=("--erofs-compression" "$erofs_comp"); [ -n "$erofs_level" ] && repack_args+=("--erofs-level" "$erofs_level")
            echo -e "  - ${YELLOW}EROFS Compression:${RESET}  ${erofs_comp:-none}"
        else
            [ -n "$ext4_mode" ] && repack_args+=("--ext4-mode" "$ext4_mode")
            echo -e "  - ${YELLOW}EXT4 Mode:${RESET}        ${ext4_mode:-strict}"
            if [ "$ext4_mode" == "flexible" ]; then
                local overhead_percent="${CONFIG[EXT4_OVERHEAD_PERCENT]:-5}"
                repack_args+=("--ext4-overhead-percent" "$overhead_percent")
                echo -e "  - ${YELLOW}EXT4 Overhead:${RESET}      ${overhead_percent}%"
            fi
        fi
        echo -e "  - ${YELLOW}Create Sparse IMG:${RESET}  $create_sparse"

        echo -e "\n${RED}${BOLD}Starting repack. DO NOT INTERRUPT...${RESET}";
        local quiet_flag=""
        [ "$quiet_mode" = true ] && quiet_flag="--quiet"
        bash "$REPACK_SCRIPT_PATH" "$source_dir" "$output_image" "${repack_args[@]}" --no-banner $quiet_flag

        local final_image_path="$output_image"
        if [ -f "$output_image" ]; then
            if [ "$create_sparse" == "true" ]; then
                local sparse_output="${output_image%.img}.sparse.img"; echo -e "\n${BLUE}Creating sparse image...${RESET}"; img2simg "$output_image" "$sparse_output"; rm -f "$output_image"; final_image_path="$sparse_output"
            fi
            # Transfer ownership to actual user
            [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$final_image_path"
            echo -e "\n${GREEN}${BOLD}Success: Final image created at: ${final_image_path}${RESET}"
            display_final_image_size "$final_image_path"
        else
            echo -e "\n${RED}${BOLD}Repack failed.${RESET}"
        fi

    # --- NEW: Non-interactive super unpack ---
    elif [ "$ACTION" == "super_unpack" ]; then
        local input_image="${CONFIG[INPUT_IMAGE]}"
        local project_name="${CONFIG[PROJECT_NAME]}"
        if [[ "$input_image" != /* ]]; then input_image="$SCRIPT_DIR/INPUT_IMAGES/$input_image"; fi
        if [ -z "$input_image" ] || [ -z "$project_name" ]; then echo -e "${RED}Error: INPUT_IMAGE/PROJECT_NAME not set.${RESET}"; exit 1; fi

        local project_dir="$SCRIPT_DIR/SUPER_TOOLS/$project_name"
        if [ -d "$project_dir" ]; then echo -e "${RED}Error: Project '$project_name' already exists.${RESET}"; exit 1; fi

        echo -e "\n${BOLD}Super Unpack Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Project Name:${RESET} $project_name"
        echo -e "\n${RED}${BOLD}Starting super unpack...${RESET}"

        # Mirror the interactive logic
        mkdir -p "$project_dir/.metadata" "$project_dir/logical_partitions" "$project_dir/extracted_content"
        bash "$SUPER_SCRIPT_PATH" unpack "$input_image" "$project_dir/logical_partitions" --no-banner &>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "${RED}${BOLD}Error: Failed to unpack super image.${RESET}" >&2
            exit 1
        fi

        local metadata_dir="$project_dir/.metadata"
        local partition_list_file="${metadata_dir}/partition_list.txt"
        local empty_partitions_file="${metadata_dir}/empty_partitions.txt"
        touch "$partition_list_file" "$empty_partitions_file"

        # Collect all partition images first (avoid subshell issues)
        local all_partition_images=()
        while IFS= read -r logical_img; do
            all_partition_images+=("$logical_img")
        done < <(find "$project_dir/logical_partitions" -maxdepth 1 -type f -name '*.img' ! -name 'super.raw.img')

        # Check if this is a virtual-AB image
        local is_virtual_ab=false
        if [ -f "${metadata_dir}/super_repack_info.txt" ]; then
            load_metadata "${metadata_dir}/super_repack_info.txt"
            [ "${VIRTUAL_AB:-false}" = "true" ] && is_virtual_ab=true
        fi

        # Detect empty partitions and separate them
        local empty_count=0
        for logical_img in "${all_partition_images[@]}"; do
            local part_name
            part_name=$(basename "$logical_img" .img)
            echo "$part_name" >> "$partition_list_file"

            if is_empty_partition "$logical_img"; then
                echo "$part_name" >> "$empty_partitions_file"
                empty_count=$((empty_count + 1))
            else
                echo -e "--- Unpacking logical partition: ${part_name} ---"
                local quiet_flag=""
                [ "$quiet_mode" = true ] && quiet_flag="--quiet"
                bash "$UNPACK_SCRIPT_PATH" "$logical_img" "$project_dir/extracted_content/${part_name}" --no-banner $quiet_flag &>/dev/null
                if [ $? -ne 0 ]; then
                    echo -e "${RED}${BOLD}Error: Failed to unpack partition '${part_name}'.${RESET}" >&2
                    rm -rf "$project_dir/logical_partitions"
                    exit 1
                fi
            fi
        done

        # Show concise message about empty partitions
        if [ "$empty_count" -gt 0 ]; then
            if [ "$is_virtual_ab" = true ]; then
                echo -e "${BLUE}Detected virtual A/B layout with ${BOLD}${empty_count}${RESET} empty slot partitions (normal for virtual-AB).${RESET}"
            else
                echo -e "${BLUE}Found ${BOLD}${empty_count}${RESET} empty partition(s). They will be skipped during unpack and recreated during repack.${RESET}"
            fi
        fi
        rm -rf "$project_dir/logical_partitions"
        echo -e "\n${GREEN}${BOLD}Success: Super image unpacked to $project_dir${RESET}"

    # --- Non-interactive super repack ---
    elif [ "$ACTION" == "super_repack" ]; then
        local project_name="${CONFIG[PROJECT_NAME]}"; local output_image="${CONFIG[OUTPUT_IMAGE]}"
        if [[ "$output_image" != /* ]]; then output_image="$SCRIPT_DIR/REPACKED_IMAGES/$output_image"; fi
        if [ -z "$project_name" ] || [ -z "$output_image" ]; then echo -e "${RED}Error: PROJECT_NAME/OUTPUT_IMAGE not set.${RESET}"; exit 1; fi
        local project_dir="$SCRIPT_DIR/SUPER_TOOLS/$project_name"; local final_config_file="${project_dir}/project.conf"
        if [ ! -f "$final_config_file" ]; then echo -e "${RED}Error: 'project.conf' not found in '$project_dir'.${RESET}"; exit 1; fi

        source "$final_config_file"
        echo -e "\n${BOLD}Super Repack Summary:${RESET}\n  - ${YELLOW}Project:${RESET} $project_name\n  - ${YELLOW}Output Image:${RESET} $output_image"
        echo -e "\n${RED}${BOLD}Starting super repack...${RESET}"

        local logical_dir="${project_dir}/logical_partitions"
        local metadata_dir="${project_dir}/.metadata"
        mkdir -p "$logical_dir"

        # Read empty partitions list if it exists
        local empty_partitions_file="${metadata_dir}/empty_partitions.txt"
        local empty_partitions=()
        read_empty_partitions "$empty_partitions_file" empty_partitions

        # Build associative array for O(1) lookup
        local -A empty_map
        for empty_part in "${empty_partitions[@]}"; do
            empty_map["$empty_part"]=1
        done

        # Filter out empty partitions and repack only non-empty ones
        local repack_failed=false
        for part_name in $PARTITION_LIST; do
            [ -n "${empty_map[$part_name]}" ] && continue

            local fs_var="${part_name^^}_FS"; local fs="${!fs_var}"

            if [ -z "$fs" ]; then
                echo -e "\n${RED}${BOLD}ERROR: Filesystem not configured for partition '${part_name}'.${RESET}" >&2
                echo -e "${RED}${BOLD}Please run 'Finalize Project Configuration' for this project.${RESET}" >&2
                exit 1
            fi

            local mount_method=""
            load_metadata "$project_dir/extracted_content/${part_name}/.repack_info/metadata.txt"
            mount_method="$MOUNT_METHOD"
            if [ "$mount_method" == "fuse" ] && [ "$fs" == "ext4" ]; then
                echo -e "\n${RED}${BOLD}ERROR: FUSE-based unpacking detected for partition '${part_name}'.${RESET}" >&2
                echo -e "${RED}${BOLD}Repacking as EXT4 is not supported for images unpacked with FUSE.${RESET}" >&2
                echo -e "${RED}${BOLD}Please re-run 'Finalize Project Configuration' or edit 'project.conf'.${RESET}" >&2
                exit 1
            fi

            echo "--- Repacking logical partition: ${part_name} ---"
            local repack_args=("--fs" "$fs")
            if [ "$fs" == "erofs" ]; then
                local comp_var="${part_name^^}_EROFS_COMPRESSION"; local level_var="${part_name^^}_EROFS_LEVEL"
                [ -n "${!comp_var}" ] && repack_args+=("--erofs-compression" "${!comp_var}"); [ -n "${!level_var}" ] && repack_args+=("--erofs-level" "${!level_var}")
            else
                local mode_var="${part_name^^}_EXT4_MODE"; [ -n "${!mode_var}" ] && repack_args+=("--ext4-mode" "${!mode_var}")
                if [ "${!mode_var}" == "flexible" ]; then
                    local percent_var="${part_name^^}_EXT4_OVERHEAD_PERCENT"
                    repack_args+=("--ext4-overhead-percent" "${!percent_var}")
                fi
            fi

            # Use project config ENABLE_VERBOSE_LOGS first, then fallback to command line quiet_mode
            local use_verbose_logs="${ENABLE_VERBOSE_LOGS:-false}"
            if [ "$use_verbose_logs" != "true" ] && [ "$quiet_mode" = true ]; then
                use_verbose_logs="false"
            fi

            local quiet_flag=""
            [ "$quiet_mode" = true ] && quiet_flag="--quiet"

            if [ "$use_verbose_logs" == "true" ]; then
                # Verbose mode: show output
                echo -e "\n${YELLOW}--- Repacking: ${BOLD}${part_name}${RESET} ---${RESET}"
                bash "$REPACK_SCRIPT_PATH" "$project_dir/extracted_content/${part_name}" "$logical_dir/${part_name}.img" "${repack_args[@]}" --no-banner $quiet_flag
            else
                # Quiet mode: suppress output
                bash "$REPACK_SCRIPT_PATH" "$project_dir/extracted_content/${part_name}" "$logical_dir/${part_name}.img" "${repack_args[@]}" --no-banner $quiet_flag &>/dev/null
            fi

            if [ $? -ne 0 ]; then
                if [ "$use_verbose_logs" == "true" ]; then
                    echo -e "${RED}--- [✗] FAILED: ${BOLD}${part_name}${RESET} repack failed. See logs above. ---${RESET}" >&2
                else
                    echo -e "${RED}${BOLD}ERROR: Failed to repack partition '${part_name}'.${RESET}" >&2
                fi
                repack_failed=true
                break
            fi
        done

        if [ "$repack_failed" = true ]; then
            rm -rf "$logical_dir"
            exit 1
        fi

        # Create empty partition files before final assembly
        # Create 0-byte files - super-tools.sh will handle them correctly:
        # - For virtual-ab images: kept as 0 bytes
        # - For non-virtual-ab images: allocated at least 4096 bytes in lpmake
        if [ ${#empty_partitions[@]} -gt 0 ]; then
            echo "--- Creating empty partition files ---"
            for empty_part in "${empty_partitions[@]}"; do
                # Create 0-byte file (handled appropriately by super-tools.sh based on virtual-ab flag)
                touch "${logical_dir}/${empty_part}.img"
            done
        fi

        echo "--- Assembling final super image ---"
        local sparse_flag=""; [ "${CONFIG[CREATE_SPARSE_IMAGE]}" == "false" ] && sparse_flag="--raw"
        bash "$SUPER_SCRIPT_PATH" repack "$logical_dir" "$output_image" "$sparse_flag" --no-banner &>/dev/null
        if [ $? -ne 0 ]; then
            echo -e "\n${RED}${BOLD}ERROR: Failed to assemble final super image.${RESET}" >&2
            rm -rf "$logical_dir"
            exit 1
        fi
        rm -rf "$logical_dir"

        # Transfer ownership to actual user
        [ -n "$SUDO_USER" ] && chown "$SUDO_USER:$SUDO_USER" "$output_image"

        echo -e "\n${GREEN}${BOLD}Success: Final image created at: ${output_image}${RESET}"
        display_final_image_size "$output_image"
    else
        echo -e "${RED}Error: Invalid ACTION '${ACTION}'.${RESET}"; exit 1
    fi
    exit 0
}

# --- Main Execution Logic ---
detect_os
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"; exit 1
fi

# Parse command line arguments
CONF_FILE=""
QUIET_MODE=false
UNKNOWN_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --conf=*)
            CONF_FILE="${1#*=}"
            shift
            ;;
        --quiet)
            QUIET_MODE=true
            shift
            ;;
        *)
            UNKNOWN_ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate arguments
if [ ${#UNKNOWN_ARGS[@]} -gt 0 ]; then
    echo -e "${RED}Error: Unknown argument(s): ${UNKNOWN_ARGS[*]}${RESET}" >&2
    print_usage
    exit 1
fi

# Determine mode
if [ -n "$CONF_FILE" ]; then
    # Non-interactive mode
    if [ ! -f "$CONF_FILE" ]; then
        echo -e "${RED}Error: Config file not found: '$CONF_FILE'${RESET}"; exit 1
    fi
    print_banner
    check_dependencies
    create_workspace
    run_non_interactive "$CONF_FILE" "$QUIET_MODE"
    exit 0
else
    # Interactive mode - continue to main menu
    :
fi

set +e
while true; do
    clear; print_banner
    if [ -z "$WORKSPACE_INITIALIZED" ]; then
        check_dependencies
        create_workspace
        WORKSPACE_INITIALIZED=true
    fi

    # Main Menu Reordered
    main_options=("Unpack an Android Image" "Repack a Directory" "Generate default.conf file" "Advanced Tools" "Cleanup Workspace" "Exit")
    select_option "Select an action:" "${main_options[@]}"; choice=$AIT_CHOICE_INDEX

    case $choice in
        0) run_unpack_interactive "$QUIET_MODE";;
        1) run_repack_interactive "$QUIET_MODE";;
        2) generate_config_file; read -rp $'\nPress Enter to continue...';;
        3) run_advanced_tools_menu;;
        4) cleanup_workspace;;
        5) break;;
    esac

done
