#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TOKEN=$1
PAGE=1
PER_PAGE=100
RKE_RELEASES_URL="https://api.github.com/repos/rancher/rke/releases"
RKE_DOWNLOAD_URL="https://github.com/rancher/rke/releases/download"
TARGET_VERSION=""
MATCHED_K8S_VERSION=""  # Global variable to store the matched Kubernetes version.
ALL_K8S_VERSIONS=""  # Global variable to store the list of K8S versions.
CLUSTER_CONFIG="$(pwd)/cluster.yml"
RKE_BINARY_SNAPSHOT=""  # Global variable to store the path to the RKE binary for snapshot operations.
RKE_BINARY_UPGRADE=""   # Global variable to store the path to the RKE binary for upgrade operations.
DATE_STR=$(date +"%Y%m%d%H%M%S")

trap 'echo -e "${RED}Script interrupted by user, exiting...${NC}"; exit' SIGINT

# Debugging: Output the current directory
echo -e "${GREEN}Current directory: $(pwd)${NC}"

# Debugging: List the contents of the current directory
echo -e "${GREEN}Contents of the current directory:${NC}"
ls -alh

check_and_prepare_requirements() {
    echo "Building cluster.rkestate..."

    # Debugging: Output the Kubernetes configuration
    echo -e "${GREEN}Running kubectl command to get the full-cluster-state configmap...${NC}"

    # Capture the output of kubectl
    KUBECTL_OUTPUT=$(kubectl -n kube-system get configmap full-cluster-state -o json)

    # Debugging: Output the result of kubectl command
    #echo -e "${GREEN}kubectl output: ${KUBECTL_OUTPUT}${NC}"

    # Try to parse the kubectl output with jq, but capture the output and errors separately
    PARSED_OUTPUT=$(echo "$KUBECTL_OUTPUT" | jq -r .data.\"full-cluster-state\" 2>&1)
    JQ_EXIT_STATUS=$?

    if [ $JQ_EXIT_STATUS -ne 0 ]; then
        echo -e "${RED}Failed to parse kubectl output with jq. Error: $PARSED_OUTPUT${NC}"
        echo "Waiting for a few seconds to read the error message..."
        sleep 2
        exit 1
    else
        # Check the permissions of the directory before attempting to write the file
        echo -e "${GREEN}Checking directory permissions:${NC}"
        ls -ld .

        echo "$PARSED_OUTPUT" | jq -r . > "$(pwd)/cluster.rkestate"
        # Check if the file was created successfully
        if [ ! -f "$(pwd)/cluster.rkestate" ]; then
            echo -e "${RED}Failed to create cluster.rkestate file. Please check the permissions and try again.${NC}"
            exit 1
        else
            echo -e "${GREEN}cluster.rkestate created successfully.${NC}"
            sleep 2
        fi
    fi

    # Check GitHub token
    if [[ -z "$TOKEN" ]]; then
        echo -e "${RED}GitHub token is missing. Please provide it as an argument.${NC}"
        exit 1
    fi

    # Check if cluster.yml exists and is a regular file
    if [ ! -f "$CLUSTER_CONFIG" ]; then
        if [ -d "$CLUSTER_CONFIG" ]; then
            echo -e "${RED}$CLUSTER_CONFIG is a directory but should be a file. Make sure you have passed it correctly to the docker run command and try again.${NC}"
        else
            echo -e "${RED}$CLUSTER_CONFIG is missing. Please ensure it's mounted correctly.${NC}"
        fi
        exit 1
    fi

    # Check if the kubeconfig exists
    local src_kubeconfig="$(pwd)/kubeconfig"
    if [ ! -f "$src_kubeconfig" ]; then
        echo -e "${RED}kubeconfig ($src_kubeconfig) is missing. Please ensure it's mounted correctly.${NC}"
        exit 1
    fi

    echo -e "${GREEN}Requirements checked and prepared successfully.${NC}"
}

prompt_rke_version() {
    dialog --title "Enter RKE Version" --yesno "Do you know the exact RKE version you want to use? If so, please enter it (example format : v1.4.6). If not, select 'No' to download using script" 10 60
    RESPONSE=$?
    clear

    if [ $RESPONSE -eq 0 ]; then
        RKE_VERSION=$(dialog --stdout --inputbox "Please enter the RKE version:" 10 60)
        clear
        if [[ -n "$RKE_VERSION" ]]; then
            if [[ $RKE_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${GREEN}Using provided RKE version: $RKE_VERSION${NC}"
                if download_rke $RKE_VERSION; then
                    return 0
                else
                    echo -e "${RED}Failed to download provided RKE version: $RKE_VERSION. Will try to search for RKE version...${NC}"
                    return 1
                fi
            else
                echo -e "${RED}The provided RKE version: $RKE_VERSION is not in the correct format. Will try to search for RKE version...${NC}"
                return 1
            fi
        fi
    fi
    return 1
}

IGNORE_DOCKER_VERSION="--ignore-docker-version"

ignore_docker_version() {
    echo -e "${YELLOW}Unsupported Docker version found. Automatically ignoring Docker version and continuing.${NC}"
    IGNORE_DOCKER_VERSION="--ignore-docker-version"
}

take_snapshot() {
    local snapshot_name="snapshot_$DATE_STR"
    echo "Taking etcd snapshot using configuration: $CLUSTER_CONFIG"
    echo -e "${YELLOW}Applying --ignore-docker-version flag to avoid Docker version issues.${NC}"
    $RKE_BINARY_SNAPSHOT etcd snapshot-save --config=$CLUSTER_CONFIG --name=$snapshot_name $IGNORE_DOCKER_VERSION

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to take snapshot even with --ignore-docker-version flag.${NC}"
        exit 1
    else
        echo -e "${GREEN}Snapshot taken successfully with name: $snapshot_name.${NC}"
    fi
}


get_server_version() {
    # Capture both stdout and stderr outputs
    SERVER_VERSION_OUTPUT=$(kubectl get nodes 2>&1 | awk 'NR==2 {print $NF}')
    COMMAND_EXIT_STATUS=$?

    # Check for errors in the output or a non-zero exit status
    if [[ $COMMAND_EXIT_STATUS -ne 0 || -z "$SERVER_VERSION_OUTPUT" || "$SERVER_VERSION_OUTPUT" == *"error"* || "$SERVER_VERSION_OUTPUT" == *"Error"* || "$SERVER_VERSION_OUTPUT" == *"unable to handle the request"* ]]; then
        echo -e "${RED}Failed to get Kubernetes server version. Please ensure kubectl is installed and configured properly.${NC}"
        # Optionally, print the error output for diagnostic purposes
        echo -e "${RED}Error from kubectl: $SERVER_VERSION_OUTPUT${NC}"
        exit 1
    fi
    # If we reach this point, the SERVER_VERSION_OUTPUT should be valid
    echo "$SERVER_VERSION_OUTPUT"
}

get_rke_releases() {
    local page=$1
    local response=$(curl -s -H "Authorization: token $TOKEN" "$RKE_RELEASES_URL?per_page=$PER_PAGE&page=$page")
    if [[ $response == *"API rate limit exceeded"* ]]; then
        echo -e "${RED}GitHub API rate limit exceeded. Please wait and try again later.${NC}"
        exit 1
    fi
    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        echo -e "${RED}Failed to parse the JSON response from the GitHub API.${NC}"
        echo "$response"
        exit 1
    fi
    echo "$response"
}

download_rke() {
    local rke_version=$1
    local url="$RKE_DOWNLOAD_URL/$rke_version/rke_linux-amd64"

    wget -O rke $url
    local response=$?

    if [ $response -eq 0 ]; then
        echo -e "${GREEN}Download successful for RKE version: $rke_version${NC}"
        chmod +x rke  # make the downloaded file executable
        return 0  # exit the function if the download is successful
    else
        echo -e "${RED}Error downloading RKE version: $rke_version${NC}"
        echo "Continuing the search for RKE version."
        return 1  # return non-zero in case of error
    fi
}

select_k8s_version() {
    echo "Fetching available K8S versions..."
    AVAILABLE_VERSIONS=("${FULL_K8S_VERSIONS[@]}")

    # Filter versions that are greater or equal to the current version, considering major and minor only
    GREATER_VERSIONS=()
    for version in "${AVAILABLE_VERSIONS[@]}"; do
        if [[ $(echo "$version" | cut -d'-' -f1) > "$SERVER_VERSION" || $(echo "$version" | cut -d'-' -f1) == "$SERVER_VERSION" ]]; then
            GREATER_VERSIONS+=("$version")
        fi
    done

    if [ ${#GREATER_VERSIONS[@]} -eq 0 ]; then
        echo -e "${RED}No available K8S versions for upgrade found.${NC}"
        echo "Press enter to return to the main menu."
        read _
        return 1
    fi

    # Dialog to select k8s version
    exec 3>&1
    TARGET_VERSION_INDEX=$(dialog --title "Select K8S version" --menu "Please choose the K8S version you want to upgrade to:" 15 60 4 $(for i in "${!GREATER_VERSIONS[@]}"; do echo "$i ${GREATER_VERSIONS[$i]}"; done) 2>&1 1>&3)
    TARGET_VERSION_EXIT_STATUS=$?
    exec 3>&-

    TARGET_VERSION=${GREATER_VERSIONS[$TARGET_VERSION_INDEX]}

    case $TARGET_VERSION_EXIT_STATUS in
        0)  # User selected a version
            clear
            ;;
        1)  # User selected "Cancel"
            clear
            echo -e "${RED}Operation cancelled.${NC}"
            exit 1
            ;;
        255)  # User pressed ESC
            clear
            echo -e "${RED}Operation aborted.${NC}"
            exit 1
            ;;
        *)  # Any other return status (including null input)
            echo -e "${RED}Warning: You didn't select any version! Defaulting to the latest version.${NC}"
            TARGET_VERSION=${GREATER_VERSIONS[0]}
            ;;
    esac

    echo "Selected K8S version: $TARGET_VERSION"
    echo $TARGET_VERSION
}


check_rke_existence_snapshot() {
    if [[ -z "$RKE_BINARY_SNAPSHOT" || ! -x "$RKE_BINARY_SNAPSHOT" ]]; then
        echo -e "${RED}Error: RKE for snapshot operations is not available or not executable.${NC}"
        search_rke_for_snapshot
    else
        SERVER_VERSION=$(get_server_version)
        echo -e "${GREEN}Checking compatibility of RKE version for snapshot operations... ${NC}"
        AVAILABLE_VERSIONS="$ALL_K8S_VERSIONS"
        if [[ -z $(echo "$AVAILABLE_VERSIONS" | grep "$SERVER_VERSION") ]]; then
            echo -e "${RED}Warning: The current SERVER_VERSION ($SERVER_VERSION) is not supported by the existing RKE binary for snapshot operations.${NC}"
            search_rke_for_snapshot
        fi
    fi
}

check_rke_existence_upgrade() {
    if [[ -z "$RKE_BINARY_UPGRADE" || ! -x "$RKE_BINARY_UPGRADE" ]]; then
        echo -e "${RED}Error: RKE for upgrade operations is not available or not executable.${NC}"
        search_rke_for_upgrade
    else
        SERVER_VERSION=$(get_server_version)
        echo -e "${GREEN}Checking compatibility of RKE version for upgrade operations... ${NC}"
        if [[ -n "$ALL_K8S_VERSIONS" ]]; then
            if [[ -z $(echo "$ALL_K8S_VERSIONS" | grep "$SERVER_VERSION") ]]; then
                echo -e "${RED}Warning: The current SERVER_VERSION ($SERVER_VERSION) is not supported by the existing RKE binary for upgrade operations.${NC}"
                search_rke_for_upgrade
            fi
        fi
    fi
}

search_rke_for_snapshot() {
    SERVER_VERSION=$(get_server_version)
    echo -e "${GREEN}Debug: Current Kubernetes Server Version: $SERVER_VERSION${NC}"
    PAGE=1  # Reset the page number to 1

    while : ; do
        echo "Fetching page $PAGE of RKE releases from GitHub..."
        RELEASES=$(get_rke_releases $PAGE)
        RELEASE_COUNT=$(echo "$RELEASES" | jq 'length')

        echo "Currently checking RKE releases on page $PAGE..."

        for (( i=0; i<$RELEASE_COUNT; i++ )); do
            BODY=$(echo "$RELEASES" | jq -r ".[$i].body")
            TAG=$(echo "$RELEASES" | jq -r ".[$i].tag_name")

            if [[ $TAG == *"rc"* ]]; then
                continue
            fi

            K8S_VERSIONS=$(echo "$BODY" | awk 'match($0, /v[0-9]+\.[0-9]+\.[0-9]+-rancher[0-9]+-[0-9]+/) {print substr($0, RSTART, RLENGTH)}' | awk -F- '{print $1}' | sort -V)

            # Debugging: Output the currently checked RKE version and supported K8S versions
            echo -e "${GREEN}Debug: Currently checking RKE version: $TAG${NC}"
            echo -e "${GREEN}Debug: Supported K8S versions: $K8S_VERSIONS${NC}"

            CURRENT_SUPPORTED=$(echo "$K8S_VERSIONS" | grep -c "^$SERVER_VERSION")

            if [[ $CURRENT_SUPPORTED -gt 0 ]]; then
                echo -e "${GREEN}Compatible RKE version found for snapshot: $TAG${NC}"
                MATCHED_K8S_VERSION="$SERVER_VERSION"
                MATCHED_FULL_K8S_VERSION=$(echo "$K8S_VERSIONS" | grep "^$NEXT_MAJOR_MINOR" | head -n 1)
                ALL_K8S_VERSIONS="$K8S_VERSIONS"  # Storing the list of versions in the global variable.
                download_rke $TAG
                RKE_BINARY_SNAPSHOT="$(pwd)/rke"  # Store the path to the RKE binary for snapshot operations.
                return 0
            else
                echo -e "${RED}RKE version $TAG does not support the current K8S version.${NC}"
            fi
        done

        if (( RELEASE_COUNT < PER_PAGE )); then
            echo -e "${RED}End of RKE releases reached without finding a compatible version for snapshot.${NC}"
            return 1
        else
            ((PAGE++))
        fi
    done
}

FULL_K8S_VERSIONS=()

search_rke_for_upgrade() {
    SERVER_VERSION=$(get_server_version)
    echo -e "${GREEN}Debug: Current Kubernetes Server Version: $SERVER_VERSION${NC}"
    PAGE=1  # Reset the page number to 1

    # Extract the major and minor version components
    CURRENT_MAJOR=$(echo "$SERVER_VERSION" | awk -F. '{print $1}')
    CURRENT_MINOR=$(echo "$SERVER_VERSION" | awk -F. '{print $2}')
    CURRENT_MAJOR_MINOR="$CURRENT_MAJOR.$CURRENT_MINOR"
    NEXT_MAJOR=$CURRENT_MAJOR
    NEXT_MINOR=$((CURRENT_MINOR + 1))
    NEXT_MAJOR_MINOR="$NEXT_MAJOR.$NEXT_MINOR"

    echo -e "${GREEN}Debug: Current Kubernetes Major.Minor Version: $CURRENT_MAJOR_MINOR${NC}"
    echo -e "${GREEN}Debug: Next Kubernetes Major.Minor Version: $NEXT_MAJOR_MINOR${NC}"

    while : ; do
        echo "Fetching page $PAGE of RKE releases from GitHub..."
        RELEASES=$(get_rke_releases $PAGE)
        RELEASE_COUNT=$(echo "$RELEASES" | jq 'length')

        echo "Currently checking RKE releases on page $PAGE..."

        for (( i=0; i<$RELEASE_COUNT; i++ )); do
            BODY=$(echo "$RELEASES" | jq -r ".[$i].body")
            TAG=$(echo "$RELEASES" | jq -r ".[$i].tag_name")

            if [[ $TAG == *"rc"* ]]; then
                continue
            fi

            K8S_VERSIONS=$(echo "$BODY" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+-rancher[0-9]+-[0-9]+' | sort -uV)

            # Debugging: Output the currently checked RKE version and supported K8S versions
            echo -e "${GREEN}Debug: Currently checking RKE version: $TAG${NC}"
            echo -e "${GREEN}Debug: Supported K8S versions: $K8S_VERSIONS${NC}"

            CURRENT_MAJOR_MINOR_SUPPORTED=$(echo "$K8S_VERSIONS" | grep -c "^$CURRENT_MAJOR_MINOR")
            NEXT_MAJOR_MINOR_SUPPORTED=$(echo "$K8S_VERSIONS" | grep -c "^$NEXT_MAJOR_MINOR")

            if [[ $CURRENT_MAJOR_MINOR_SUPPORTED -gt 0 && $NEXT_MAJOR_MINOR_SUPPORTED -gt 0 ]]; then
                echo -e "${GREEN}Compatible RKE version found for upgrade: $TAG${NC}"
                MATCHED_K8S_VERSION="$SERVER_VERSION"
                FULL_K8S_VERSIONS=($K8S_VERSIONS)  # Store the full versions in an array
                download_rke $TAG
                RKE_BINARY_UPGRADE="$(pwd)/rke"  # Store the path to the RKE binary for upgrade operations.
                return 0
            else
                echo -e "${RED}RKE version $TAG does not support the current and next K8S versions.${NC}"
            fi
        done

        if (( RELEASE_COUNT < PER_PAGE )); then
            echo -e "${RED}End of RKE releases reached without finding a compatible version for upgrade.${NC}"
            return 1
        else
            ((PAGE++))
        fi
    done
}


prepare_upgrade_config() {
    local new_version=$1
    local old_config="$CLUSTER_CONFIG"
    local new_config_dir="$(pwd)/output"
    local new_config="${new_config_dir}/cluster_${DATE_STR}.yml"
    local old_config_backup="${new_config_dir}/old_cluster_${DATE_STR}.yml"

    mkdir -p "$new_config_dir"

    # Backup the old configuration
    cp "$old_config" "$old_config_backup"
    # Copy the provided cluster.yml to a new file for upgrade modifications
    cp "$old_config" "$new_config"

    # Modify the Kubernetes version in the new file
    if [ -f "$new_config" ]; then
        if grep -q "kubernetes_version:" "$new_config"; then
            sed -i "s|kubernetes_version:.*|kubernetes_version: \"$new_version\"|g" "$new_config"
        else
            # If kubernetes_version line doesn't exist, add it at the beginning of the file
            sed -i "1ikubernetes_version: \"$new_version\"" "$new_config"
        fi
        echo -e "${GREEN}Cluster configuration copied and modified for upgrade. New config: $new_config${NC}"
        echo -e "${YELLOW}Kubernetes version set to: $new_version${NC}"
    else
        echo -e "${RED}Error: New configuration file not found: $new_config${NC}"
        exit 1
    fi

    # Verify the change
    if grep -q "kubernetes_version: \"$new_version\"" "$new_config"; then
        echo -e "${GREEN}Kubernetes version successfully updated in the configuration file.${NC}"
    else
        echo -e "${RED}Error: Failed to update Kubernetes version in the configuration file.${NC}"
        exit 1
    fi
}


upgrade_cluster() {
    echo -e "${GREEN}Starting cluster upgrade process...${NC}"

    SERVER_VERSION=$(get_server_version)
    echo -e "${YELLOW}Current server version: $SERVER_VERSION${NC}"

    select_k8s_version
    echo -e "${YELLOW}Selected upgrade version: $TARGET_VERSION${NC}"

    if [[ -z "$RKE_BINARY_UPGRADE" || ! -x "$RKE_BINARY_UPGRADE" ]]; then
        echo -e "${YELLOW}Checking RKE binary for upgrade...${NC}"
        check_rke_existence_upgrade
    fi

    if [[ -z "$MATCHED_K8S_VERSION" ]]; then
        echo -e "${RED}Error: Unable to find a matching K8S version. Ensure search_rke_for_upgrade was executed successfully.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Preparing upgrade configuration...${NC}"
    prepare_upgrade_config "$TARGET_VERSION"

    # Ensure the kubeconfig file exists
    if [ ! -f "$(pwd)/kubeconfig" ]; then
        echo -e "${RED}Error: kubeconfig file not found at $(pwd)/kubeconfig${NC}"
        return 1
    fi

    # Copy kubeconfig to the output directory
    cp "$(pwd)/kubeconfig" "$(pwd)/output/kube_config_cluster_${DATE_STR}.yml"
    echo -e "${GREEN}Copied kubeconfig to $(pwd)/output/kube_config_cluster_${DATE_STR}.yml${NC}"

    # Update the cluster configuration to include the correct kubeconfig path
    sed -i "s|kube_config_path:.*|kube_config_path: \"kube_config_cluster_${DATE_STR}.yml\"|g" "$(pwd)/output/cluster_${DATE_STR}.yml"
    echo -e "${GREEN}Updated cluster configuration with correct kubeconfig path${NC}"

    echo -e "${GREEN}Creating state file using RKE util get-state-file...${NC}"
    set -o pipefail
    ERROR_LOG=$(mktemp)
    (cd "$(pwd)/output" && $RKE_BINARY_UPGRADE util get-state-file $IGNORE_DOCKER_VERSION --config "cluster_${DATE_STR}.yml") 2>&1 | tee "$(pwd)/output/rke_util_${DATE_STR}.log" | tee $ERROR_LOG
    GET_STATE_EXIT_CODE=$?
    set +o pipefail

    if [[ $GET_STATE_EXIT_CODE -ne 0 ]]; then
        echo -e "${RED}Failed to create state file. Exit code: $GET_STATE_EXIT_CODE${NC}"
        echo -e "${RED}Error details:${NC}"
        cat $ERROR_LOG
        echo -e "${YELLOW}The complete log is available in $(pwd)/output/rke_util_${DATE_STR}.log${NC}"

        echo -e "${YELLOW}Waiting for 10 seconds before returning to the main menu...${NC}"
        sleep 10
        rm $ERROR_LOG
        return 1
    else
        echo -e "${GREEN}State file created successfully.${NC}"
    fi

    # Check if the state file was created with the expected name
    if [ -f "$(pwd)/output/cluster_${DATE_STR}.rkestate" ]; then
        echo -e "${GREEN}State file found at $(pwd)/output/cluster_${DATE_STR}.rkestate${NC}"
    else
        echo -e "${RED}Error: State file not found at expected location $(pwd)/output/cluster_${DATE_STR}.rkestate${NC}"
        return 1
    fi

    echo -e "${GREEN}Running RKE up : ${NC}"
    echo -e "${GREEN}Proceeding with RKE up to $TARGET_VERSION in 3 seconds...${NC}"
    sleep 3

    echo -e "${YELLOW}Applying --ignore-docker-version flag to avoid Docker version issues.${NC}"

    set -o pipefail
    ERROR_LOG=$(mktemp)
    (cd "$(pwd)/output" && $RKE_BINARY_UPGRADE up $IGNORE_DOCKER_VERSION --config "cluster_${DATE_STR}.yml") 2>&1 | tee "$(pwd)/output/rke_up_${DATE_STR}.log" | tee $ERROR_LOG
    UPGRADE_EXIT_CODE=$?
    set +o pipefail

    if [[ $UPGRADE_EXIT_CODE -ne 0 ]]; then
        echo -e "${RED}Failed to upgrade cluster. Exit code: $UPGRADE_EXIT_CODE${NC}"
        echo -e "${RED}Error details:${NC}"
        cat $ERROR_LOG
        echo -e "${YELLOW}The complete log is available in $(pwd)/output/rke_up_${DATE_STR}.log${NC}"
        echo -e "${YELLOW}Waiting for 10 seconds before returning to the main menu...${NC}"
        sleep 10
        rm $ERROR_LOG
        return 1
    else
        echo -e "${GREEN}Cluster upgrade completed successfully.${NC}"
        echo -e "${GREEN}The updated cluster.yml, state file, and RKE up logs are saved in the output directory.${NC}"
    fi

    echo -e "${YELLOW}Verifying the new cluster version...${NC}"
    NEW_SERVER_VERSION=$(get_server_version)
    echo -e "${GREEN}New server version: $NEW_SERVER_VERSION${NC}"

    if [[ "$NEW_SERVER_VERSION" == "$TARGET_VERSION" ]]; then
        echo -e "${GREEN}Cluster successfully upgraded to version $TARGET_VERSION${NC}"
    else
        echo -e "${YELLOW}Warning: Cluster version ($NEW_SERVER_VERSION) does not match target version ($TARGET_VERSION)${NC}"
    fi

    echo -e "${GREEN}Operation completed: Cluster upgrade.${NC}"
    echo -e "${YELLOW}Returning to main menu in 10 seconds...${NC}"
    sleep 10
}


copy_ssh_id() {
    if [ ! -f "$CLUSTER_CONFIG" ]; then
        echo -e "${RED}File $CLUSTER_CONFIG does not exist. Please make sure it is properly defined.${NC}"
        return
    fi

    echo -e "${YELLOW}Debugging: Contents of $CLUSTER_CONFIG:${NC}"
    cat "$CLUSTER_CONFIG"

    nodes=$(yq -r '.nodes[] | .user + "," + .address' "$CLUSTER_CONFIG")
    echo -e "${YELLOW}Debugging: Extracted nodes:${NC}"
    echo "$nodes"

    while IFS=',' read -r user address; do
        echo -e "${GREEN}Copying SSH key to $user@$address${NC}"
        ssh-copy-id -i ~/.ssh/id_rsa.pub "$user@$address"
    done <<< "$nodes"
}


restore_etcd_snapshot() {
    SERVER_VERSION=$(get_server_version)
    check_rke_existence_snapshot

    echo -e "${YELLOW}Please enter the name of the snapshot you wish to restore:${NC}"
    read SNAPSHOT_NAME

    echo "Attempting to restore etcd snapshot: $SNAPSHOT_NAME"
    echo -e "${YELLOW}Applying --ignore-docker-version flag to avoid Docker version issues.${NC}"
    $RKE_BINARY_SNAPSHOT etcd snapshot-restore --config=$CLUSTER_CONFIG --name "$SNAPSHOT_NAME" $IGNORE_DOCKER_VERSION

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Failed to restore etcd snapshot even with --ignore-docker-version flag.${NC}"
        exit 1
    else
        echo -e "${GREEN}Successfully restored etcd snapshot: $SNAPSHOT_NAME.${NC}"
    fi
}

main() {
    echo -e "${GREEN}Starting main function...${NC}"
    check_and_prepare_requirements
    while true; do
        echo -e "${GREEN}Displaying menu...${NC}"
        exec 3>&1
        CHOICE=$(dialog --clear --backtitle "RKE Operations" --no-collapse --cancel-label "Exit" --menu "Please choose:" 0 60 5 \
        "1" "Copy SSH keys to the cluster nodes" \
        "2" "Take etcd snapshot of the current cluster state" \
        "3" "Restore etcd snapshot" \
        "4" "Upgrade the RKE cluster" \
        "5" "Exit" 2>&1 1>&3)
        exit_status=$?
        exec 3>&-

        echo -e "${GREEN}Menu choice selected: $CHOICE, exit status: $exit_status${NC}"

        case $exit_status in
            1)  # User selected "Exit"
                clear
                echo "Program terminated."
                exit
                ;;
             255)  # User pressed ESC
                clear
                echo "Program aborted." >&2
                exit 1
                ;;
        esac

        case $CHOICE in
            1)
                echo -e "${GREEN}Copying SSH keys...${NC}"
                copy_ssh_id
                echo "Operation completed: Copy SSH keys."
                ;;
            2)
                echo -e "${GREEN}Prompting for RKE version...${NC}"
                if prompt_rke_version; then
                    echo "Operation completed: RKE download."
                else
                    search_rke_for_snapshot
                    echo "Operation completed: RKE download."
                fi
                take_snapshot
                echo "Operation completed: etcd snapshot."
                ;;
            3)
                echo -e "${GREEN}Prompting for RKE version...${NC}"
                if prompt_rke_version; then
                    echo "Operation completed: RKE download."
                else
                    search_rke_for_snapshot
                    echo "Operation completed: RKE download."
                fi
                restore_etcd_snapshot
                echo "Operation completed: etcd snapshot restoration."
                ;;
            4)
                echo -e "${GREEN}Prompting for RKE version...${NC}"
                if prompt_rke_version; then
                    echo "Operation completed: RKE download."
                else
                    search_rke_for_upgrade
                    echo "Operation completed: RKE download."
                fi
                upgrade_cluster
                echo "Operation completed: Cluster upgrade."
                ;;
            5)
                echo "Exiting the program..."
                break
                ;;
        esac
        sleep 3  # Give the user time to read the output.
        clear
    done
}

main
