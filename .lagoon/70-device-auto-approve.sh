#!/bin/sh
# Lagoon entrypoint: auto-approve device pairing requests.
#
# Hosted users have no SSH access to run `openclaw devices approve`, so the
# beta.4+ device-pairing gate ("Device pairing required" in the Control UI)
# hard-locks them out. Pairing requests are only created AFTER the client has
# already authenticated with the gateway token, so auto-approving them keeps
# the token as the sole credential -- the same trust model the retired
# gateway.controlUi.dangerouslyDisableDeviceAuth=true gave us on pre-beta.4
# runtimes. Opt out per instance with OPENCLAW_DEVICE_AUTO_APPROVE=false.

if [ "${OPENCLAW_DEVICE_AUTO_APPROVE:-true}" = "false" ]; then
  echo "[device-auto-approve] Disabled via OPENCLAW_DEVICE_AUTO_APPROVE=false"
else
  device_auto_approve_loop() {
    # Let the gateway finish starting before the first poll.
    sleep 30
    while true; do
      for req in $(openclaw devices list --json 2>/dev/null | jq -r '.pending[]?.requestId // empty'); do
        echo "[device-auto-approve] $(date -u +%FT%TZ) approving pending device pairing request $req"
        openclaw devices approve "$req" \
          || echo "[device-auto-approve] WARNING: failed to approve $req (may have been superseded; retrying next poll)"
      done
      # ponytail: 15s CLI poll (one node process per iteration); switch to a
      # long-lived gateway event subscription if CPU ever matters.
      sleep 15
    done
  }
  ( device_auto_approve_loop ) >/home/.openclaw/device-auto-approve.log 2>&1 &
  echo "[device-auto-approve] Started background pairing auto-approver (poll every 15s)"
fi
