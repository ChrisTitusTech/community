# frozen_string_literal: true

# DiscordBridge — core logic for the Discord ↔ Discourse bidirectional bridge.
#
# Responsibilities:
#   1. resolve_user      — map a Discord user to a Discourse User (cached)
#   2. incoming_*        — create Discourse Chat messages / Topics / Posts from Discord
#   3. post_to_discord_* — push Discourse content to Discord via webhook / REST API
#   4. mapping helpers   — bidirectional Discord↔Discourse ID storage in PluginStore
#
# All network calls use Net::HTTP (bundled with MRI Ruby — no extra gems needed).
# Errors are logged but never raised to the caller, so one bridge failure never
# takes down an unrelated feature.

module DiscordBridge
  PLUGIN_STORE_PREFIX = "discord-bridge"
  DISCORD_API_BASE    = "https://discord.com/api/v10"

  # ── User resolution ──────────────────────────────────────────────────────────

  # Returns [user, matched] for the given Discord identity.
  #   user    — the Discourse User to post as (never nil if the fallback account exists)
  #   matched — true when a real Discourse account was found for this Discord user;
  #             false when falling back to the configured bridge system account.
  #
  # Callers use `matched` to decide whether to add a "Discord: username:" attribution
  # prefix so it is clear who in Discord sent the message.
  #
  # Resolution order:
  #   1. PluginStore cached mapping (discord_user_id → discourse user_id)
  #   2. Username exact-match lookup (case-insensitive)
  #   3. Configured bridge/system account (matched = false)
  def self.resolve_user(discord_username, discord_user_id)
    cached_id = PluginStore.get(PLUGIN_STORE_PREFIX, "user_map_#{discord_user_id}")
    if cached_id
      user = User.find_by(id: cached_id)
      return [user, true] if user
    end

    # Try username match (Discourse usernames are unique and case-insensitive)
    user =
      User.find_by(username_lower: discord_username.downcase) ||
        User.find_by(username_lower: discord_username.downcase.gsub(/[^a-z0-9_.-]/, "_"))

    if user
      PluginStore.set(PLUGIN_STORE_PREFIX, "user_map_#{discord_user_id}", user.id)
      return [user, true]
    end

    # Fall back to the configured bridge system account
    bridge_username = SiteSetting.community_integrations_discord_bridge_username.presence || "discord-bridge"
    fallback = User.find_by(username_lower: bridge_username.downcase)
    unless fallback
      Rails.logger.warn(
        "DiscordBridge: fallback user '#{bridge_username}' not found — cannot post message from #{discord_username}",
      )
    end
    [fallback, false]
  end

  # ── Incoming: Discord → Discourse ───────────────────────────────────────────

  # Called by the incoming controller when Discord sends a General channel message.
  # payload keys: discord_msg_id, discord_username, discord_user_id, content
  def self.incoming_chat_message(payload)
    user, matched = resolve_user(payload[:discord_username], payload[:discord_user_id])
    return unless user

    channel_id = SiteSetting.community_integrations_discourse_chat_channel_id
    return if channel_id.zero?

    channel = Chat::Channel.find_by(id: channel_id)
    unless channel
      Rails.logger.warn("DiscordBridge: Chat::Channel #{channel_id} not found")
      return
    end

    # When matched to a real account the post author already identifies the sender.
    # When unmatched we post as the bridge account, so prefix the content so it is
    # clear which Discord user sent this.
    content =
      if matched
        payload[:content]
      else
        "Discord: #{payload[:discord_username]}: #{payload[:content]}"
      end

    # Set a thread-local flag so the :chat_message_created event hook in
    # plugin.rb can skip this message. The custom_fields guard alone is
    # insufficient because the event fires inside Chat::CreateMessage.call,
    # before we have a chance to save the discord_bridge_id custom field.
    Thread.current[:discord_bridge_incoming] = true
    result =
      Chat::CreateMessage.call(
        guardian: Guardian.new(user),
        params: {
          chat_channel_id: channel.id,
          message: content,
        },
      )

    if result.failure?
      Rails.logger.warn("DiscordBridge: Chat::CreateMessage failed: #{result.inspect_steps}")
      return
    end

    msg = result.message_instance
    msg.custom_fields["discord_bridge_id"] = payload[:discord_msg_id].to_s
    msg.save_custom_fields

    # Bidirectional mapping: discord msg_id ↔ discourse chat message id
    PluginStore.set(PLUGIN_STORE_PREFIX, "chat_discord_#{payload[:discord_msg_id]}", msg.id)
    PluginStore.set(PLUGIN_STORE_PREFIX, "chat_discourse_#{msg.id}", payload[:discord_msg_id].to_s)
  rescue => e
    Rails.logger.error("DiscordBridge.incoming_chat_message error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  ensure
    Thread.current[:discord_bridge_incoming] = nil
  end

  # Called when a new Discord Forum channel post arrives (creates a Discourse topic).
  # payload keys: discord_thread_id, discord_username, discord_user_id, title, content
  def self.incoming_forum_post(payload)
    user, matched = resolve_user(payload[:discord_username], payload[:discord_user_id])
    return unless user

    category_id = SiteSetting.community_integrations_discourse_support_category_id
    return if category_id.zero?

    discord_name = payload[:discord_username]
    raw_title    = payload[:title].presence || payload[:content].truncate(60)
    raw_content  = payload[:content]

    # When unmatched, attribute content explicitly so the bridge account's name
    # alone does not misrepresent who created the post.
    title   = matched ? raw_title   : "Discord: #{raw_title}"
    content = matched ? raw_content : "Discord: #{discord_name}: #{raw_content}"

    creator =
      PostCreator.new(
        user,
        title: title,
        raw: content,
        category: category_id,
        skip_validations: false,
      )

    post = creator.create
    if post.nil? || post.errors.present?
      Rails.logger.warn(
        "DiscordBridge: PostCreator failed: #{post&.errors&.full_messages&.join(", ")}",
      )
      return
    end

    unless post.topic
      Rails.logger.warn("DiscordBridge: PostCreator returned post without topic")
      return
    end

    topic = post.topic
    topic.custom_fields["discord_bridge_id"] = payload[:discord_thread_id].to_s
    topic.save_custom_fields

    # Bidirectional mapping: discord thread_id ↔ discourse topic_id
    PluginStore.set(PLUGIN_STORE_PREFIX, "thread_discord_#{payload[:discord_thread_id]}", topic.id)
    PluginStore.set(PLUGIN_STORE_PREFIX, "topic_discord_#{topic.id}", payload[:discord_thread_id].to_s)
  rescue => e
    Rails.logger.error("DiscordBridge.incoming_forum_post error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end

  # Called when a reply arrives in a Discord Forum thread.
  # payload keys: discord_thread_id, discord_msg_id, discord_username, discord_user_id, content
  def self.incoming_forum_reply(payload)
    user, matched = resolve_user(payload[:discord_username], payload[:discord_user_id])
    return unless user

    topic_id = PluginStore.get(PLUGIN_STORE_PREFIX, "thread_discord_#{payload[:discord_thread_id]}")
    unless topic_id
      Rails.logger.warn(
        "DiscordBridge: no Discourse topic found for Discord thread #{payload[:discord_thread_id]}",
      )
      return
    end

    topic = Topic.find_by(id: topic_id)
    unless topic
      Rails.logger.warn("DiscordBridge: Topic #{topic_id} not found")
      return
    end

    raw_content = payload[:content]
    content =
      if matched
        raw_content
      else
        "Discord: #{payload[:discord_username]}: #{raw_content}"
      end

    creator =
      PostCreator.new(
        user,
        raw: content,
        topic_id: topic.id,
        skip_validations: false,
      )

    post = creator.create
    if post.nil? || post.errors.present?
      Rails.logger.warn(
        "DiscordBridge: reply PostCreator failed: #{post&.errors&.full_messages&.join(", ")}",
      )
      return
    end

    post.custom_fields["discord_bridge_id"] = payload[:discord_msg_id].to_s
    post.save_custom_fields
  rescue => e
    Rails.logger.error("DiscordBridge.incoming_forum_reply error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end

  # ── Outgoing: Discourse → Discord ───────────────────────────────────────────

  # POST a chat message to Discord General channel via Incoming Webhook.
  # Discord Incoming Webhooks are POST-only (no auth header needed — token is in URL).
  # The webhook username is prefixed with "Forum: " so Discord readers can tell the
  # message originated from the Discourse forum rather than a Discord member.
  # A small subtext link lets Discord users jump directly to the chat message.
  def self.post_to_discord_general(username, content, chat_channel_id, message_id)
    webhook_url = SiteSetting.community_integrations_discord_general_webhook_url.presence
    return unless webhook_url

    link    = "#{Discourse.base_url}/chat/c/-/#{chat_channel_id}?messageId=#{message_id}"
    discord_content = "#{content}\n-# [View on forum](<#{link}>)"

    body = { username: "Forum: #{username}", content: discord_content }.to_json
    post_json(webhook_url, body, auth_header: nil)
  rescue => e
    Rails.logger.error("DiscordBridge.post_to_discord_general error: #{e.class}: #{e.message}")
  end

  # Create a new Discord Forum thread (for a new Discourse topic).
  # Returns the Discord thread_id string, or nil on failure.
  def self.create_discord_forum_thread(title, content, username, discourse_topic_id)
    forum_id  = SiteSetting.community_integrations_discord_support_forum_id.presence
    bot_token = SiteSetting.community_integrations_discord_bot_token.presence
    return unless forum_id && bot_token

    url  = "#{DISCORD_API_BASE}/channels/#{forum_id}/threads"
    topic_link = "#{Discourse.base_url}/t/#{discourse_topic_id}"
    body = {
      name: title.truncate(100),
      message: {
        content: "**Forum: #{username}**: #{content}\n-# [View on forum](<#{topic_link}>)",
      },
    }.to_json

    response_body = post_json(url, body, auth_header: "Bot #{bot_token}")
    return unless response_body

    data = JSON.parse(response_body)
    discord_thread_id = data["id"]

    if discord_thread_id
      # Store bidirectional mapping
      PluginStore.set(PLUGIN_STORE_PREFIX, "thread_discord_#{discord_thread_id}", discourse_topic_id)
      PluginStore.set(PLUGIN_STORE_PREFIX, "topic_discord_#{discourse_topic_id}", discord_thread_id)
    end

    discord_thread_id
  rescue => e
    Rails.logger.error("DiscordBridge.create_discord_forum_thread error: #{e.class}: #{e.message}")
    nil
  end

  # Post a reply message into an existing Discord Forum thread.
  # post_number is the Discourse post number within the topic (used to build a
  # direct permalink so Discord users can jump to the exact reply).
  def self.post_to_discord_forum_thread(discord_thread_id, content, username, discourse_topic_id, post_number)
    bot_token = SiteSetting.community_integrations_discord_bot_token.presence
    return unless bot_token && discord_thread_id

    post_link = "#{Discourse.base_url}/t/#{discourse_topic_id}/#{post_number}"
    url  = "#{DISCORD_API_BASE}/channels/#{discord_thread_id}/messages"
    body = { content: "**Forum: #{username}**: #{content}\n-# [View on forum](<#{post_link}>)" }.to_json
    post_json(url, body, auth_header: "Bot #{bot_token}")
  rescue => e
    Rails.logger.error("DiscordBridge.post_to_discord_forum_thread error: #{e.class}: #{e.message}")
  end

  # ── PluginStore helpers ───────────────────────────────────────────────────────

  def self.discord_thread_id_for_topic(topic_id)
    PluginStore.get(PLUGIN_STORE_PREFIX, "topic_discord_#{topic_id}")
  end

  # ── Internal HTTP helper ─────────────────────────────────────────────────────

  # Makes a POST request with a JSON body and returns the response body string.
  # auth_header: e.g. "Bot <token>", or nil for webhooks (no auth needed).
  # Returns nil on HTTP errors (logs them).
  def self.post_json(url_string, body, auth_header:)
    require "net/http"
    require "uri"

    uri = URI.parse(url_string)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.read_timeout = 10
    http.open_timeout = 5

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request["User-Agent"]   = "DiscourseDiscordBridge/1.0"
    request["Authorization"] = auth_header if auth_header

    request.body = body

    response = http.request(request)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.warn(
        "DiscordBridge HTTP #{response.code} from #{uri.host}#{uri.path}: #{response.body.to_s.truncate(200)}",
      )
      return nil
    end

    response.body
  rescue => e
    Rails.logger.error("DiscordBridge.post_json error for #{url_string}: #{e.class}: #{e.message}")
    nil
  end
end
