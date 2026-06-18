#!/bin/sh

# If the current User ID is not in /etc/passwd, append it dynamically
# so shell/SSH connections run /bin/bash by default.
# Use a UID-scoped username to avoid duplicating the existing "openclaw" entry.
uid="$(id -u)"
if ! getent passwd "$uid" >/dev/null 2>&1; then
  if [ -w /etc/passwd ]; then
    echo "openclaw-$uid:x:$uid:0:OpenClaw User:/home:/bin/bash" >> /etc/passwd
  fi
fi
