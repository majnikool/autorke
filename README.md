# AutoRKE Script v0.5.0

This script automates various operations for RKE (Rancher Kubernetes Engine) clusters, including taking snapshots, restoring from snapshots, and upgrading the cluster.

## Requirements

- Bash
- curl
- jq
- yq
- wget
- dialog
- kubectl (configured with access to your cluster)
- SSH access to cluster nodes

## Setup

1. Ensure you have all the required binaries installed on your system.
2. Place the `autorke.sh` script in a directory of your choice.
3. Make sure `cluster.yml` and `kubeconfig` files are in the same directory as the script.
4. Ensure the script is executable:
   ```
   chmod +x autorke.sh
   ```

AutoRKE needs a GitHub token to interact with the GitHub API. To generate a token:

1. Visit https://github.com/settings/tokens.
2. Click `Generate new token`.
3. Give your token a descriptive name.
4. Under `Select scopes`, choose `repo`.
5. Click `Generate token` at the bottom of the page.
6. Copy the token and keep it safe. It won't be shown again

## Usage

Run the script with your GitHub token as an argument:

```
./autorke.sh <github_token>
```

Replace `<github_token>` with your actual GitHub personal access token.

## Features

The script provides a menu-driven interface with the following options:

1. **Copy SSH keys to the cluster nodes**
   - This option automates the process of copying your SSH public key to all nodes specified in the `cluster.yml` file.
   - It uses the `ssh-copy-id` command to copy the key to each node.

2. **Take etcd snapshot of the current cluster state**
   - This option allows you to take a snapshot of the current etcd state.
   - It prompts you to either specify an RKE version or searches for a compatible version.
   - The snapshot is taken using the `rke etcd snapshot-save` command.

3. **Restore etcd snapshot**
   - This option allows you to restore the cluster from a previously taken etcd snapshot.
   - It prompts you to enter the name of the snapshot you wish to restore.
   - The restoration is performed using the `rke etcd snapshot-restore` command.

4. **Upgrade the RKE cluster**
   - This option guides you through the process of upgrading your RKE cluster.
   - It checks for compatible RKE versions and allows you to select a target Kubernetes version.
   - The upgrade is performed using the `rke up` command with a modified cluster configuration.

5. **Exit**
   - This option allows you to exit the script.

Each option in the menu is implemented with error checking and informative output to guide you through the process.

## Output

- The script creates an `output` directory in the same location as the script.
- RKE binaries are downloaded and stored in the script's directory after each execution.
- Logs and modified configuration files are saved in the `output` directory.

## Notes

- The script requires SSH access to the cluster nodes. Ensure your SSH key is set up correctly.
- It uses the GitHub API to fetch RKE releases, so a valid GitHub token is required.
- The script automatically applies the `--ignore-docker-version` flag to avoid Docker version issues.

## Caution

- Always take a backup of your cluster before performing operations like upgrades or restores.
- Test the script in a non-production environment before using it on critical systems.

## Troubleshooting

If you encounter any issues:

1. Check the logs in the `output` directory.
2. Ensure all required binaries are installed and in your PATH.
3. Verify that your `cluster.yml` and `kubeconfig` files are correct and up-to-date.

