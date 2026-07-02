# Deploying the Sentiero website

This is a [Jekyll](https://jekyllrb.com/) site using the
[`jekyll-vitepress-theme`](https://jekyll-vitepress.dev/) gem. The marketing
landing (`index.html`) is a static page; the docs under `_*/` collections are
rendered by the theme.

## Local development

```bash
cd website
bundle install
bundle exec jekyll serve --livereload
# → http://127.0.0.1:4000
```

## Build

```bash
cd website
bundle exec jekyll build
# → static site in website/_site/
```

## Deploy

Publish the contents of `website/_site/` to any static host (GitHub Pages,
Netlify, Cloudflare Pages, S3, etc.). Because the theme is a gem (not on the
GitHub Pages whitelist), a GitHub Pages deploy must build via CI (e.g. a
GitHub Actions workflow that runs `bundle exec jekyll build` and publishes
`_site/`) rather than the native Pages build.

## Custom domain

`CNAME` carries `sentiero.app`. To change the domain, edit `CNAME` and the
`url:` value in `_config.yml`, then rebuild.
