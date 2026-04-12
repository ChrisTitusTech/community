# frozen_string_literal: true

# Receives inbound POSTs from the Discord bridge bot and routes them to
# DiscordBridge for processing.
#
# Security: every request must carry a valid HMAC-SHA256 signature in the
# X-Bridge-Signature header (format: "sha256=<hex>"). Requests with missing
# or incorrect signatures are rejected with 401 before any processing occurs.
#
# Route: POST /community-integrations/discord/incoming
#        (registered in plugin.rb inside Discourse::Application.routes.append)

module CommunityIntegrations
  class DiscordIncomingController < ::ApplicationController
    requires_plugin "discourse-community-integrations"

    # Discord's bot posts JSON — no browser session/CSRF involved.
    skip_before_action :verify_authenticity_token
    # The bot is not a logged-in Discourse user.
    skip_before_action :check_xhr
    before_action :ensure_bridge_enabled
    before_action :verify_hmac_signature

    def receive
      payload = JSON.parse(request.raw_post, symbolize_names: true)

      case payload[:type]
      when "chat_message"
        DiscordBridge.incoming_chat_message(payload)
      when "forum_post"
        DiscordBridge.incoming_forum_post(payload)
      when "forum_reply"
        DiscordBridge.incoming_forum_reply(payload)
      else
        Rails.logger.warn("DiscordBridge: unknown payload type '#{payload[:type]}'")
        render json: { error: "unknown type" }, status: :unprocessable_entity
        return
      end

      render json: { ok: true }, status: :ok
    rescue JSON::ParserError => e
      Rails.logger.warn("DiscordBridge: invalid JSON body: #{e.message}")
      render json: { error: "invalid JSON" }, status: :bad_request
    rescue => e
      Rails.logger.error("DiscordBridge receive error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      render json: { error: "internal error" }, status: :internal_server_error
    end

    private

    def ensure_bridge_enabled
      unless SiteSetting.community_integrations_enabled
        render json: { error: "disabled" }, status: :not_found
      end
    end

    # Validates the X-Bridge-Signature header using HMAC-SHA256.
    # Expected format: "sha256=<lowercase hex digest>"
    # Computes HMAC over the raw request body using the shared secret from
    # SiteSetting.community_integrations_discord_incoming_secret.
    def verify_hmac_signature
      secret = SiteSetting.community_integrations_discord_incoming_secret.presence
      unless secret
        Rails.logger.warn("DiscordBridge: incoming secret not configured — rejecting request")
        render json: { error: "unauthorized" }, status: :unauthorized
        return
      end

      provided_sig   = request.headers["X-Bridge-Signature"].to_s
      expected_sig   = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, request.raw_post)}"

      # Use a constant-time comparison to prevent timing attacks.
      unless ActiveSupport::SecurityUtils.secure_compare(provided_sig, expected_sig)
        Rails.logger.warn("DiscordBridge: HMAC signature mismatch — request rejected")
        render json: { error: "unauthorized" }, status: :unauthorized
      end
    end
  end
end
