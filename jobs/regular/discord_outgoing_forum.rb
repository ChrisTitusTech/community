# frozen_string_literal: true

# Relays a Discourse support-category Topic or Post to the Discord Forum channel.
#
# When is_new_thread is true:  creates a new Discord Forum thread.
# When is_new_thread is false: posts a reply into an existing Discord Forum thread
#                              (looked up from PluginStore via topic_id).
#
# Triggered by :topic_created / :post_created event hooks in plugin.rb.

module Jobs
  class DiscordOutgoingForum < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.community_integrations_enabled

      post_id       = args[:post_id].to_i
      is_new_thread = args[:is_new_thread]
      return if post_id.zero?

      post = Post.find_by(id: post_id)
      return unless post

      topic = post.topic
      return unless topic

      # Loop-prevention: skip posts that originated from Discord
      return if post.custom_fields["discord_bridge_id"].present?
      return if topic.custom_fields["discord_bridge_id"].present? && is_new_thread
      return if is_new_thread && DiscordBridge.discord_thread_id_for_topic(topic.id).present?
      return if !is_new_thread && DiscordBridge.discord_message_id_for_post(post.id).present?

      username = post.user&.username || "discourse"
      content  = post.raw.to_s.strip

      if is_new_thread
        # Create a new Discord Forum thread for this Discourse topic
        DiscordBridge.create_discord_forum_thread(
          topic.title,
          content,
          username,
          topic.id,
        )
      else
        # Find the Discord thread ID that corresponds to this Discourse topic
        discord_thread_id = DiscordBridge.discord_thread_id_for_topic(topic.id)
        unless discord_thread_id
          Rails.logger.warn(
            "Jobs::DiscordOutgoingForum: no Discord thread found for topic #{topic.id} — cannot relay reply",
          )
          return
        end

        DiscordBridge.post_to_discord_forum_thread(discord_thread_id, content, username, topic.id, post.post_number)
      end
    rescue => e
      Rails.logger.error("Jobs::DiscordOutgoingForum error: #{e.class}: #{e.message}")
    end
  end
end
