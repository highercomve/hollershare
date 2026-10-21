# HollerShare website

Built with Zine 0.14.0, like GhostPen. Production: https://hollershare.foreachdeveloper.com/.
Privacy policy: https://hollershare.foreachdeveloper.com/privacy/.

Run `zine --port 1991` from the repository root, or `zine release -f` to produce `public/`.
The Cloudflare Pages workflow (`.github/workflows/cloudflare.yml`) deploys the site from main. No analytics, remote fonts or client-side API calls.

The canonical privacy policy is `site/content/privacy.smd`. Run `python3 scripts/sync-privacy.py`
after edits to update its offline copy in `frontend/index.html`; CI checks they match.
Self-hosted fonts include their upstream OFL licenses under `site/assets/fonts/`.
