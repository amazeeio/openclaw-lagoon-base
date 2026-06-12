#!/bin/sh

# If the current User ID is not in /etc/passwd, append it dynamically
# so shell/SSH connections run /bin/bash by default.
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
  if [ -w /etc/passwd ]; then
    echo "openclaw:x:$(id -u):0:OpenClaw User:/home:/bin/bash" >> /etc/passwd
  fi
fi
