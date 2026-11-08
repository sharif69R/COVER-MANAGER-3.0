# Mobile Cover Manager (Repair X Zone)

Offline-first Android inventory app for mobile phone covers.

- Search the bundled phone catalogue (works offline). Search is instant as you type and
  understands partial names ("a15", "iphone15", "galaxy a1").
- Every result shows the phone's **back photo** and a clear status: IN STOCK, OUT OF STOCK
  or not in your list yet. Tap a photo to zoom.
- Save model, cover quantity (with +/- buttons) and an optional description.
- My stock tab: totals, search, and All / In stock / Out of stock filters.
- Local SQLite storage; no Firebase or Supabase. Saving never waits for the internet.

## How phone photos work

The first time a model is shown, the app looks for a back photo online and saves it on the
phone. After that it is loaded from the device (works offline). Models with no photo are
remembered for 7 days so the app does not keep searching; the search icon in the top bar
retries them immediately.

Sources, in order (everything works for free, no key needed):
1. **Brave Image Search** - optional and paid; skipped unless a `BRAVE_API_KEY` secret is set.
2. **DuckDuckGo image search** (free, no key, unofficial endpoint). Results are scored: official
   manufacturer sites win, the model name must match exactly (an A15 never shows an A15 Pro),
   back/rear views are preferred, and cases/covers/accessories are rejected. Official images
   get a green verified tick.
3. **Wikipedia + Wikimedia Commons** (free). Last resort; not guaranteed to be a back view.

Catalogue: https://github.com/GetTechAPI/TechAPI (CC-BY-SA 4.0; curated, not exhaustive).

## Build APK
Open GitHub Actions and run Build Android APK. Download the mobile-cover-manager-apk artifact
from the completed workflow run.
