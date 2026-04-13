#!/usr/bin/env bash
# discord_debug.sh — Preflight & troubleshooting script for the Discord ↔ Discourse bridge.
#
# Run as root or with sudo on the VPS:
#   bash /var/discourse/community/scripts/discord_debug.sh
#
# What it checks:
#   1.  Bot service (systemd) — installed, enabled, running
#   2.  Bot working directory & files present
#   3.  .env file — exists, not example values, all required keys present
#   4.  Python 3 available and discord.py / aiohttp / python-dotenv installed
#   5.  HMAC secret length (≥32 chars recommended)
#   6.  Discord bot token format (starts with expected prefix)
#   7.  Discord channel IDs are numeric snowflakes
#   8.  Discourse container running
#   9.  Discourse incoming endpoint reachable (loopback test with wrong sig → expect 401)
#   10. HMAC round-trip test (sign a payload the same way the bot does, expect 200)
#   11. Discourse Chat channel ID configured and non-zero
#   12. Discourse support category ID configured and non-zero
#   13. discord-bridge Discourse user existence (via Discourse API)
#   14. Outbound HTTPS to Discord API reachable
#   15. Recent bot journal log tail

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'
BLD='\033[1m'

pass()  { echo -e "  ${GRN}✔${RST}  $*"; }
fail()  { echo -e "  ${RED}✘${RST}  $*"; FAILURES=$((FAILURES+1)); }
warn()  { echo -e "  ${YEL}⚠${RST}  $*"; WARNINGS=$((WARNINGS+1)); }
info()  { echo -e "  ${BLU}ℹ${RST}  $*"; }
hdr()   { echo -e "\n${BLD}${CYN}── $* ${RST}"; }

FAILURES=0
WARNINGS=0

# ── Configuration ─────────────────────────────────────────────────────────────
# Adjust these paths if your deployment differs from the defaults in discord-bot.service
BOT_DIR="${BOT_DIR:-/var/discourse/community/scripts/discord_bot}"
SERVICE_NAME="${SERVICE_NAME:-discord-bot}"
DISCOURSE_URL="${DISCOURSE_URL:-https://forum.christitus.com}"
DISCOURSE_API_KEY="${DISCOURSE_API_KEY:-}"   # optional — needed for check 13

ENV_FILE="$BOT_DIR/.env"
BOT_PY="$BOT_DIR/bot.py"
REQ_TXT="$BOT_DIR/requirements.txt"

echo -e "\n${BLD}╔══════════════════════════════════════════════════════════╗"
echo -e   "║     Discord ↔ Discourse Bridge — Preflight Debug Script  ║"
echo -e   "╚══════════════════════════════════════════════════════════╝${RST}"
echo -e "  Discourse URL : ${CYN}${DISCOURSE_URL}${RST}"
echo -e "  Bot directory : ${CYN}${BOT_DIR}${RST}"
echo -e "  Systemd unit  : ${CYN}${SERVICE_NAME}${RST}"
echo -e "  Timestamp     : $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n"

# ── 1. Systemd service ────────────────────────────────────────────────────────
hdr "1. Systemd service"

if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null && \
   systemctl list-unit-files "${SERVICE_NAME}.service" | grep -q "${SERVICE_NAME}"; then
  pass "Unit file ${SERVICE_NAME}.service is installed"
else
  fail "Unit file ${SERVICE_NAME}.service not found — copy deploy/discord-bot.service to /etc/systemd/system/ and run: systemctl daemon-reload"
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
  pass "Service is enabled (will start on boot)"
else
  warn "Service is not enabled — run: systemctl enable ${SERVICE_NAME}"
fi

SVC_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)
if [[ "$SVC_STATE" == "active" ]]; then
  pass "Service is running (active)"
else
  fail "Service state: ${SVC_STATE} — run: systemctl start ${SERVICE_NAME}  |  check: journalctl -u ${SERVICE_NAME} -n 50"
fi

# ── 2. Bot files ──────────────────────────────────────────────────────────────
hdr "2. Bot files"

if [[ -d "$BOT_DIR" ]]; then
  pass "Bot directory exists: $BOT_DIR"
else
  fail "Bot directory not found: $BOT_DIR  (check WorkingDirectory in the service file)"
fi

if [[ -f "$BOT_PY" ]]; then
  pass "bot.py present"
