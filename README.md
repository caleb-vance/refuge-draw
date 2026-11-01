# Refuge Rat

Prototype guide to California refuge waterfowl lotteries. It uses the Ruby that ships with macOS and needs no other installs.

    ruby server.rb 8080      # serves the site and pulls CDFW data every 15 minutes
    ruby build.rb            # pulls fresh data and rewrites public/index.html

- `src/refuges.json`: refuge rules, map links and 2025-26 odds, entered by hand from CDFW PDFs. Pin locations are approximate.
- `lib/cdfw.rb`: reads CDFW's vacancy draw pages and hunt results.
- `lib/pdf_text.rb`: reads text from those PDFs.
- `src/app.html`: the app. `public/index.html` is generated from it, so don't edit that file.

Map layers: `ruby tools/overlays.rb` renders GPS-tagged hunt map PDFs to `public/overlays/` and pulls official USFWS and CDFW boundaries to `public/boundaries.json`. Rerun it when CDFW posts new maps. It needs macOS for PDF rendering.

Hosting: `.github/workflows/deploy.yml` publishes `site/` to GitHub Pages and refreshes CDFW data every 30 minutes. In the repo, set Settings > Pages > Source to GitHub Actions.

Blind results: `ruby tools/blinds.rb` reads USFWS blind-by-blind PDFs into `public/blinds.json`. Rerun it and add new file names when USFWS posts a newer season.

Draw night: the workflow is scheduled every 5 minutes from 8 to 9 PM Pacific, but GitHub can delay or skip these runs, and open pages check `snapshot.json` every 2 minutes in that window.
