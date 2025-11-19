# VSCodium Remote Server for AIX

This project provides an automated build system for creating VSCodium Remote Server packages compatible with IBM AIX on ppc64 architecture.

## Project Purpose

VSCodium Remote Server does not officially support AIX. This project bridges that gap by:

1. Building native Node.js modules specifically for AIX
2. Applying necessary patches for AIX compatibility
3. Packaging the server in a format that works on AIX systems
4. Automating the entire build and release process
5. Publishing releases to GitHub for easy distribution

## Target Users

This is designed for development teams using IBM AIX systems who want to use VSCodium's remote development capabilities.

## Architecture

The system consists of three main components:

### 1. Build System (build-vscodium-server-aix.sh)

The main build orchestrator that:

- Downloads the latest VSCodium Remote Server from upstream
- Builds native modules for AIX (native-watchdog, node-spdlog, node-pty, ripgrep)
- Applies AIX-specific patches to the server
- Creates a node wrapper for AIX compatibility
- Packages everything into a release tarball
- Generates SHA256 checksums and metadata

Location: scripts/build-vscodium-server-aix.sh

### 2. Automation System (auto-build-release.sh)

The automation orchestrator that:

- Checks GitHub for new VSCodium releases
- Triggers builds only when new versions are available
- Uploads completed builds to GitHub releases
- Sends email notifications for all events
- Maintains a cache to avoid duplicate builds
- Keeps detailed logs of all operations

Location: scripts/auto-build-release.sh

### 3. Module Build Scripts

Individual build scripts for each native module:

- build-native-watchdog.sh: Builds the native watchdog module
- build-node-spdlog.sh: Builds the logging module
- build-node-pty.sh: Builds the pseudo-terminal module (requires portlibforaix)
- build-ripgrep.sh: Builds the ripgrep search tool
- build-deviceid.sh: Patches device identification for AIX
- build-platform-override.sh: Overrides platform detection
- build-path-setup.sh: Sets up AIX-specific paths

Location: scripts/modules/

## Prerequisites

### System Requirements

- IBM AIX 7.3 or later
- ppc64 architecture
- Node.js 22.x installed at /opt/nodejs/bin/node
- GCC 10.3 or later
- Python 3.9 or later
- Rust toolchain (for ripgrep)
- Git
- wget or curl
- Internet connectivity for downloading sources

### Required Tools

- gcc: C/C++ compiler
- g++: C++ compiler
- make: Build automation
- cargo: Rust package manager
- node-gyp: Node.js native addon build tool
- npm: Node.js package manager

### GitHub Token

A GitHub personal access token is required for:

- Downloading releases (to avoid rate limits)
- Uploading releases to your repository

Create a token at: https://github.com/settings/tokens/new
Required scope: repo (full control)

Store the token at: ~/.config/github/token

## Installation

1. Clone this repository:
```
git clone https://github.com/tonykuttai/vscodium-aix-server.git
cd vscodium-aix-server
```

2. Make scripts executable:
```
chmod +x scripts/*.sh
chmod +x scripts/modules/*.sh
```

3. Configure GitHub token:
```
mkdir -p ~/.config/github
echo "your_token_here" > ~/.config/github/token
chmod 600 ~/.config/github/token
```

4. Configure email notifications:

Edit scripts/auto-build-release.sh and set:
```
EMAIL_TO="your@email.com"
```

## Usage

### Manual Build

To build the current latest VSCodium release:
```
cd scripts
bash build-vscodium-server-aix.sh
```

The build will:
- Download the latest VSCodium Remote Server
- Build all native modules
- Apply AIX patches
- Create a package in releases/VERSION/

### Automated Builds

To run the full automation pipeline:
```
cd scripts
bash auto-build-release.sh
```

This will:
- Check for new releases
- Build if a new version is found
- Upload to GitHub releases
- Send email notifications

### Setting Up Cron Automation

1. Verify cron-wrapper.sh is executable:
```
ls -la scripts/cron-wrapper.sh
```

2. Add to crontab:
```
crontab -e
```

3. Add this line for weekly runs (every Sunday at 2 AM):
```
0 2 * * 0 /home/varghese/utility/vscodium-aix-server/scripts/cron-wrapper.sh
```

Alternative schedules:
```
# Daily at 2 AM
0 2 * * * /home/varghese/utility/vscodium-aix-server/scripts/cron-wrapper.sh

# Twice per week (Monday and Thursday at 2 AM)
0 2 * * 1,4 /home/varghese/utility/vscodium-aix-server/scripts/cron-wrapper.sh

# Monthly (1st of month at 2 AM)
0 2 1 * * /home/varghese/utility/vscodium-aix-server/scripts/cron-wrapper.sh
```

