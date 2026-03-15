#!/bin/sh
# Lagoon entrypoint: Configure shell prompt with OpenClaw branding
# Sets a custom PS1 with lobster emoji, brand colors, and Lagoon env info

# Write bashrc additions to a file that gets sourced
BASHRC_D="/home/.bashrc.d"
mkdir -p "$BASHRC_D"

cat > "$BASHRC_D/openclaw-prompt.sh" << 'EOFBASH'
# OpenClaw custom prompt - lobster seam 🦞
# Brand color: #FF5A2D (lobster red/orange)
# Incorporates Lagoon environment variables

# Only set prompt for interactive shells
if [ "$PS1" ]; then
  # Color definitions (256-color for broad compatibility)
  __oc_lobster='\[\033[38;5;202m\]'      # Lobster orange-red
  __oc_coral='\[\033[38;5;209m\]'        # Coral/salmon
  __oc_green='\[\033[38;5;71m\]'         # Success green
  __oc_red='\[\033[38;5;196m\]'          # Error/production red
  __oc_blue='\[\033[38;5;75m\]'          # Dev environment blue
  __oc_yellow='\[\033[38;5;220m\]'       # Warning yellow
  __oc_gray='\[\033[38;5;245m\]'         # Muted gray
  __oc_white='\[\033[38;5;255m\]'        # Bright white
  __oc_reset='\[\033[0m\]'               # Reset
  __oc_bold='\[\033[1m\]'                # Bold

  # Build prompt with Lagoon environment info
  # Format: [project] branch@lagoon:🦞 ~/path$

  PS1=""

  # Project name (white, in brackets)
  if [ -n "$LAGOON_PROJECT" ]; then
    PS1="${PS1}[${__oc_white}${LAGOON_PROJECT}${__oc_reset}]"
  fi

  # Git branch / environment (red for production, blue for dev)
  if [ -n "$LAGOON_GIT_BRANCH" ]; then
    if [ "$LAGOON_ENVIRONMENT_TYPE" = "production" ]; then
      PS1="${PS1}${__oc_red}${LAGOON_GIT_BRANCH}${__oc_reset}@"
    else
      PS1="${PS1}${__oc_blue}${LAGOON_GIT_BRANCH}${__oc_reset}@"
    fi
  fi

  # Lagoon instance name (green) - fallback to "openclaw" branding
  if [ -n "$LAGOON" ]; then
    PS1="${PS1}${__oc_green}${LAGOON}${__oc_reset}:"
  fi

  # OpenClaw lobster branding + path
  PS1="${PS1}${__oc_lobster}🦞${__oc_reset} "
  PS1="${PS1}${__oc_yellow}\w${__oc_reset}\$ "
fi

# Helper to get gateway token (from env var or config file)
__oc_get_token() {
  # First check environment variable
  if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "$OPENCLAW_GATEWAY_TOKEN"
    return
  fi
  # Fall back to reading from config file
  local config_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
  local config_file="$config_dir/openclaw.json"
  if [ -f "$config_file" ]; then
    node -e "
      try {
        const c = require('$config_file');
        if (c.gateway?.auth?.token) console.log(c.gateway.auth.token);
      } catch {}
    " 2>/dev/null
  fi
}

# Welcome message on interactive shell
if [ -t 1 ] && [ -z "$__OC_WELCOMED" ]; then
  export __OC_WELCOMED=1

  # Determine base dashboard URL (LAGOON_ROUTE or localhost fallback)
  __oc_base_url="${LAGOON_ROUTE:-http://localhost:${OPENCLAW_GATEWAY_PORT:-3000}}"

  # Get gateway token
  __oc_token=$(__oc_get_token)

  # Build full dashboard URL with token
  if [ -n "$__oc_token" ]; then
    __oc_dashboard_url="${__oc_base_url}?token=${__oc_token}"
  else
    __oc_dashboard_url="$__oc_base_url"
  fi

  echo -e "\033[38;5;202m"
  echo "  🦞 OpenClaw Gateway Container"
  if [ -n "$LAGOON_PROJECT" ]; then
    echo -e "\033[38;5;245m  Project: $LAGOON_PROJECT"
  fi
  if [ -n "$LAGOON_GIT_BRANCH" ]; then
    echo -e "\033[38;5;245m  Environment: $LAGOON_GIT_BRANCH ($LAGOON_ENVIRONMENT_TYPE)"
  fi
  echo ""
  echo -e "\033[38;5;255m  Dashboard: \033[38;5;75m$__oc_dashboard_url\033[0m"
  echo ""
  echo -e "\033[38;5;245m  Type 'openclaw --help' for available commands\033[0m"
  echo ""

  # Clean up temp vars
  unset __oc_base_url __oc_token __oc_dashboard_url
fi
EOFBASH

# Add sourcing to .bashrc if not already present
BASHRC="/home/.bashrc"
if [ -f "$BASHRC" ]; then
  if ! grep -q "openclaw-prompt.sh" "$BASHRC" 2>/dev/null; then
    echo "" >> "$BASHRC"
    echo "# Source OpenClaw shell customizations" >> "$BASHRC"
    echo '[ -f /home/.bashrc.d/openclaw-prompt.sh ] && . /home/.bashrc.d/openclaw-prompt.sh' >> "$BASHRC"
  fi
else
  # Create .bashrc with our customization
  cat > "$BASHRC" << 'EOFRC'
# OpenClaw container bashrc
[ -f /home/.bashrc.d/openclaw-prompt.sh ] && . /home/.bashrc.d/openclaw-prompt.sh
EOFRC
fi

echo "[shell-config] OpenClaw shell prompt configured"
