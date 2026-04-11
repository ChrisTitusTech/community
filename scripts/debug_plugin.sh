#!/usr/bin/env bash
# =============================================================================
# debug_plugin.sh — diagnose discourse-community-integrations plugin health
#
# Run from the VPS as root:
#   cd /var/discourse && bash /path/to/debug_plugin.sh
#
# Or copy into the container and run directly:
#   ./launcher enter app
#   bash /shared/debug_plugin.sh
#
# What this checks:
#   1. Plugin is cloned and on disk
#   2. Plugin appears in Discourse plugin registry
#   3. Required site settings exist and are non-empty
#   4. Discourse groups exist (Twitch Subscriber, GitHub Sponsors, YouTube Member)
#   5. Auth providers are registered (Twitch, YouTube)
#   6. Redis is reachable
#   7. Sidekiq job classes are loaded
#   8. Recent job errors from Sidekiq dead queue
#   9. Recent production log errors for this plugin
# =============================================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()  { echo -e "  ${GREEN}✔${NC}  $*"; }
fail()  { echo -e "  ${RED}✗${NC}  $*"; FAILURES=$((FAILURES + 1)); }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $*"; }
info()  { echo -e "  ${CYAN}→${NC}  $*"; }
section() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

FAILURES=0

# ── Detect if we're inside or outside the container ──────────────────────────
INSIDE_CONTAINER=false
if [[ -f /var/www/discourse/config/application.rb ]]; then
  INSIDE_CONTAINER=true
fi

DISCOURSE_DIR="/var/discourse"
PLUGIN_DIR="/var/lib/docker/volumes/discourse_shared_standalone_data/_data/plugins/discourse-community-integrations"

# Fallback: find the overlay mount path used by discourse_docker
if [[ ! -d "$PLUGIN_DIR" ]]; then
  PLUGIN_DIR=$(find /var/lib/docker -path "*/plugins/discourse-community-integrations" -maxdepth 10 2>/dev/null | head -1 || true)
fi

# Inside container the path is fixed
if [[ "$INSIDE_CONTAINER" == true ]]; then
  PLUGIN_DIR="/var/www/discourse/plugins/discourse-community-integrations"
fi

# =============================================================================
section "1. Plugin files on disk"
# =============================================================================

if [[ -z "$PLUGIN_DIR" || ! -d "$PLUGIN_DIR" ]]; then
  fail "Plugin directory not found. Is the container running and was the git clone successful?"
  info "Expected path: \$shared/discourse/plugins/discourse-community-integrations"
  info "Run:  ./launcher enter app && ls /var/www/discourse/plugins/"
else
  pass "Plugin directory exists: $PLUGIN_DIR"

  required_files=(
    "plugin.rb"
    "config/settings.yml"
    "config/locales/server.en.yml"
    "config/locales/client.en.yml"
    "app/lib/auth/twitch_strategy.rb"
    "app/lib/auth/twitch_authenticator.rb"
    "app/lib/auth/youtube_authenticator.rb"
    "app/lib/community_integrations/group_sync.rb"
    "app/lib/community_integrations/twitch_checker.rb"
    "app/lib/community_integrations/github_sponsors_checker.rb"
    "app/lib/community_integrations/youtube_member_checker.rb"
    "jobs/regular/check_twitch_subscriber.rb"
    "jobs/regular/check_github_sponsor.rb"
    "jobs/regular/check_youtube_member.rb"
    "jobs/scheduled/sync_community_integrations.rb"
  )

  missing=0
  for f in "${required_files[@]}"; do
    if [[ -f "$PLUGIN_DIR/$f" ]]; then
      pass "$f"
    else
      fail "MISSING: $f"
      missing=$((missing + 1))
    fi
  done

  if [[ $missing -gt 0 ]]; then
    warn "$missing files missing — the git clone may be incomplete or on wrong branch"
    if [[ "$INSIDE_CONTAINER" == true ]]; then
      info "Current git state:"
      git -C "$PLUGIN_DIR" log --oneline -5 2>/dev/null || echo "    (not a git repo)"
      git -C "$PLUGIN_DIR" status --short 2>/dev/null || true
    fi
  fi
fi

# =============================================================================
section "2. Plugin registry (requires running container)"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == false ]]; then
  if ! command -v docker &>/dev/null; then
    warn "Docker not found — skipping registry check (run inside container for full output)"
  else
    info "Checking plugin registry via rails runner..."
    docker exec app bash -c \
      "cd /var/www/discourse && RAILS_ENV=production bin/rails runner \
      'puts Discourse.plugins.map(&:name).sort.each {|n| puts n}'" 2>/dev/null \
      | grep -i "community-integrations" \
      && pass "discourse-community-integrations is registered" \
      || fail "discourse-community-integrations NOT found in plugin registry"
  fi
else
  info "Checking plugin registry..."
  registered=$(cd /var/www/discourse && RAILS_ENV=production bin/rails runner \
    'Discourse.plugins.each {|p| puts p.name}' 2>/dev/null || true)

  if echo "$registered" | grep -q "discourse-community-integrations"; then
    pass "discourse-community-integrations is registered"
  else
    fail "discourse-community-integrations NOT in plugin registry"
    info "All registered plugins:"
    echo "$registered" | sed 's/^/    /'
  fi
