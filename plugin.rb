# frozen_string_literal: true

# name: discourse-community-integrations
# about: Syncs GitHub Sponsors, Twitch Subscribers, and YouTube Members to Discourse groups; bridges Discord ↔ Discourse Chat and Support Forum
# version: 0.2.0
# authors: ChrisTitusTech
# url: https://github.com/ChrisTitusTech/discourse-community-integrations

enabled_site_setting :community_integrations_enabled

# ── PT Sans font — loaded from Google Fonts via <link> in <head> ─────────────
# Injecting via register_html_builder is the reliable way to load external
# fonts in a Discourse plugin (SCSS @import of external URLs is blocked by CSP).
register_html_builder("server:before-head-close") do
  <<~HTML
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=PT+Sans:ital,wght@0,400;0,700;1,400&display=swap" rel="stylesheet">
  HTML
end

# ── Theme stylesheets ─────────────────────────────────────────────────────────
register_asset "stylesheets/common/ctt-theme.scss"
register_asset "stylesheets/desktop/ctt-desktop.scss", :desktop
register_asset "stylesheets/mobile/ctt-mobile.scss", :mobile

# ── Load auth strategies & authenticators ─────────────────────────────────────
require_relative "app/lib/auth/twitch_strategy"
require_relative "app/lib/auth/twitch_authenticator"
require_relative "app/lib/auth/youtube_authenticator"

# ── Load membership checker modules ───────────────────────────────────────────
require_relative "app/lib/community_integrations/group_sync"
require_relative "app/lib/community_integrations/twitch_checker"
require_relative "app/lib/community_integrations/github_sponsors_checker"
require_relative "app/lib/community_integrations/youtube_member_checker"

# ── Load Discord bridge ────────────────────────────────────────────────────────
# NOTE: Only lib files are require_relative'd here. Controllers live under app/
# and are auto-loaded by Rails — explicitly requiring them at boot causes a
# NameError because ApplicationController isn't defined yet at that stage.
require_relative "app/lib/community_integrations/discord_bridge"

# ── Register OAuth providers ───────────────────────────────────────────────────
auth_provider authenticator: Auth::TwitchAuthenticator.new
auth_provider authenticator: Auth::YouTubeAuthenticator.new

# ── Discord bridge: incoming HTTP route ───────────────────────────────────────
# Must use prepend (not append): append defers execution until after all of
# routes.rb is drawn — including Discourse's catch-all — so appended routes
# are inserted AFTER the catch-all and never match. prepend inserts BEFORE.
Discourse::Application.routes.prepend do
  post "/community-integrations/discord/incoming" =>
         "community_integrations/discord_incoming#receive"
end

after_initialize do
  # ── Discord bridge: register custom fields ──────────────────────────────────
  # Chat::Message custom fields (requires chat plugin to be loaded)
  if defined?(Chat::Message)
    Chat::Message.register_custom_field_type("discord_bridge_id", :string)
  end

  Topic.register_custom_field_type("discord_bridge_id", :string)
  Post.register_custom_field_type("discord_bridge_id", :string)

  # ── Discord bridge: Discourse Chat → Discord General ────────────────────────
  on(:chat_message_created) do |message, channel, _user, _extra|
    next unless SiteSetting.community_integrations_enabled
    next if message.custom_fields["discord_bridge_id"].present?

    expected_channel_id = SiteSetting.community_integrations_discourse_chat_channel_id
    next if expected_channel_id.zero? || channel.id != expected_channel_id

    Jobs.enqueue(:discord_outgoing_chat, message_id: message.id)
  rescue => e
    Rails.logger.error("DiscordBridge chat_message_created hook error: #{e.class}: #{e.message}")
  end

  # ── Discord bridge: Discourse Support Topic → Discord Forum thread ───────────
  on(:topic_created) do |topic, _opts, _user|
    next unless SiteSetting.community_integrations_enabled
    next if topic.custom_fields["discord_bridge_id"].present?

    expected_category_id = SiteSetting.community_integrations_discourse_support_category_id
    next if expected_category_id.zero? || topic.category_id != expected_category_id

    # first_post may not be committed yet; enqueue and let the job load it
    Jobs.enqueue(:discord_outgoing_forum, post_id: topic.first_post&.id || 0, is_new_thread: true)
  rescue => e
    Rails.logger.error("DiscordBridge topic_created hook error: #{e.class}: #{e.message}")
  end

  # ── Discord bridge: Discourse Support Reply → Discord Forum thread reply ─────
  on(:post_created) do |post, _opts, _user|
    next unless SiteSetting.community_integrations_enabled
    next if post.custom_fields["discord_bridge_id"].present?
    next if post.is_first_post?

    expected_category_id = SiteSetting.community_integrations_discourse_support_category_id
    next if expected_category_id.zero? || post.topic&.category_id != expected_category_id

    Jobs.enqueue(:discord_outgoing_forum, post_id: post.id, is_new_thread: false)
  rescue => e
    Rails.logger.error("DiscordBridge post_created hook error: #{e.class}: #{e.message}")
  end

  # ── GitHub Sponsors check on GitHub login ───────────────────────────────────
  # Runs asynchronously after every successful GitHub OAuth so the login
  # response time is unaffected by the GraphQL API call.
  on(:after_auth) do |authenticator, result|
    next unless result.user
    next unless SiteSetting.community_integrations_enabled

    begin
      case authenticator.name
      when "github"
        Jobs.enqueue(:check_github_sponsor, user_id: result.user.id)
      when "twitch"
        Jobs.enqueue(:check_twitch_subscriber, user_id: result.user.id)
      end
    rescue => e
      Rails.logger.error(
        "CommunityIntegrations after_auth failed for #{authenticator.name}: #{e.class}: #{e.message}",
      )
    end
  end
end
