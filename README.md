# Claude Desktop APT Repository

This branch hosts the APT repository for Claude Desktop on Linux.

## Installation

```bash
# Add the GPG key
curl -fsSL https://aaddrick.github.io/claude-desktop-debian/KEY.gpg | sudo gpg --dearmor -o /usr/share/keyrings/claude-desktop.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg arch=amd64,arm64] https://aaddrick.github.io/claude-desktop-debian stable main" | sudo tee /etc/apt/sources.list.d/claude-desktop.list

# Update and install
sudo apt update
sudo apt install claude-desktop
```

## Updates

Once installed, Claude Desktop will update with your regular system updates:

```bash
sudo apt update && sudo apt upgrade
```

## Supported Architectures

- `amd64` (x86_64)
- `arm64` (aarch64)
