# Agent Awake website

Public website: [https://agent-awake.finegoose32.chatgpt.site](https://agent-awake.finegoose32.chatgpt.site).

A buildless, single-page download and setup guide. `index.html`, `styles.css`, `app.js`,
and `assets/` are the complete site. The interactive product illustration uses synthetic
state and does not control a visitor's Mac.

Preview with `python3 -m http.server 4173 --directory website --bind 127.0.0.1` from
the repository root. Versioned GitHub release URLs are intentionally pinned because
the current release is a prerelease. Update the download, notes, and checksum URLs
together when releasing a new version. See `docs/RELEASING.md` for publication details.

The durable Sites project ID is in `.openai/hosting.json`. Copy that manifest to
`.build/site/.openai/hosting.json` and the public assets to `.build/site/dist/` when
preparing a deployment. Reuse this project; do not create a new Site for updates.
