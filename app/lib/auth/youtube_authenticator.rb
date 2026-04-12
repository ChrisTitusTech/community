# frozen_string_literal: true

# Auth::YouTubeAuthenticator — "Connect YouTube Account" OAuth flow.
#
# This authenticator is intentionally a CONNECT-ONLY provider:
#   - It does NOT appear on the login page as a primary login method.
#   - It does NOT create new Discourse accounts.
#   - It appears in a user's preferences under "Connected Accounts" so
#     they can voluntarily link their YouTube/Google account.
#
# Why a separate authenticator instead of the built-in google_oauth2?
# The membership verification requires the youtube.readonly scope, which is
# not requested by the standard Discourse Google login flow. This provider
# uses a dedicated GCP OAuth app configured with that extra scope so the
# user is only asked for YouTube permissions when they explicitly connect.
#
# Token storage:
#   The access token and refresh token are stored in UserAssociatedAccount
#   under provider_name "youtube".  The YoutubeMemberChecker uses the stored
#   refresh token to obtain a fresh access token when checking membership,
#   and the creator refresh token (site setting) to query the member list.
class Auth::YouTubeAuthenticator < Auth::ManagedAuthenticator
  def name
    "youtube"
  end

  def enabled?
    SiteSetting.community_integrations_enabled && SiteSetting.community_integrations_youtube_client_id.present?
  end

  # Do NOT show this provider on the login modal — it only shows in
  # user preferences under "Associated Accounts" / "Connected Accounts".
  def primary_login_enabled?
    false
  end

  # Allow users with an existing Discourse account to connect their YouTube.
  def can_connect_existing_account?
    true
  end

  def register_middleware(omniauth)
    # Re-use omniauth-google-oauth2 (already bundled with Discourse) but
    # register it under the name "youtube" so it doesn't conflict with the
    # standard google_oauth2 provider.
    omniauth.provider :google_oauth2,
                      name: :youtube,
                      setup:
                        lambda { |env|
                          opts = env["omniauth.strategy"].options
                          opts[:client_id] = SiteSetting.community_integrations_youtube_client_id
                          opts[:client_secret] = SiteSetting.community_integrations_youtube_client_secret
                          # Request offline access so we receive a refresh token
                          # that can be used by the scheduled sync job.
                          opts[:access_type] = "offline"
                          # Force consent prompt to guarantee the refresh token
                          # is returned even if the user has authorised before.
                          opts[:prompt] = "consent"
                          opts[:scope] =
                            "email profile https://www.googleapis.com/auth/youtube.readonly"
                        }
  end

  def after_authenticate(auth_token, existing_account: nil)
    result = super
    return result unless result.user

    persist_token_metadata(result.user, auth_token)
    Jobs.enqueue(:check_youtube_member, user_id: result.user.id)
    result
  rescue => e
    Rails.logger.error("YouTubeAuthenticator#after_authenticate failed: #{e.class}: #{e.message}")
    result
  end

  def after_create_account(user, auth_token)
    super
    persist_token_metadata(user, auth_token)
    Jobs.enqueue(:check_youtube_member, user_id: user.id)
  rescue => e
    Rails.logger.error("YouTubeAuthenticator#after_create_account failed: #{e.class}: #{e.message}")
  end

  private

  def persist_token_metadata(user, auth_token)
    associated =
      UserAssociatedAccount.find_by(user_id: user.id, provider_name: "youtube")
    return unless associated

    credentials = auth_token[:credentials] || {}
    extra = associated.extra || {}

    associated.update!(
      extra:
        extra.merge(
          "refresh_token" => credentials[:refresh_token],
          "token_expires_at" =>
            credentials[:expires_at] ||
              (Time.now.to_i + (credentials[:expires_in] || 3_600).to_i),
        ),
    )
  rescue => e
    Rails.logger.warn(
      "YouTubeAuthenticator: could not persist token metadata for user #{user.id}: #{e.message}",
    )
  end
end
