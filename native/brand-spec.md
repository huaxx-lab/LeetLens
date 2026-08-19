# LeetLens Native Brand Spec

## Direction

- Quiet, work-focused macOS interface inspired by Codex's spatial hierarchy.
- System typography and neutral system surfaces; accent color only communicates selection, progress, and primary action.
- Liquid Glass is reserved for navigation and floating controls. Reading surfaces and data panes stay materially quiet.

## Geometry

- 8 pt spacing grid, with 4 pt only for tight icon/text relationships.
- Unified toolbar: 52 pt. Sidebar: 218-310 pt, ideal 256 pt.
- Context panel: 328 pt with 348 pt reserved layout width.
- Tool inspector: 380-620 pt, ideal 460 pt.
- Composer: 50 pt resting height, maximum width 820 pt.
- Compact controls use 28 pt visual frames and native macOS hit testing.
- Repeated content uses 6-8 pt corners. Floating glass may use 16-22 pt continuous corners.

## Iconography

- SF Symbols in hierarchical rendering for navigation and commands.
- Provider identity uses the project's original DeepSeek, Alibaba Cloud, and OpenCode artwork.
- Icon-only commands always expose a tooltip and accessibility label.

## Motion

- Interactive panel changes: interruptible 0.30 s spring with minimal bounce.
- Selection changes: 0.22 s snappy spring.
- Opacity and hover feedback: 0.16-0.18 s ease.
- Symbol state changes use SF Symbols Replace; ongoing activity uses variable color or pulse.
- No decorative ambient motion. System Reduce Motion remains authoritative.