fi

# =============================================================================
section "3. Site settings"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == true ]]; then
  run_rails() {
    cd /var/www/discourse && RAILS_ENV=production bin/rails runner "$1" 2>/dev/null
  }

  # Master switch
  enabled=$(run_rails 'puts SiteSetting.community_integrations_enabled rescue puts "ERROR"')
  if [[ "$enabled" == "true" ]]; then
    pass "community_integrations_enabled = true"
  elif [[ "$enabled" == "false" ]]; then
    fail "community_integrations_enabled = false — plugin is disabled!"
    info "Fix: Admin → Settings → search 'community_integrations_enabled' → enable"
  else
    fail "Could not read community_integrations_enabled: $enabled"
  fi

  check_setting() {
    local key="$1"
    local label="$2"
    local val
    val=$(run_rails "puts SiteSetting.${key}.to_s.strip rescue puts 'ERROR'")
    if [[ -n "$val" && "$val" != "ERROR" && "$val" != "" ]]; then
      # Mask secrets
      if [[ "$key" == *secret* || "$key" == *token* ]]; then
        pass "$label = [set, ${#val} chars]"
      else
        pass "$label = $val"
      fi
    else
      fail "$label is EMPTY — set it in Admin → Settings (search: ${key})"
    fi
  }

  echo ""
  info "Twitch settings:"
  check_setting "community_integrations_twitch_client_id"        "twitch_client_id"
  check_setting "community_integrations_twitch_client_secret"     "twitch_client_secret"
  check_setting "community_integrations_twitch_broadcaster_id"    "twitch_broadcaster_id"
  check_setting "community_integrations_twitch_subscriber_group"  "twitch_subscriber_group"

  echo ""
  info "GitHub Sponsors settings:"
  check_setting "community_integrations_github_sponsors_target_username" "github_sponsors_target_username"
  check_setting "community_integrations_github_sponsors_group"           "github_sponsors_group"

  echo ""
  info "YouTube settings:"
  check_setting "community_integrations_youtube_client_id"              "youtube_client_id"
  check_setting "community_integrations_youtube_client_secret"          "youtube_client_secret"
  check_setting "community_integrations_youtube_channel_id"             "youtube_channel_id"
  check_setting "community_integrations_youtube_creator_refresh_token"  "youtube_creator_refresh_token"
  check_setting "community_integrations_youtube_member_group"           "youtube_member_group"
else
  warn "Run inside the container for settings checks:"
  info "./launcher enter app && bash /shared/debug_plugin.sh"
fi

# =============================================================================
section "4. Discourse groups"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == true ]]; then
  check_group() {
    local name="$1"
    local exists
    exists=$(run_rails "puts Group.find_by(name: '${name}').present?")
    if [[ "$exists" == "true" ]]; then
      local count
      count=$(run_rails "puts Group.find_by(name: '${name}').users.count rescue puts 0")
      pass "Group '$name' exists ($count members)"
    else
      fail "Group '$name' does NOT exist — create it in Admin → Groups"
    fi
  }

  check_group "Twitch Subscriber"
  check_group "GitHub Sponsors"
  check_group "YouTube Member"
else
  warn "Skipping group check (not inside container)"
fi

# =============================================================================
section "5. Auth providers registered"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == true ]]; then
  providers=$(run_rails 'Discourse.enabled_authenticators.map(&:name).each {|n| puts n}' || true)

  for provider in twitch youtube; do
    if echo "$providers" | grep -q "^${provider}$"; then
      pass "Auth provider '$provider' is registered and enabled"
    else
      fail "Auth provider '$provider' NOT registered"
      info "Check: SiteSetting.community_integrations_twitch_client_id is set"
      info "Check: Auth::TwitchAuthenticator is loaded (see section 1)"
    fi
  done

  info "All active auth providers: $(echo "$providers" | tr '\n' ' ')"
else
  warn "Skipping auth provider check (not inside container)"
fi

# =============================================================================
section "6. Redis connectivity"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == true ]]; then
  pong=$(redis-cli ping 2>/dev/null || echo "FAILED")
  if [[ "$pong" == "PONG" ]]; then
    pass "Redis is reachable (PONG)"
    mem=$(redis-cli INFO memory 2>/dev/null | grep "used_memory_human" | head -1 | tr -d '\r')
    maxmem=$(redis-cli CONFIG GET maxmemory 2>/dev/null | tail -1 | tr -d '\r')
    info "Redis memory: $mem  maxmemory=$maxmem"
    if [[ "$maxmem" == "0" ]]; then
      info "maxmemory=0 means no limit (good for single-server Discourse)"
    fi
  else
    fail "Redis is NOT reachable — run: sv start redis"
  fi
