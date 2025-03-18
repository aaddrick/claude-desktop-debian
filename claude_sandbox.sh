#!/bin/bash

if ! command -v bwrap &>/dev/null; then
    echo "bwrap not found. Installing bubblewrap..."
    sudo apt update && sudo apt install -y bubblewrap
fi

# Determine sandbox name from the first argument or default to "claude-desktop"
SANDBOX_NAME="${1:-claude-desktop}"
SANDBOX_HOME="$HOME/sandboxes/${SANDBOX_NAME}"

# create fake passwd file
grep "^$(whoami)" /etc/passwd | sed 's#[^\:]*:x:\([0-9\:]*\).*#agent:x:\1Agent:/home/agent:/bin/bash#' > "fake_passwd.${SANDBOX_NAME}"

BWRAP_CMD=(
  bwrap
  --ro-bind /sbin /sbin
  --ro-bind /bin /bin
  --ro-bind /usr /usr
  --ro-bind /lib /lib
  --ro-bind /lib64 /lib64
  --ro-bind /etc /etc
  --ro-bind "./fake_passwd.${SANDBOX_NAME}" /etc/passwd
  --ro-bind /run/dbus /run/dbus
  --ro-bind /run/systemd /run/systemd
  --bind "/run/user/${UID}/bus" "/run/user/${UID}/bus"
  --bind "/run/user/${UID}/docker.pid" "/run/user/${UID}/docker.pid"
  --bind "/run/user/${UID}/docker.sock" "/run/user/${UID}/docker.sock"
  --bind "/run/user/${UID}/docker" "/run/user/${UID}/docker"
  --dev-bind /dev /dev
  --proc /proc
  --bind "${SANDBOX_HOME}" /home/agent
  --ro-bind "${HOME}/.docker/contexts/meta/" /home/agent/.docker/contexts/meta/
  --tmpfs /tmp
  --clearenv
  --setenv HOME /home/agent
  --setenv PATH "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/home/agent/.local/bin"
  --setenv DISPLAY "${DISPLAY}"
  --setenv DBUS_SESSION_BUS_ADDRESS "${DBUS_SESSION_BUS_ADDRESS}"
  --setenv XDG_RUNTIME_DIR "${XDG_RUNTIME_DIR}"
  --setenv TERM "${TERM}"
  --setenv COLOTTERM "${COLORTERM}"
)

# Check if SANDBOX_HOME exists, if not create it and set ownership
if [ ! -d "$SANDBOX_HOME" ]; then
  mkdir -p "$SANDBOX_HOME"

  cat > "${SANDBOX_HOME}/init.sh" <<EOF
#!/bin/bash

check_command() {
    if ! command -v "\$1" &> /dev/null; then
        echo "❌ \$1 not found"
        return 1
    else
        echo "✓ \$1 found"
        return 0
    fi
}

if check_command "electron"; then
  echo "Electron already installed"
  exit 0
fi
# Install electron globally via npm if not present
echo "Instaling nvm..."
# install nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash

export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"  # This loads nvm

echo "Installing node via nvm..."
# install node
nvm install 22

echo "Installing electron via npm..."
npm install -g electron
if ! check_command "electron"; then
    echo "Failed to install electron. Please install it manually:"
    echo "sudo npm install -g electron"
    exit 1
fi
echo "Electron installed successfully"
# npx playwright install

echo "Installing uv/uvx..."
curl -LsSf https://astral.sh/uv/install.sh | sh

EOF
  chmod +x "${SANDBOX_HOME}/init.sh"

  # Initialize the sandbox
  "${BWRAP_CMD[@]}" "./init.sh"

  cp -a ~/.bashrc "${SANDBOX_HOME}"
  echo 'PS1="\[\e[48;5;208m\e[97m\]sandbox\[\e[0m\] \[\e[1;32m\]\h:\w\[\e[0m\]$ "' >> "${SANDBOX_HOME}/.bashrc"

  echo "Sandbox initialized successfully!"
fi

"${BWRAP_CMD[@]}" /bin/bash

#  --ro-bind "${HOME}/.nvm/" /home/agent/.nvm/ \
#  --ro-bind "${HOME}/.local/bin" /home/agent/.local/bin \
# --bind "/run/user/$(id -u)/bus" "/run/user/$(id -u)/bus"
