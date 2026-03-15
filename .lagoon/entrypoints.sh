#!/bin/sh
# Source all entrypoint scripts in alphabetical order
if [ -d /lagoon/entrypoints ]; then
  for i in /lagoon/entrypoints/*; do
    if [ -r $i ]; then
      . $i
    fi
  done
  unset i
fi
exec "$@"
