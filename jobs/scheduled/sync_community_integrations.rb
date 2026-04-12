# frozen_string_literal: true

# Runs on a configurable interval (default: every 6 hours) to re-verify the
# subscription/sponsorship/membership status of every user who has connected
# at least one of the supported platform accounts.
#
# This catches cancellations, refunds, and bans that happen between logins,
# ensuring stale group memberships are removed in a timely fashion.
#
# The job processes users in small batches to avoid holding large data sets in
# memory and to spread API calls over time.  Each platform is processed in a
# separate pass so an error in one checker does not block the others.
class Jobs::SyncCommunityIntegrations < Jobs::Scheduled
  # Run every N hours as configured in site settings.
  # Jobs::Scheduled requires a fixed `every` value at class load time;
  # we read the setting at runtime inside execute instead of using the DSL
  # so admins can change the interval without a server restart.
  every 6.hours

  BATCH_SIZE = 50

  def execute(_args)
    return unless SiteSetting.community_integrations_enabled

    sync_twitch
    sync_github_sponsors
    sync_youtube_members
  rescue => e
    Rails.logger.error("SyncCommunityIntegrations: unexpected error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
  end

  private

  # ── Twitch ───────────────────────────────────────────────────────────────────

  def sync_twitch
    return unless SiteSetting.community_integrations_twitch_client_id.present?
    return unless SiteSetting.community_integrations_twitch_broadcaster_id.present?

    user_ids_with_account("twitch").each_slice(BATCH_SIZE) do |batch|
      User.where(id: batch).find_each do |user|
        CommunityIntegrations::TwitchChecker.sync_user(user)
      rescue => e
        Rails.logger.error(
          "SyncCommunityIntegrations: Twitch error for user #{user.id}: #{e.message}",
        )
      end
    end
  end

  # ── GitHub Sponsors ──────────────────────────────────────────────────────────

  def sync_github_sponsors
    return unless SiteSetting.community_integrations_github_sponsors_target_username.present?

    user_ids_with_account("github").each_slice(BATCH_SIZE) do |batch|
      User.where(id: batch).find_each do |user|
        CommunityIntegrations::GithubSponsorsChecker.sync_user(user)
      rescue => e
        Rails.logger.error(
          "SyncCommunityIntegrations: GitHub error for user #{user.id}: #{e.message}",
        )
      end
    end
  end

  # ── YouTube Members ───────────────────────────────────────────────────────────

  def sync_youtube_members
    return unless SiteSetting.community_integrations_youtube_members_csv.present?

    user_ids_with_account("youtube").each_slice(BATCH_SIZE) do |batch|
      User.where(id: batch).find_each do |user|
        CommunityIntegrations::YoutubeMemberChecker.sync_user(user)
      rescue => e
        Rails.logger.error(
          "SyncCommunityIntegrations: YouTube error for user #{user.id}: #{e.message}",
        )
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Returns an array of user IDs that have a connected account for +provider+.
  def user_ids_with_account(provider)
    UserAssociatedAccount
      .where(provider_name: provider)
      .where.not(provider_uid: [nil, ""])
      .pluck(:user_id)
      .uniq
  end
end
