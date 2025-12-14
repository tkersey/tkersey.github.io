---
title: Building this blog (in Zig)
date: "2025-12-14"
slug: building-this-blog
description: Notes on a small Zig static-site blog and deploying it to GitHub Pages
tags:
  - meta
  - zig
  - github-pages
  - tooling
---

I wanted a blog setup that was:

- **Small** (no framework sprawl)
- **Hackable** (easy to read end-to-end)
- **Safe by default** (no surprise HTML injection)
- **Deployable** (CI builds to a static `dist/` directory)

So I built a tiny generator in Zig that turns Markdown files under `posts/` into:

- `dist/index.html` (post list)
- `dist/<slug>.html` (one page per post)
- `dist/feed.xml` (RSS)

## Post format

Each post is a Markdown file with YAML front matter at the top:

```yaml
---
title: My Post
date: "2025-12-14"
description: Optional short summary
tags:
  - zig
  - meta
---
```

The generator treats `title` and `date` as required, and it ignores drafts:

```yaml
draft: true
```

## Markdown rendering (safe mode)

Markdown is rendered with `cmark` and configured to avoid raw HTML and dangerous link schemes.
That means the output is predictable even if I paste in something I shouldn't.

## Local workflow

The whole loop is just:

```bash
zig build
zig build serve
```

With watch enabled, `serve` rebuilds on changes (polling) so I can keep the feedback loop tight.

## Deploy

Deployment is handled by GitHub Actions building `dist/` and publishing to GitHub Pages.
Once Pages is enabled with GitHub Actions as the source, publishing is just “merge to `main`”.
