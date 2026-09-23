#!/bin/sh
# Start the service-port proxy before anything slow (doctor, plugin seeding) so
# Lagoon's liveness probe passes during boot. See /lagoon/gateway-port-proxy.js.
if [ "$1" = "openclaw" ] && [ "$2" = "gateway" ] && [ "${OPENCLAW_GATEWAY_PORT:-3000}" != "3000" ]; then
  node /lagoon/gateway-port-proxy.js &
fi
