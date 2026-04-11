# discourse-community-integrations

Discourse plugin for the ChrisTitusTech community forum. Bundles:

- **GitHub Sponsors** — syncs sponsoring users to a Discourse group via GitHub OAuth + GraphQL
- **Twitch Subscribers** — syncs subscribers via Twitch OAuth + Helix API
- **YouTube Members** — syncs channel members via Google OAuth + YouTube Data API v3
- **Chris Titus Tech dark theme** — mirrors the design of [christitus.com](https://christitus.com) (PT Sans, `#47c4f1` accent, dark `#212529` background)

---

## Installation

Discourse must already be running. Add the plugin by editing your `containers/app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/discourse/docker_manager.git
          - git clone https://github.com/ChrisTitusTech/community.git discourse-community-integrations
```

> **The clone target name `discourse-community-integrations` is required.** Font asset paths in the theme CSS use this directory name.

Then rebuild:

```bash
cd /var/discourse
./launcher rebuild app
```

After the rebuild, activate the theme in **Admin → Customize → Colors → Chris Titus Tech → Set as Default**.

---

## Repository Layout

```
plugin.rb                           ← Discourse plugin entrypoint
app/lib/
│   auth/
│   │   twitch_strategy.rb          ← OmniAuth OAuth2 strategy for Twitch
│   │   twitch_authenticator.rb     ← Discourse authenticator wrapper
│   │   youtube_authenticator.rb    ← Google OAuth connect-only (YouTube scope)
│   └── community_integrations/
│       group_sync.rb               ← Shared add/remove helper
│       twitch_checker.rb           ← Helix subscriber API
│       github_sponsors_checker.rb  ← GitHub GraphQL sponsorship check
│       youtube_member_checker.rb   ← YouTube memberships API (two-token)
config/
│   settings.yml                    ← Plugin site settings
│   locales/server.en.yml           ← Admin UI label strings
jobs/
│   regular/                        ← Async jobs triggered on login
│   └── scheduled/                  ← Periodic full re-sync (every 6 h)
assets/
│   fonts/                          ← PT Sans woff2 (reference; font loaded via Google Fonts)
│   stylesheets/
│       common/ctt-theme.scss       ← Dark theme — full color + typography
│       desktop/ctt-desktop.scss    ← Desktop-specific overrides
│       └── mobile/ctt-mobile.scss  ← Mobile-specific overrides
deploy/
│   app.yml                         ← Full Discourse Docker config (reference)
scripts/
    setup.sh                        ← One-time Ubuntu 22.04 VPS prep
    get_youtube_creator_token.py    ← Get the YouTube creator refresh token
```

---

## Configuration

All settings are under **Admin → Settings → Plugins → Community Integrations**.

| Setting | Description |
|---------|-------------|
| `community_integrations_enabled` | Master switch |
| `twitch_client_id` / `twitch_client_secret` | Twitch OAuth app credentials |
| `twitch_broadcaster_id` | Numeric channel ID (not username) |
| `twitch_subscriber_group` | Discourse group name for subscribers (default: `Twitch Subscriber`) |
| `github_sponsors_target_username` | GitHub username to check sponsorship of (default: `ChrisTitusTech`) |
| `github_sponsors_group` | Discourse group for sponsors (default: `GitHub Sponsors`) |
| `youtube_client_id` / `youtube_client_secret` | Google OAuth app credentials |
| `youtube_channel_id` | Creator's YouTube channel ID |
| `youtube_creator_refresh_token` | Creator token with `channel-memberships.creator` scope |
| `youtube_member_group` | Discourse group for members (default: `YouTube Member`) |
| `community_integrations_sync_interval_hours` | Re-sync interval in hours (1–24, default: 6) |

---

## OAuth App Setup

### Callback URL Reference

> **Error 400 / `invalid_request: Redirect URI http://… is not supported`** — Discourse is generating `http://` callback URLs instead of `https://`. The fix is to add `DISCOURSE_FORCE_HTTPS: true` to your `deploy/app.yml` (it is already present in the `deploy/app.yml` in this repo). Without it, Discourse constructs callback URLs with `http://` even when the site is served over TLS, and every OAuth provider will reject them.
>
> After adding the setting, run `./launcher rebuild app` to apply it.
>
> Other causes of redirect URI errors: wrong path (copy character-for-character from the table below), mismatched domain in `DISCOURSE_HOSTNAME`, or a trailing slash where none is expected.

| Provider | Callback URL to enter in developer console |
|----------|--------------------------------------------|
| GitHub | `https://YOUR_DOMAIN/auth/github/callback` |
| Google (login) | `https://YOUR_DOMAIN/auth/google_oauth2/callback` |
| YouTube (connect; our plugin) | `https://YOUR_DOMAIN/auth/youtube/callback` |
| Twitch (our plugin) | `https://YOUR_DOMAIN/auth/twitch/callback` |
| Patreon | `https://YOUR_DOMAIN/auth/patreon/callback` |

Common mistakes:
- Google path is `/auth/google_oauth2/callback` — the `_oauth2` suffix and trailing `/callback` are both required
- Patreon path is `/auth/patreon/callback` — not `/auth/patreon-oauth2/callback`
- All URLs must use `https://` — Discourse rejects `http` OAuth flows
- GitHub only accepts **one** callback URL per app; it must match exactly (no trailing slash)

---

### GitHub

1. <https://github.com/settings/developers> → **OAuth Apps** → **New OAuth App**
2. **Authorization callback URL**: `https://YOUR_DOMAIN/auth/github/callback`
3. Enter Client ID + Secret in **Admin → Settings → Login → GitHub** and enable `enable github logins`

GitHub OAuth is standard Discourse — no custom settings needed. The plugin checks sponsorship automatically on each GitHub login.

### Patreon

1. <https://www.patreon.com/portal/registration/register-clients> → **Create Client**
2. **Redirect URIs**: `https://YOUR_DOMAIN/auth/patreon/callback`
3. Enable the Patreon plugin in **Admin → Plugins → Patreon** and enter Client ID + Secret
4. Log in to the forum **as the creator's Patreon account** once — the plugin captures the creator token on that login
5. In **Admin → Plugins → Patreon**, map your reward tiers to the `Patron` Discourse group

### Twitch

1. <https://dev.twitch.tv/console> → **Register Your Application**
2. **OAuth Redirect URL**: `https://YOUR_DOMAIN/auth/twitch/callback`
3. Category: **Website Integration**
4. Enter Client ID, Secret, and your numeric **Broadcaster ID** in **Admin → Settings → Plugins → Community Integrations**

Find your numeric broadcaster ID (it is *not* your username):
- API: `https://api.twitch.tv/helix/users?login=YOUR_USERNAME` (requires a bearer token)
- Or use: <https://www.streamweasels.com/tools/convert-twitch-username-to-user-id/>

### YouTube + Google Login

YouTube membership verification uses two tokens and **one** Google OAuth app for both standard Google login and the YouTube connect flow.

| Token | Who | Scope | Purpose |
|-------|-----|-------|---------|
| Creator token | Channel owner | `youtube.channel-memberships.creator` | Query the member list |
| User token | Each forum member | `youtube.readonly` | Resolve their channel ID |

**Step 1 — Create a Google OAuth app**

1. <https://console.cloud.google.com> → new project → enable **YouTube Data API v3**
2. **APIs & Services → Credentials → Create OAuth Client ID** → Web Application
3. **Authorized JavaScript origins** (required by Google — base domain only, no path):
   - `https://YOUR_DOMAIN`
4. **Authorized redirect URIs** (both required):
   - `https://YOUR_DOMAIN/auth/google_oauth2/callback`
   - `https://YOUR_DOMAIN/auth/youtube/callback`
5. Copy the Client ID and Client Secret

**Step 2 — Get the creator refresh token (one-time)**

```bash
pip install google-auth-oauthlib
python3 scripts/get_youtube_creator_token.py
```

Paste the printed refresh token into plugin settings.

**Step 3 — Configure in Discourse**

- **Admin → Settings → Login → Google** — enter Client ID and Secret; enable `enable google oauth2 logins`
- **Admin → Settings → Plugins → Community Integrations** — enter YouTube Client ID, Secret, Channel ID, Creator Refresh Token

---

## Discourse Groups

Create these groups in **Admin → Groups** before enabling integrations (names must match plugin settings exactly, or update the settings to match):

| Group | Platform |
|-------|----------|
| `GitHub Sponsors` | GitHub |
| `Twitch Subscriber` | Twitch |
| `YouTube Member` | YouTube |

---

## Verify & Debug

```bash
# Tail Discourse logs for sync activity
sudo /var/discourse/launcher logs app | grep -E "(TwitchChecker|GithubSponsor|YoutubeMember|ERROR)"

# Manually trigger a full re-sync
sudo /var/discourse/launcher enter app
rails r "Jobs::SyncCommunityIntegrations.new.execute({})"
```

---

## Updating

```bash
cd /var/discourse
./launcher rebuild app
```

This pulls the latest plugin code and rebuilds the container.

---

## New Server Setup

If you're setting up the VPS from scratch:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/ChrisTitusTech/community/main/scripts/setup.sh)
```

This installs Docker, configures UFW (ports 22/80/443), adds a 2 GB swapfile, and clones `discourse_docker`. After it completes, copy `deploy/app.yml` to `/var/discourse/containers/app.yml`, fill in the `REPLACE_WITH_*` placeholders, then bootstrap.

---

## Removing Caddy and Running Discourse Standalone

If you previously had Caddy in front of Discourse and want to remove it:

**1. Stop and disable Caddy**

```bash
sudo systemctl stop caddy
sudo systemctl disable caddy
```

**2. Open ports 80 and 443 in UFW**

Caddy was holding these ports. Release them:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

**3. Update `containers/app.yml`**

Change the `expose` section to:

```yaml
expose:
  - "80:80"
  - "443:443"
```

The `deploy/app.yml` in this repo already defaults to this. `DISCOURSE_FORCE_HTTPS: true` remains correct and still needed — Discourse's own nginx uses it to issue valid `https://` OAuth callback URLs.

**4. Rebuild**

```bash
cd /var/discourse
./launcher rebuild app
```

Discourse's built-in nginx will obtain a Let's Encrypt certificate automatically on first boot, as long as:
- Your domain's DNS A record points to this server's IP
- Port 80 is reachable (Let's Encrypt HTTP-01 challenge)
- `DISCOURSE_HOSTNAME` matches the domain exactly

---
