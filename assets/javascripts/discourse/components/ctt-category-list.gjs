import Component from "@glimmer/component";
import categoryLink from "discourse/helpers/category-link";
import Category from "discourse/models/category";

export default class CttCategoryList extends Component {
  get categories() {
    const ids = siteSettings.community_integrations_sidebar_category_ids;
    if (ids && ids.trim() !== "") {
      return ids
        .split(",")
        .map((id) => Category.findById(parseInt(id.trim(), 10)))
        .filter(Boolean);
    }
    // Show all top-level categories when no IDs are configured.
    return (Category.list() ?? []).filter((c) => !c.parent_category_id);
  }

  <template>
    <h3 class="category-list__heading">Categories</h3>
    <div class="category-list__container">
      {{#each this.categories as |category|}}
        <div class="category-list__category">
          {{categoryLink category}}
        </div>
      {{/each}}
    </div>
  </template>
}
