# Agent Awake website

Public website: [Agent Awake](https://irshatharis.github.io/agent-awake/).

The site is plain HTML, CSS, and JavaScript. The app preview does not control a visitor's Mac.

Preview from the repository root:

```sh
python3 -m http.server 4173 --directory website --bind 127.0.0.1
```

GitHub Pages serves `website/` through `.github/workflows/pages.yml`. Push changes to
`main` to deploy, or run the workflow manually. In the repository's Pages settings,
the publishing source must be **GitHub Actions**.

Downloads are direct DMG links to GitHub releases. Keep the versioned download links
in `index.html` and the root README in sync with each published release.
Prereleases need explicit version links because GitHub excludes them from `/releases/latest`.
