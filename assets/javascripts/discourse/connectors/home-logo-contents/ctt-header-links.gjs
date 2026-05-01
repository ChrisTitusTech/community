import Component from "@glimmer/component";
import { service } from "@ember/service";

export default class CttHeaderLinks extends Component {
  @service siteSettings;

  get logoUrl() {
    return this.siteSettings.site_logo_url || this.siteSettings.site_logo_small_url;
  }

  <template>
    <div class="ctt-header-inline">
      <a href="/" class="ctt-header-inline__logo" aria-label="Community home">
        {{#if this.logoUrl}}
          <img src={{this.logoUrl}} alt="Chris Titus Tech" />
        {{else}}
          <span>Chris Titus Tech</span>
        {{/if}}
      </a>

      <nav class="ctt-header-nav" aria-label="Primary navigation">
        <a
          href="https://christitus.com"
          class="ctt-header-nav__link ctt-header-nav__link--primary"
          target="_blank"
          rel="noopener noreferrer"
        >
          Visit ChrisTitus.com
        </a>
      </nav>
    </div>
  </template>
}
