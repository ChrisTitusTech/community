# frozen_string_literal: true

# Auth::TwitchAuthenticator — Discourse OAuth authenticator for Twitch.
#
# Extends Auth::ManagedAuthenticator so Discourse handles the UserAssociatedAccount
# lifecycle (create / find / merge) automatically.
#
# After every successful authentication the user's Twitch subscription status
# is enqueued for an async check against the configured broadcaster channel.
class Auth::TwitchAuthenticator < Auth::ManagedAuthenticator
  def name
    "twitch"
  end

  def enabled?
    SiteSetting.community_integrations_enabled && SiteSetting.community_integrations_twitch_client_id.present?
  end

  # Show Twitch as a login option on the login modal.
  def primary_login_enabled?
    enabled?
  end

  def register_middleware(omniauth)
    omniauth.provider OmniAuth::Strategies::Twitch,
                      setup:
                        lambda { |env|
                          opts = env["omniauth.strategy"].options
                          opts[:client_id] = SiteSetting.community_integrations_twitch_client_id
                          opts[:client_secret] = SiteSetting.community_integrations_twitch_client_secret
                        }
  end

  # Store the refresh token and expiry so the scheduled sync can re-verify
  # subscriptions without requiring the user to log in again.
  def after_authenticate(auth_token, existing_account: nil)
    result = super
    return result unless result.user

    persist_token_metadata(result.user, auth_token)
    Jobs.enqueue(:check_twitch_subscriber, user_id: result.user.id)
    result
  rescue => e
    Rails.logger.error("TwitchAuthenticator#after_authenticate failed: #{e.class}: #{e.message}")
    result
  end

  def after_create_account(user, auth_token)
    super
    persist_token_metadata(user, auth_token)
    Jobs.enqueue(:check_twitch_subscriber, user_id: user.id)
  rescue => e
    Rails.logger.error("TwitchAuthenticator#after_create_account failed: #{e.class}: #{e.message}")
  end

  private

  def persist_token_metadata(user, auth_token)
    associated =
      UserAssociatedAccount.find_by(user_id: user.id, provider_name: "twitch")
    return unless associated

    credentials = auth_token[:credentials] || {}
    extra = associated.extra || {}

    associated.update!(
      extra:
        extra.merge(
          "refresh_token" => credentials[:refresh_token],
          "token_expires_at" =>
            credentials[:expires_at] ||
              (Time.now.to_i + (credentials[:expires_in] || 14_400).to_i),
        ),
    )
  rescue => e
    Rails.logger.warn(
      "TwitchAuthenticator: could not persist token metadata for user #{user.id}: #{e.message}",
    )
  end
end