else
  fail "bot.py missing from $BOT_DIR"
fi

if [[ -f "$REQ_TXT" ]]; then
  pass "requirements.txt present"
else
  warn "requirements.txt missing — dependencies may not be installed"
fi

if [[ -f "$ENV_FILE" ]]; then
  pass ".env file present"
else
  fail ".env file missing — copy .env.example to .env and fill in values"
fi

# ── 3. .env contents ──────────────────────────────────────────────────────────
hdr "3. .env file contents"

if [[ -f "$ENV_FILE" ]]; then
  # Source safely: extract key=value lines into variables without executing arbitrary code
  declare -A ENV_VARS=()
  while IFS='=' read -r key val; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue   # skip comments
    [[ -z "$key" ]] && continue
    key="${key// /}"
    val="${val//\"}"
    val="${val//\'}"
    ENV_VARS["$key"]="$val"
  done < "$ENV_FILE"

  REQUIRED_KEYS=(DISCORD_BOT_TOKEN DISCOURSE_URL HMAC_SECRET GENERAL_CHANNEL_ID SUPPORT_FORUM_ID)
  for k in "${REQUIRED_KEYS[@]}"; do
    v="${ENV_VARS[$k]:-}"
    if [[ -z "$v" ]]; then
      fail "Missing or empty: $k"
    elif [[ "$v" == *"your-"* || "$v" == *"change-me"* || "$v" == *"123456789012345678"* ]]; then
      fail "$k still has example/placeholder value: $v"
    else
      # Show only suffix for secrets
      case "$k" in
        DISCORD_BOT_TOKEN|HMAC_SECRET)
          pass "$k is set (${#v} chars, ends: …${v: -6})"
          ;;
        *)
          pass "$k = $v"
          ;;
      esac
    fi
  done

  # Check DISCOURSE_URL has no trailing slash
  DISC_URL="${ENV_VARS[DISCOURSE_URL]:-}"
  if [[ "$DISC_URL" == */ ]]; then
    warn "DISCOURSE_URL has a trailing slash — the bot strips it but it's cleaner without: $DISC_URL"
  fi
else
  warn "Skipping .env content checks (file missing)"
fi

# ── 4. Python environment ─────────────────────────────────────────────────────
hdr "4. Python environment"

# Prefer the venv python (used by the service) over the system python
VENV_PYTHON="$BOT_DIR/venv/bin/python3"
if [[ -x "$VENV_PYTHON" ]]; then
  PYTHON_BIN="$VENV_PYTHON"
  info "Using venv python: $VENV_PYTHON"
elif command -v python3 &>/dev/null; then
  PYTHON_BIN=$(command -v python3)
  warn "venv not found at $VENV_PYTHON — falling back to system python3 ($PYTHON_BIN). Run: python3 -m venv $BOT_DIR/venv && $BOT_DIR/venv/bin/pip install -r $REQ_TXT"
else
  PYTHON_BIN=""
  fail "python3 not found — install with: apt install python3"
fi

if [[ -n "$PYTHON_BIN" ]]; then
  PY_VER=$("$PYTHON_BIN" --version 2>&1)
  pass "python3 found: $PY_VER ($PYTHON_BIN)"
  for pkg in discord aiohttp dotenv; do
    if "$PYTHON_BIN" -c "import $pkg" 2>/dev/null; then
      VER=$("$PYTHON_BIN" -c "import importlib.metadata; print(importlib.metadata.version('$(
        case $pkg in dotenv) echo python-dotenv;; discord) echo discord.py;; *) echo "$pkg";; esac
      )')") 2>/dev/null || true
      pass "Python package '${pkg}' importable${VER:+ (v${VER})}"
    else
      fail "Python package '${pkg}' not installed — run: $BOT_DIR/venv/bin/pip install -r $REQ_TXT"
    fi
  done
fi

# ── 5. HMAC secret strength ───────────────────────────────────────────────────
hdr "5. HMAC secret strength"

if [[ -f "$ENV_FILE" ]]; then
  HMAC_VAL="${ENV_VARS[HMAC_SECRET]:-}"
  HMAC_LEN="${#HMAC_VAL}"
  if [[ -z "$HMAC_VAL" ]]; then
    fail "HMAC_SECRET is empty"
  elif [[ $HMAC_LEN -lt 32 ]]; then
    fail "HMAC_SECRET is only ${HMAC_LEN} chars — use ≥32 random chars (generate: python3 -c \"import secrets; print(secrets.token_hex(32))\")"
  elif [[ $HMAC_LEN -lt 48 ]]; then
    warn "HMAC_SECRET is ${HMAC_LEN} chars — 64+ recommended for best security"
  else
    pass "HMAC_SECRET length ${HMAC_LEN} chars — good"
  fi
