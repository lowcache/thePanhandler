# Forced command for the unlock keys: pass the request and the address the client hit to the root half.
read -r _ _ server_ip _ <<<"${SSH_CONNECTION:-}"
exec sudo -n "$PH_UNLOCK_ROOT" "${server_ip:-}" "${SSH_ORIGINAL_COMMAND:-status}"
