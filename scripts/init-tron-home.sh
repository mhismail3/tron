#!/bin/bash
# Initialize ~/.tron directory structure
# Called during postinstall to ensure the config directory exists

TRON_HOME="${HOME}/.tron"

# Create directory structure
mkdir -p "${TRON_HOME}/db"
mkdir -p "${TRON_HOME}/skills"
mkdir -p "${TRON_HOME}/plans"
mkdir -p "${TRON_HOME}/notes"
mkdir -p "${TRON_HOME}/artifacts/canvases"

# Create .gitignore to prevent accidental commits if ~/.tron is ever version controlled
if [ ! -f "${TRON_HOME}/.gitignore" ]; then
  cat > "${TRON_HOME}/.gitignore" << 'EOF'
# Ignore everything - this is user data, not meant for version control
*
!.gitignore
EOF
fi

echo "✓ Initialized ~/.tron directory structure"