else
  # Check from outside via docker exec
  if command -v docker &>/dev/null 2>&1; then
    pong=$(docker exec app redis-cli ping 2>/dev/null || echo "FAILED")
    if [[ "$pong" == "PONG" ]]; then
      pass "Redis is reachable inside container"
    else
      fail "Redis is NOT reachable inside container"
    fi
  else
    warn "Skipping Redis check (not inside container, no docker command)"
  fi
fi

# =============================================================================
section "7. Sidekiq job classes loaded"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == true ]]; then
  for job in CheckTwitchSubscriber CheckGithubSponsor CheckYoutubeMember SyncCommunityIntegrations; do
    exists=$(run_rails "puts defined?(Jobs::${job}) ? 'yes' : 'no'" || echo "no")
    if [[ "$exists" == "yes" ]]; then
      pass "Jobs::$job is loaded"
    else
      fail "Jobs::$job is NOT loaded — check require_relative in plugin.rb"
    fi
  done
else
  warn "Skipping Sidekiq job class check (not inside container)"
fi

# =============================================================================
section "8. Sidekiq dead queue (recent failures)"
# =============================================================================

if [[ "$INSIDE_CONTAINER" == true ]]; then
  dead=$(run_rails "
    require 'sidekiq/api'
    dead = Sidekiq::DeadSet.new
    count = dead.size
    puts \"Dead queue size: #{count}\"
    dead.first(5).each do |j|
      klass = j['class']
      err   = j['error_message'].to_s.truncate(120)
      at    = Time.at(j['failed_at'].to_i).utc.iso8601 rescue 'unknown'
      puts \"  [#{at}] #{klass}: #{err}\"
    end
  " || true)

  if echo "$dead" | grep -q "Dead queue size: 0"; then
    pass "Sidekiq dead queue is empty"
  else
    warn "Sidekiq dead queue has entries:"
    echo "$dead" | sed 's/^/    /'
    info "Clear dead queue: Admin → Sidekiq → Dead (or rails runner 'Sidekiq::DeadSet.new.clear')"
  fi

  # Also check retry queue for community integration jobs
  retries=$(run_rails "
    require 'sidekiq/api'
    rs = Sidekiq::RetrySet.new
    relevant = rs.select {|j| j['class'].to_s.include?('Twitch') || j['class'].to_s.include?('Github') || j['class'].to_s.include?('Youtube') || j['class'].to_s.include?('Community')}
    if relevant.empty?
      puts 'No plugin jobs in retry queue'
    else
      puts \"#{relevant.size} plugin job(s) queued for retry:\"
      relevant.first(5).each {|j| puts \"  #{j['class']}: #{j['error_message'].to_s.truncate(100)}\"}
    end
  " || true)
  info "$retries"
else
  warn "Skipping Sidekiq queue check (not inside container)"
fi

# =============================================================================
section "9. Recent production log errors for this plugin"
# =============================================================================

LOG_PATH=""
if [[ "$INSIDE_CONTAINER" == true ]]; then
  LOG_PATH="/shared/log/rails/production.log"
elif [[ -f "/var/discourse/shared/standalone/log/rails/production.log" ]]; then
  LOG_PATH="/var/discourse/shared/standalone/log/rails/production.log"
fi

if [[ -n "$LOG_PATH" && -f "$LOG_PATH" ]]; then
  echo ""
  info "Last 20 plugin-related errors in production.log:"
  grep -i -E "(TwitchChecker|GithubSponsor|YoutubeMember|SyncCommunity|discourse-community|community_integrations)" \
    "$LOG_PATH" 2>/dev/null | grep -i "error\|warn\|fatal\|exception" | tail -20 \
    | sed 's/^/    /' \
    || info "  (no plugin errors found in production.log)"
else
  warn "production.log not accessible from current context"
  info "Run inside container: grep -i 'TwitchChecker\|GithubSponsor\|YoutubeMember' /shared/log/rails/production.log | tail -30"
fi

# =============================================================================
section "10. Quick manual test commands"
# =============================================================================

echo ""
info "To manually trigger a sync for a specific user (replace USER_ID):"
echo "    cd /var/www/discourse && RAILS_ENV=production bin/rails runner \\"
echo "      'CommunityIntegrations::TwitchChecker.sync_user(User.find(USER_ID))'"
echo ""
info "To manually trigger the full scheduled sync:"
echo "    cd /var/www/discourse && RAILS_ENV=production bin/rails runner \\"
echo "      'Jobs::SyncCommunityIntegrations.new.execute({})'"
echo ""
info "To check a specific user's connected accounts:"
echo "    cd /var/www/discourse && RAILS_ENV=production bin/rails runner \\"
echo "      'puts UserAssociatedAccount.where(user_id: USER_ID).pluck(:provider_name, :provider_uid)'"
echo ""
info "To reload the plugin without full rebuild (dev only — not for production):"
echo "    cd /var/discourse && ./launcher restart app"

# =============================================================================
section "Summary"
# =============================================================================

echo ""
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed!${NC}"
else
  echo -e "${RED}${BOLD}$FAILURES check(s) failed — review the ✗ items above.${NC}"
fi
echo ""