fi

# ── 6. Discord bot token format ───────────────────────────────────────────────
hdr "6. Discord bot token format"

if [[ -f "$ENV_FILE" ]]; then
  TOKEN="${ENV_VARS[DISCORD_BOT_TOKEN]:-}"
  # Modern Discord bot tokens: <base64 user_id>.<timestamp>.<hmac>  (3 dot-separated parts)
  PARTS=$(echo "$TOKEN" | tr '.' '\n' | wc -l)
  if [[ -z "$TOKEN" ]]; then
    fail "DISCORD_BOT_TOKEN is empty"
  elif [[ "$PARTS" -ne 3 ]]; then
    warn "DISCORD_BOT_TOKEN doesn't look like a standard Discord bot token (expected 3 dot-separated parts, got ${PARTS}) — double-check in Discord Developer Portal"
  else
    pass "DISCORD_BOT_TOKEN format looks correct (3-part structure)"
  fi
fi

# ── 7. Discord channel ID format ──────────────────────────────────────────────
hdr "7. Discord channel ID format (snowflakes)"

if [[ -f "$ENV_FILE" ]]; then
  for id_key in GENERAL_CHANNEL_ID SUPPORT_FORUM_ID; do
    id_val="${ENV_VARS[$id_key]:-}"
    if [[ -z "$id_val" ]]; then
      fail "$id_key is empty"
    elif ! [[ "$id_val" =~ ^[0-9]{17,20}$ ]]; then
      fail "$id_key = '$id_val' — Discord snowflake IDs are 17-20 digit numbers (enable Developer Mode in Discord, then right-click channel → Copy ID)"
    else
      pass "$id_key = $id_val (valid snowflake format)"
    fi
  done
fi

# ── 8. Discourse container ────────────────────────────────────────────────────
hdr "8. Discourse container"

if command -v docker &>/dev/null; then
  # Standard Discourse Docker container is named 'app'; also catch any with 'discourse' in the name
  DISC_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^app$|discourse' | head -1 || true)
  if [[ -n "$DISC_CONTAINER" ]]; then
    pass "Discourse Docker container running: $DISC_CONTAINER"
  else
    warn "No running Docker container named 'app' or 'discourse' found — check: docker ps"
  fi
elif [[ -f /etc/systemd/system/discourse.service ]] || systemctl is-active --quiet discourse 2>/dev/null; then
  pass "Discourse systemd service is active"
else
  warn "Cannot determine Discourse container/service status — verify it manually"
fi

# ── 9. Incoming endpoint reachable (wrong sig → expect 401) ──────────────────
hdr "9. Discourse incoming endpoint (wrong signature → expect 401)"

ENDPOINT="${DISCOURSE_URL}/community-integrations/discord/incoming"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "X-Bridge-Signature: sha256=invalidsignature" \
  -d '{"type":"chat_message","discord_msg_id":"0","discord_username":"test","discord_user_id":"0","content":"test"}' \
  --max-time 10 2>/dev/null || echo "CURL_FAIL")

if [[ "$HTTP_CODE" == "401" ]]; then
  pass "Endpoint reachable and correctly rejecting bad signature (HTTP 401)"
elif [[ "$HTTP_CODE" == "404" ]]; then
  fail "Endpoint returned 404 — plugin route not registered. Did Discourse restart after adding the plugin? Check: /admin/plugins"
elif [[ "$HTTP_CODE" == "CURL_FAIL" ]]; then
  fail "Could not connect to $ENDPOINT — check that Discourse is running and the URL is correct"
else
  warn "Unexpected HTTP $HTTP_CODE from endpoint — expected 401 for bad signature"
fi

# ── 10. HMAC round-trip test (correct sig → expect 200) ───────────────────────
hdr "10. HMAC round-trip test (correct signature → expect 200)"

