# Source type picker

## Goal

Make `/source/sources/new` an understandable starting point for adding knowledge sources. Replace the unstyled links with equally prominent choices using the existing DuskMoon theme and shell.

## Design

- Show a back link to Sources, the existing page title, and one sentence explaining that collected items become knowledge entries.
- Render registered source types as a responsive grid of linked `dm_card` components. Each card has an icon, knowledge category when known, source name, short description, configuration hint, and a directional arrow. Use one native navigation link per card with an accessible name and description; no nested buttons or duplicate tab stops.
- Describe Trending as discovering popular repositories by language and date range, Stars as following a GitHub user's starred repositories, and RFCs as importing Internet specifications and their full text. RFC setup only requires a name and collection interval.
- Retain registry order and support additional registered types with generic presentation. Keep all presentation metadata in the web layer and translate copy through the `source` gettext domain.
- Below the choices, provide a quiet link to the existing manual project page. The configuration form for a new source has a return link to the picker.
- On narrow screens, wrap the shared appbar into two rows and let the section menu take its natural height at full width. Desktop navigation remains unchanged. This prevents horizontal overflow and a full-screen sidebar above the picker.
- Use semantic theme colors, equal-height cards, visible hover/focus states, and reduced-motion-aware transitions. Use a single column on narrow screens and three columns when space permits.

## Scope

The picker, its return navigation, shared-shell responsive sizing, translations, focused navigation tests, and the design rule clarifying fixed-choice cards. Existing collectors, source creation/validation, data model, dependencies, app navigation colors, and collection scheduling are unchanged. No publishing or Git delivery.

## Acceptance

All registered choices reach the correct existing configuration form; generic types still render. Back and manual navigation work without creating records. Existing source form tests pass. Formatting, test-environment strict compilation, and the suite pass. Inspect dark/light desktop and narrow-screen rendering on the local devenv server, including keyboard focus and horizontal overflow.
