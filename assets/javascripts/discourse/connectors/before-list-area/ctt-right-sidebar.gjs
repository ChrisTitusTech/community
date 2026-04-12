import Component from "@glimmer/component";
import { service } from "@ember/service";
import MinimalGamificationLeaderboard from "discourse/plugins/discourse-gamification/discourse/components/minimal-gamification-leaderboard";
import CttCategoryList from "../../components/ctt-category-list";

export default class CttRightSidebar extends Component {
  @service router;
  @service site;
  @service siteSettings;

  leaderboardComponent = MinimalGamificationLeaderboard;

  get leaderboardId() {
    return this.siteSettings.community_integrations_gamification_leaderboard_id;
  }

  get showLeaderboard() {
    return this.leaderboardComponent && this.leaderboardId > 0;
  }

  get showSidebar() {
    if (this.site.mobileView) {
      return false;
    }
    // Hide on the /categories landing page — the sidebar clutters it.
    return this.router.currentRouteName !== "discovery.categories";
  }

  <template>
    {{#if this.showSidebar}}
      <div class="tc-right-sidebar">
        {{#if this.showLeaderboard}}
          <div class="rs-component rs-minimal-gamification-leaderboard">
            <this.leaderboardComponent @id={{this.leaderboardId}} />
          </div>
        {{/if}}
        <div class="rs-component rs-ctt-category-list">
          <CttCategoryList />
        </div>
      </div>
    {{/if}}
  </template>
}


