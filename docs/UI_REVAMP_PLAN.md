# UI refresh: green and gold

## Direction

Give Kuber a lively, Gen Z friendly feel while keeping savings, risk, and transaction states easy to read. Green is the primary action and brand color. Gold is used for highlights, progress, and the shared pot illustration. White and pale green keep dense app screens calm.

The reference is Vercel's [Geist color guidance](https://vercel.com/geist/colors): distinct background, border, and text roles with accessible contrast. I also reviewed the independent [Geist UI GitHub repository](https://github.com/geist-org/geist-ui) for component styling patterns. The UI keeps Kuber's own components and flow.

## Palette

| Role | Color |
| --- | --- |
| Page | `#cce9d5` |
| Surface | `#ffffff` |
| Main text | `#102d20` |
| Secondary text | `#50665a` |
| Primary green | `#116b43` |
| Deep green | `#083d2b` |
| Highlight gold | `#edbd53` |

## Screen treatment

1. Welcome: young friends in the hero illustration, a strong headline, and clear benefit cards.
2. Shared controls: consistent rounded buttons, status chips, section panels, and visible focus.
3. Home and menu: deep green wallet panels, clearer number hierarchy, and lighter circle cards.
4. Tutorial and forms: inherit the same tokens and shared controls. Keep all steps, actions, wording, and navigation as implemented.

## Verification

- Check the welcome screen at phone and desktop widths.
- Confirm primary button, secondary text, and gold on deep green meet WCAG AA text contrast.
- Run the web build, tests, and Biome check.
- Review the diff for presentation-only changes.
