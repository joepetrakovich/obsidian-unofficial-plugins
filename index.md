---
title: Home
layout: home
---

# Obsidian Unofficial Plugins

<div>
    <span class="pending" title="This value is updated daily at midnight UTC and only includes plugin submissions that have passed validation.">Currently <span>{{ site.data.pending-plugins | size }}</span> plugins pending review
        <svg width="14" viewBox="0 0 24 24" aria-hidden="true"><use href="#svg-info"></use></svg>
    </span>
    <div class="text-grey-dk-000"><i>Last updated: {{ "now" | date: "%b %d, %Y" }}</i></div>
</div>

## A catalog of [Obsidian] plugins that have *yet-to-be* accepted into the official community plugin list.

{: .warning }
> These plugins have not been reviewed by Obsidian and could be harmful.  Try them at your own risk via the [BRAT] plugin.

<div id="main-header" class="main-header">
 {% include components/search_header.html %}
</div>

<form class="sort my-3">
    Sort by:
    <span>
      <input type="radio" id="sortByNewest" name="sort" value="newest" checked/>
      <label for="sortByNewest">Newest</label>
    </span>
    <span>
      <input type="radio" id="sortByOldest" name="sort" value="oldest" />
      <label for="sortByOldest">Oldest</label>
    </span>
</form>

<div class="plugin-grid">
{% assign pending = site.data.pending-plugins | sort: "pr_number" | reverse %}
{% for plugin in pending  %}
{% assign plugin_url = "https://github.com/" | append: plugin.repo %}
  <div data-pr="{{ plugin.pr_number }}" class="plugin p-3">
    <h4 class="fw-700 fs-5 mt-0" id="{{ plugin.id }}">{{ plugin.name }}</h4>
    <span class="fs-3 text-grey-dk-000">by {{ plugin.author | escape }}</span>
    <div>{{plugin.description | escape }}</div>
    <div class="spacer"></div>
    <span class="toolbar d-flex flex-justify-end gap-4">
        <a target="_blank" href="{{ plugin_url }}">Learn more</a>
        <a href="#" data-url="{{ plugin_url }}">Copy link</a>
    </span>
  </div>
{% endfor %}
</div>

<script>
    const grid = document.querySelector('.plugin-grid');
    const plugins = Array.from(grid.querySelectorAll('.plugin'));
    const sortForm = document.querySelector("form.sort");

   sortForm.addEventListener("change", (event) => {
        plugins.sort(function(a, b) {
            const prA = parseInt(a.dataset.pr);
            const prB = parseInt(b.dataset.pr);
            return event.target.value === 'oldest' ? prA - prB : prB - prA;
        });
            
        grid.innerHTML = '';
        plugins.forEach(function(item) {
            grid.appendChild(item);
        });
    });
</script>

[Obsidian]: https://obsidian.md
[BRAT]: https://tfthacker.com/BRAT
