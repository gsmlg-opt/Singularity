# Source type picker implementation plan

**Goal:** Replace the bare source-type links with clear, accessible choices.

**Architecture:** Keep the registered type list and existing routes. Add presentation-only metadata and a private card component in `SourceLive.Form`; use DuskMoon cards/icons and existing Phoenix navigation. No collector or dependency changes.

**Tech stack:** Phoenix LiveView, phoenix_duskmoon, Tailwind, Gettext.

## Steps

- [x] Update `apps/singularity_web/lib/singularity_web/live/source_live/form.ex`: add the picker header, linked card grid, type-specific purpose/description/setup text, generic fallback, manual entry link, and new-form back navigation. Preserve `type-<kind>` IDs and existing form behavior.
- [x] Extend `apps/singularity_web/test/singularity_web/live/source_live_test.exs` to exercise card navigation into the form, registered/generic types, and return/manual links.
- [x] Adjust `components/layouts.ex` and `assets/css/app.css` so the mobile appbar wraps and the section menu uses natural height instead of pushing the page below a full viewport.
- [x] Extract translations with `MIX_ENV=test` so the running dev server retains ownership of `_build/dev`; keep only source-domain catalog changes.
- [x] Run `devenv shell -- mix format --check-formatted`, `devenv shell -- env MIX_ENV=test mix compile --warnings-as-errors`, and `devenv shell -- mix test` sequentially.
- [x] Review the combined diff once. Confirm local postgres and singularity readiness and inspect desktop/mobile screenshots, theme contrast, focus, and navigation at `http://10.100.10.10:4120/source/sources/new`.
