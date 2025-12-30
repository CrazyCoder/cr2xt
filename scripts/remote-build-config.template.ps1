# Remote macOS Build Configuration Template
# Copy this file to remote-build-config.local.ps1 and update the values
# The .local.ps1 file is ignored by Git

# SSH Connection Settings
$SSH_HOST = "mac-hostname.local"     # Hostname or IP address of the remote Mac
$SSH_PORT = 22                       # SSH port (default: 22)
$SSH_USER = "username"               # SSH username

# Remote Paths
$REMOTE_PROJECT_PATH = "/Users/username/projects/cr2xt"  # Project root on remote machine
$REMOTE_DIST_PATH = "/Users/username/projects/cr2xt/dist" # DMG output directory

# Local Paths (relative to script directory or absolute)
$LOCAL_DIST_PATH = ""  # Leave empty to use project's dist folder, or specify absolute path

# SSH/SCP Tool Selection
# Options: "msys2" (uses ssh/scp from MSYS2), "putty" (uses plink/pscp from PuTTY)
$SSH_TOOL = "msys2"

# Tool Paths (only needed if tools are not in PATH)
# For MSYS2:
$MSYS2_SSH = "C:\tools\msys64\usr\bin\ssh.exe"
$MSYS2_SCP = "C:\tools\msys64\usr\bin\scp.exe"

# For PuTTY:
$PUTTY_PLINK = "C:\Program Files\PuTTY\plink.exe"
$PUTTY_PSCP = "C:\Program Files\PuTTY\pscp.exe"
$PUTTY_KEY = ""  # Path to .ppk private key file for passwordless auth
