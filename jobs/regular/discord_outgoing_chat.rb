# frozen_string_literal: true

# Relays a Discourse Chat message to the Discord General channel via
# Discord's Incoming Webhook (no bot token required — webhook URL is a secret).
#
# Triggered by the :chat_message_created event hook in plugin.rb.
# Runs asynchronously so the chat UI response time is unaffected.

module Jobs
  class DiscordOutgoingChat < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.community_integrations_enabled

      message_id = args[:message_id].to_i
      return if message_id.zero?

      message = ::Chat::Message.find_by(id: message_id)
      return unless message

      # Extra guard: drop if this message was itself bridged in from Discord
      # (loop prevention — the custom field check in the event hook is the
      # primary guard, but we re-check here in case of a race condition).
      return if message.custom_fields["discord_bridge_id"].present?
      return if DiscordBridge.discord_message_id_for_chat_message(message.id).present?

      username   = message.user&.username || "discourse"
      channel_id = SiteSetting.community_integrations_discourse_chat_channel_id
      DiscordBridge.post_to_discord_general(username, message.message, channel_id, message.id)
    rescue => e
      Rails.logger.error("Jobs::DiscordOutgoingChat error: #{e.class}: #{e.message}")
    end
  end
end
