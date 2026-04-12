# frozen_string_literal: true

require "csv"
require "set"
require "digest"

module CommunityIntegrations
  # Checks whether a Discourse user is an active YouTube channel member and
  # syncs their Discourse group membership accordingly.
  #
  # ── CSV-based design ─────────────────────────────────────────────────────────
  #
  # YouTube's Memberships API is not publicly available. Instead, the channel
  # owner exports the member list from YouTube Studio as a CSV and pastes it
  # into the plugin setting `community_integrations_youtube_members_csv`.
  #
  # When a user connects their YouTube account via OAuth (youtube.readonly scope),
  # we call channels?part=id&mine=true to retrieve their YouTube channel ID and
  # store it against their Discourse account.  On each sync we look up that
  # channel ID in the parsed CSV to determine membership.
  #
  # The admin should re-export and update the CSV periodically (e.g. weekly)
  # to keep group membership accurate.
  #
  # ── API quota note ──────────────────────────────────────────────────────────
  # channels.list costs 1 unit per call.
  # At 6-hour sync for 1,000 users: 1,000 × 4 = 4,000 units/day (well within
  # the 10,000 unit/day default quota).
  module YoutubeMemberChecker
    GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
    CHANNELS_URL     = "https://www.googleapis.com/youtube/v3/channels"
    CSV_CACHE_PREFIX = "youtube_members_channel_ids"

    def self.sync_user(user)
      return unless SiteSetting.community_integrations_enabled
      return unless SiteSetting.community_integrations_youtube_members_csv.present?

      associated =
        UserAssociatedAccount.find_by(user_id: user.id, provider_name: "youtube")
      unless associated
        Rails.logger.debug(
          "YoutubeMemberChecker: user #{user.id} has not connected YouTube; skipping.",
        )
        return
      end

      user_token = refreshed_user_token(associated)
      unless user_token
        Rails.logger.warn(
          "YoutubeMemberChecker: could not obtain user token for user #{user.id}; skipping.",
        )
        return
      end

      user_channel_id = fetch_user_channel_id(user_token, associated)
      unless user_channel_id
        Rails.logger.warn(
          "YoutubeMemberChecker: could not retrieve YouTube channel ID for user #{user.id}.",
        )
        return
      end

      member = member_channel_ids.include?(user_channel_id)
      GroupSync.sync(user, SiteSetting.community_integrations_youtube_member_group, member)
    end

    # ── Private helpers ────────────────────────────────────────────────────────

    # Returns a Set of YouTube channel IDs parsed from the admin-provided CSV.
    # Cached for 1 hour, keyed by a digest of the CSV content so the cache
    # invalidates immediately when the admin updates the setting.
    def self.member_channel_ids
      csv = SiteSetting.community_integrations_youtube_members_csv
      cache_key = "#{CSV_CACHE_PREFIX}_#{Digest::MD5.hexdigest(csv)}"

      Discourse.cache.fetch(cache_key, expires_in: 1.hour) do
        parse_member_channel_ids(csv)
      end
    end
    private_class_method :member_channel_ids

    # Parses the YouTube Studio CSV export.
    # The "Link to profile" column (index 1) contains URLs like:
    #   https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxxxx
    # We extract the channel ID (UCxxx…) from each row.
    def self.parse_member_channel_ids(csv_content)
      ids = Set.new
      rows = CSV.parse(csv_content.strip, headers: true)
      rows.each do |row|
        url = row["Link to profile"].to_s
        channel_id = url[%r{/channel/(UC[^/\s]+)}, 1]
        ids.add(channel_id) if channel_id
      end
      ids
    rescue CSV::MalformedCSVError => e
      Rails.logger.error("YoutubeMemberChecker: failed to parse members CSV: #{e.message}")
      Set.new
    end
    private_class_method :parse_member_channel_ids

    # Retrieves the user's YouTube channel ID using their OAuth token.
    # Caches the channel ID in the associated account's extra data so we
    # avoid an API call on every sync if the token has been refreshed.
    def self.fetch_user_channel_id(user_token, associated)
      # Return cached channel ID if we have it stored already.
      cached = associated.extra&.dig("youtube_channel_id")
      return cached if cached.present?

      response =
        Faraday.get(
          CHANNELS_URL,
          { part: "id", mine: "true" },
          { "Authorization" => "Bearer #{user_token}" },
        )

      unless response.status == 200
        Rails.logger.error(
          "YoutubeMemberChecker: channels.list HTTP #{response.status}: " \
            "#{response.body.truncate(200)}",
        )
        return nil
      end

      channel_id = JSON.parse(response.body)["items"]&.first&.dig("id")
      return nil unless channel_id

      # Persist so future syncs don't need another API call.
      associated.update!(
        extra: (associated.extra || {}).merge("youtube_channel_id" => channel_id),
      )

      channel_id
    rescue => e
      Rails.logger.error("YoutubeMemberChecker#fetch_user_channel_id error: #{e.message}")
      nil
    end
    private_class_method :fetch_user_channel_id

    # ── User token refresh ─────────────────────────────────────────────────────

    def self.refreshed_user_token(associated)
      extra = associated.extra || {}
      token = associated.credentials&.dig("token")

      return token if token.present? && !token_expired?(extra)

      refresh_token = extra["refresh_token"]
      return nil unless refresh_token.present?

      response =
        Faraday.post(GOOGLE_TOKEN_URL) do |req|
          req.headers["Content-Type"] = "application/x-www-form-urlencoded"
          req.body =
            URI.encode_www_form(
              grant_type: "refresh_token",
              refresh_token: refresh_token,
              client_id: SiteSetting.community_integrations_youtube_client_id,
              client_secret: SiteSetting.community_integrations_youtube_client_secret,
            )
        end

      unless response.status == 200
        Rails.logger.error(
          "YoutubeMemberChecker: user token refresh failed (HTTP #{response.status}) " \
            "for associated account #{associated.id}",
        )
        return nil
      end

      data = JSON.parse(response.body)
      new_token = data["access_token"]

      associated.update!(
        credentials: (associated.credentials || {}).merge("token" => new_token),
        extra:
          extra.merge(
            "token_expires_at" => Time.now.to_i + data["expires_in"].to_i,
          ),
      )

      new_token
    rescue => e
      Rails.logger.error("YoutubeMemberChecker#refreshed_user_token error: #{e.message}")
      nil
    end
    private_class_method :refreshed_user_token

    def self.token_expired?(extra)
      expires_at = extra["token_expires_at"].to_i
      return true if expires_at.zero?
      Time.now.to_i >= expires_at - 300
    end
    private_class_method :token_expired?
  end
end
