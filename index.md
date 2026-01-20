---
title: Home
layout: home
---

# Obsidian Unofficial Plugins

## A catalog of [Obsidian] plugins that have *yet-to-be* accepted into the official community plugin list.

{: .warning .mb-6 }
> These plugins have not been reviewed by Obsidian and could be harmful.  Try them at your own risk via the [BRAT] plugin.

<div class="plugin-grid">
{% for plugin in site.data.pending-plugins %}
{% assign plugin_url = "https://github.com/" | append: plugin.repo %}
  <div class="plugin p-3">
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

[Obsidian]: https://obsidian.md
[BRAT]: https://tfthacker.com/BRAT
