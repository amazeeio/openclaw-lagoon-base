#!/bin/sh
set -e

mkdir -p /home/.ssh

# If we there is an ssh key injected via lagoon and kubernetes, we use that
if [ -f /var/run/secrets/lagoon/sshkey/ssh-privatekey ]; then
  cp -f /var/run/secrets/lagoon/sshkey/ssh-privatekey /home/.ssh/key
# If there is an env variable SSH_PRIVATE_KEY we use that
elif [ ! -z "$SSH_PRIVATE_KEY" ]; then
  echo -e "$SSH_PRIVATE_KEY" > /home/.ssh/key
# If there is an env variable LAGOON_SSH_PRIVATE_KEY we use that
elif [ ! -z "$LAGOON_SSH_PRIVATE_KEY" ]; then
  echo -e "$LAGOON_SSH_PRIVATE_KEY" > /home/.ssh/key
fi

if [ -f /home/.ssh/key ] && [ -w /home/.ssh/key ]; then
  # add a new line to the key. OpenSSH is very picky that keys are always end with a newline
  echo >> /home/.ssh/key

  # Check the current file permissions of /home/.ssh/key.
  # If the permissions are not set to 600 (owner read/write only), update them to 600
  # to ensure SSH private key security (required by OpenSSH).
  if [ "$(stat -c '%a' /home/.ssh/key)" != "600" ]; then
  chmod 600 /home/.ssh/key
  fi

fi