## Directory Structure
```
vscodium-aix-server/
|
+-- scripts/
|   |-- build-vscodium-server-aix.sh    Main build orchestrator
|   |-- auto-build-release.sh           Automation pipeline
|   |-- cron-wrapper.sh                 Cron job wrapper
|   |-- upload-release.sh               GitHub upload handler
|   |-- check-status.sh                 Status checker
|   |
|   +-- modules/                        Individual module builders
|   |   |-- build-native-watchdog.sh
|   |   |-- build-node-spdlog.sh
|   |   |-- build-node-pty.sh
|   |   |-- build-ripgrep.sh
|   |   |-- build-deviceid.sh
|   |   |-- build-platform-override.sh
|   |   +-- build-path-setup.sh
|   |
|   +-- utils/                          Utility scripts
|   |   +-- aix-environment.sh          AIX build environment setup
|   |
|   +-- vscodium-servers/               Built servers (local cache)
|       +-- COMMIT_ID/                  Server organized by commit
|       +-- latest -> COMMIT_ID         Symlink to latest build
|
+-- releases/                           Packaged releases
|   +-- VERSION/                        One directory per version
|       |-- vscodium-reh-aix-ppc64-VERSION.tar.gz
|       |-- vscodium-reh-aix-ppc64-VERSION.tar.gz.sha256
|       +-- vscodium-reh-aix-ppc64-VERSION.info
|
+-- README.md                           This file
+-- LICENSE                             Project license
```

## Cache and Logs

The automation system uses the following directories:
```
~/.vscodium-build-cache/
|-- last-built.txt                     Tracks last built version
+-- logs/
    |-- auto-build-TIMESTAMP.log       Build logs
    +-- cron-wrapper.log               Cron execution log
```

## Email Notifications

The automation system sends emails for the following events:

1. Pipeline started
2. New release detected
3. Build completed successfully
4. Build failed
5. Upload failed
6. No new release available (optional)

Each email includes:
- Event summary
- Timestamp and hostname
- Last 50 lines of the log file

To disable email notifications:
```
export SEND_EMAIL="false"
```

## Build Process Details

### Phase 1: Environment Setup

- Configures compiler flags for AIX
- Sets up build paths
- Validates required tools
- Installs portlibforaix if needed

### Phase 2: Native Module Building

Each module is built independently:

- native-watchdog: File system watcher
- node-spdlog: High-performance logging
- node-pty: Pseudo-terminal support
- ripgrep: Fast text search

### Phase 3: Server Patching

- deviceid: Fixes device identification on AIX
- platform-override: Overrides platform detection to report as linux
- path-setup: Configures AIX-specific paths

### Phase 4: Packaging

- Creates tarball with AIX-specific naming
- Generates SHA256 checksum
- Creates metadata file with build information

## Troubleshooting

### Build Fails

Check the build log:
```
tail -100 ~/.vscodium-build-cache/logs/auto-build-*.log
```

Common issues:
- Missing dependencies: Install required system packages
- Compiler errors: Verify GCC version is 10.3 or later
- Network issues: Check internet connectivity

### Upload Fails

Verify GitHub token:
```
cat ~/.config/github/token
curl -H "Authorization: token $(cat ~/.config/github/token)" https://api.github.com/user
```

### Cron Job Not Running

Check cron status:
```
crontab -l
tail -50 ~/.vscodium-build-cache/logs/cron-wrapper.log
```

## Checking Build Status

Use the status checker:
```
bash scripts/check-status.sh
```

This displays:
- Last built version
- Recent build logs
- Cron job configuration
- Recent releases

## Manual Upload

If automated upload fails, upload manually:
```
cd scripts
bash upload-release.sh VERSION
```

## Contributing

This is a community project. Contributions are welcome:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test on AIX
5. Submit a pull request

## Support

For issues specific to AIX builds:
- Check existing issues: https://github.com/tonykuttai/vscodium-aix-server/issues
- Create a new issue with detailed logs

For upstream VSCodium issues:
- Visit: https://github.com/VSCodium/vscodium

## License

See LICENSE file for details.

## Acknowledgments

- VSCodium project for the base remote server
- IBM for AIX platform and tools
- Open source community for native modules

## Version Information

Built for: IBM AIX 7.3 on ppc64
Node.js: 22.x
Base: VSCodium Remote Server (upstream)

Last updated: 2025-11-19