if [[ -f "$ENV_FILE" ]]; then
  HMAC_SECRET_VAL="${ENV_VARS[HMAC_SECRET]:-}"
  if [[ -z "$HMAC_SECRET_VAL" || "$HMAC_SECRET_VAL" == *"change-me"* ]]; then
    warn "Skipping round-trip test — HMAC_SECRET not set in .env"
  elif ! command -v python3 &>/dev/null; then
    warn "Skipping round-trip test — python3 not available to compute HMAC"
  else
    TEST_BODY='{"type":"chat_message","discord_msg_id":"debug1","discord_username":"debuguser","discord_user_id":"1","content":"debug preflight test"}'
    CORRECT_SIG=$(python3 -c "
import hmac, hashlib, sys
secret = sys.argv[1].encode()
body   = sys.argv[2].encode()
print('sha256=' + hmac.new(secret, body, hashlib.sha256).hexdigest())
" "$HMAC_SECRET_VAL" "$TEST_BODY" 2>/dev/null || true)

    if [[ -z "$CORRECT_SIG" ]]; then
      warn "Could not compute HMAC signature — skipping round-trip test"
    else
      RT_CODE=$(curl -sf -o /tmp/discord_debug_response.txt -w "%{http_code}" \
        -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "X-Bridge-Signature: $CORRECT_SIG" \
        -d "$TEST_BODY" \
        --max-time 10 2>/dev/null || echo "CURL_FAIL")

      if [[ "$RT_CODE" == "200" ]]; then
        pass "Round-trip HMAC test passed (HTTP 200) — endpoint accepted the correctly signed payload"
      elif [[ "$RT_CODE" == "CURL_FAIL" ]]; then
        fail "curl failed during round-trip test — check network connectivity to $DISCOURSE_URL"
      elif [[ "$RT_CODE" == "500" ]]; then
        RESP=$(cat /tmp/discord_debug_response.txt 2>/dev/null || true)
        fail "Endpoint returned 500 — plugin code error. Check Discourse logs: tail -f /var/discourse/shared/standalone/log/rails/production.log | grep DiscordBridge. Response: ${RESP:0:200}"
      elif [[ "$RT_CODE" == "404" ]]; then
        fail "Endpoint returned 404 — route not registered (same as check 9)"
      else
        RESP=$(cat /tmp/discord_debug_response.txt 2>/dev/null || true)
        warn "Unexpected HTTP ${RT_CODE} — response: ${RESP:0:200}"
      fi
    fi
  fi
else
  warn "Skipping round-trip test — .env not found"
fi

# ── 11. Discourse Chat channel ID ─────────────────────────────────────────────
hdr "11. Discourse Chat channel ID (Discourse site setting)"

# Query the Discourse API for the setting value
if [[ -n "$DISCOURSE_API_KEY" ]]; then
  CHAT_CH_ID=$(curl -sf \
    -H "Api-Key: $DISCOURSE_API_KEY" \
    -H "Api-Username: system" \
    "${DISCOURSE_URL}/admin/site_settings/community_integrations_discourse_chat_channel_id.json" \
    --max-time 10 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('site_settings'); print((s[0].get('value','') if s else d.get('value','')))" 2>/dev/null || true)
  if [[ -z "$CHAT_CH_ID" || "$CHAT_CH_ID" == "0" ]]; then
    fail "community_integrations_discourse_chat_channel_id is 0 or not set in Discourse — configure it at /admin/site_settings (filter: discord)"
  else
    pass "community_integrations_discourse_chat_channel_id = $CHAT_CH_ID"
  fi
else
  warn "DISCOURSE_API_KEY not set — skipping Discourse site settings checks (checks 11-13)"
  info "To enable: DISCOURSE_API_KEY=<your-admin-api-key> bash $0"
fi

# ── 12. Discourse support category ID ────────────────────────────────────────
hdr "12. Discourse support category ID (Discourse site setting)"

if [[ -n "$DISCOURSE_API_KEY" ]]; then
  SUP_CAT_ID=$(curl -sf \
    -H "Api-Key: $DISCOURSE_API_KEY" \
    -H "Api-Username: system" \
    "${DISCOURSE_URL}/admin/site_settings/community_integrations_discourse_support_category_id.json" \
    --max-time 10 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('site_settings'); print((s[0].get('value','') if s else d.get('value','')))" 2>/dev/null || true)
  if [[ -z "$SUP_CAT_ID" || "$SUP_CAT_ID" == "0" ]]; then
    fail "community_integrations_discourse_support_category_id is 0 or not set — configure it at /admin/site_settings (filter: discord)"
  else
    pass "community_integrations_discourse_support_category_id = $SUP_CAT_ID"
  fi
fi

# ── 13. discord-bridge Discourse user ────────────────────────────────────────
hdr "13. 'discord-bridge' fallback user"

if [[ -n "$DISCOURSE_API_KEY" ]]; then
  BRIDGE_USER_SETTING=$(curl -sf \
    -H "Api-Key: $DISCOURSE_API_KEY" \
    -H "Api-Username: system" \
    "${DISCOURSE_URL}/admin/site_settings/community_integrations_discord_bridge_username.json" \
    --max-time 10 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); s=d.get('site_settings'); print((s[0].get('value','discord-bridge') if s else d.get('value','discord-bridge')))" 2>/dev/null || echo "discord-bridge")

  USER_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Api-Key: $DISCOURSE_API_KEY" \
    -H "Api-Username: system" \
    "${DISCOURSE_URL}/u/${BRIDGE_USER_SETTING}.json" \
    --max-time 10 2>/dev/null || echo "CURL_FAIL")

  if [[ "$USER_STATUS" == "200" ]]; then
    pass "Bridge fallback user '${BRIDGE_USER_SETTING}' exists in Discourse"
  elif [[ "$USER_STATUS" == "404" ]]; then
    fail "Bridge fallback user '${BRIDGE_USER_SETTING}' does NOT exist — create it at /admin/users/new (username must match community_integrations_discord_bridge_username setting)"
  else
    warn "Could not verify user '${BRIDGE_USER_SETTING}' (HTTP ${USER_STATUS})"
  fi
fi

# ── 14. Outbound HTTPS to Discord API ────────────────────────────────────────
hdr "14. Outbound connectivity to Discord API"

DISCORD_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "https://discord.com/api/v10/gateway" \
  --max-time 10 2>/dev/null || echo "CURL_FAIL")

if [[ "$DISCORD_STATUS" == "200" ]]; then
  pass "discord.com/api/v10 reachable (HTTP 200)"
elif [[ "$DISCORD_STATUS" == "CURL_FAIL" ]]; then
  fail "Cannot reach discord.com — check VPS firewall/outbound rules (port 443 must be open)"
else
  warn "discord.com/api/v10/gateway returned HTTP $DISCORD_STATUS (non-200, but connection succeeded)"
fi

# Also check the webhook URL if set
if [[ -f "$ENV_FILE" ]]; then
  WEBHOOK_CHECK=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X GET "${DISCOURSE_URL}" \
    --max-time 5 2>/dev/null || echo "CURL_FAIL")
  # We just care the domain is up; we already know the webhook URL in the file is valid
fi

# ── 15. Recent bot logs ───────────────────────────────────────────────────────
hdr "15. Recent bot journal logs (last 30 lines)"

if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null && \
   systemctl list-unit-files "${SERVICE_NAME}.service" | grep -q "${SERVICE_NAME}"; then
  echo ""
  journalctl -u "${SERVICE_NAME}" -n 30 --no-pager 2>/dev/null || \
    warn "Could not read journal for ${SERVICE_NAME}"
else
  info "Service not installed — no logs to show"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${BLD}╔══════════════════════════════════════════════════════════╗"
echo -e   "║                        Summary                           ║"
echo -e   "╚══════════════════════════════════════════════════════════╝${RST}"

if [[ $FAILURES -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "  ${GRN}${BLD}All checks passed — bridge looks healthy!${RST}"
elif [[ $FAILURES -eq 0 ]]; then
  echo -e "  ${YEL}${BLD}${WARNINGS} warning(s) — review above${RST}"
else
  echo -e "  ${RED}${BLD}${FAILURES} failure(s)${RST}, ${YEL}${WARNINGS} warning(s)${RST} — fix the items marked ✘ above"
fi

echo -e "\n  ${BLU}Useful commands:${RST}"
echo -e "    systemctl status ${SERVICE_NAME}"
echo -e "    journalctl -u ${SERVICE_NAME} -f"
echo -e "    tail -f /var/discourse/shared/standalone/log/rails/production.log | grep -i discord"
echo -e "    DISCOURSE_API_KEY=<key> bash $0    # re-run with API key for full checks"
echo ""
