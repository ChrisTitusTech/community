import Component from "@glimmer/component";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import CttCategoryList from "../../components/ctt-category-list";

export default class CttRightSidebar extends Component {
  @service router;
  @service site;

  // Resolve the gamification leaderboard component once at construction.
  // Returns null when discourse-gamification is not installed, so the
  // {{#if this.leaderboardComponent}} guard below skips it cleanly.
  leaderboardComponent = (() => {
    if (!siteSettings.community_integrations_gamification_leaderboard_id) {
      return null;
    }
    return (
      getOwner(this).resolveRegistration(
        "component:minimal-gamification-leaderboard"
      ) ?? null
    );
  })();

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
        {{#if this.leaderboardComponent}}
          <div class="rs-component rs-minimal-gamification-leaderboard">
            <this.leaderboardComponent
              @id={{siteSettings.community_integrations_gamification_leaderboard_id}}
            />
          </div>
        {{/if}}
        <div class="rs-component rs-ctt-category-list">
          <CttCategoryList />
        </div>
      </div>
    {{/if}}
  </template>
}
