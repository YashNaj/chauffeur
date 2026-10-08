# Accessibility audit: Settings › General

This is one unedited run of Claude Code (Sonnet) with chauffeur's tools only. The device was an iPhone 18 Pro
simulator on iOS 27.0, freshly created. The run took 7 turns and cost $0.041. The script that runs it is
[`demos/a11y.sh`](../demos/a11y.sh).

## The prompt

> Open Settings › General and audit that screen for accessibility problems a VoiceOver user would hit: buttons without
> a label, tap targets smaller than 44 by 44 points, and text that is cut off. Use snapshots with coordinates
> (snapshot all) and a screenshot if you need one. Report each finding with the element, its size, and why it
> matters. Don't change any setting.

## Findings

These are the agent's findings, as it reported them. Each was then checked by hand against
`chauffeur snapshot --all` on the same screen.

| # | Element | Size (pt) | Agent's finding | Checked |
|---|---|---|---|---|
| 1 | 9 buttons: Settings (back), About, Screen Capture, AutoFill & Passwords, Dictionary, Fonts, Keyboard, Language & Region, Trackpad & Mouse | — | None is missing a label. | Correct. All 9 have labels in the snapshot. |
| 2 | Back button "Settings" | 44×44 at 16,62 | Exactly the minimum tap size, with no margin. Not a failure. | Correct: `@16,62,44,44`. |
| 3 | List rows | 370×52 | All above the 44 pt minimum. | Correct: every row is `370,52`. |
| 4 | Intro paragraph under "General" | 333×86 at 32,271 | The accessibility tree shortens the text to "…such as software updates,…", but the screen shows all of it. The agent said this was probably the snapshot tool, not the app, and asked for a check with VoiceOver. | **Wrong: not an app problem.** chauffeur cuts screen text at 80 characters in every snapshot, by design, so a long label can't flood the agent's context. VoiceOver reads the full text. The agent's hedge was right. |
| 5 | "Trackpad & Mouse" row | 370×52 at y=841.7 | It extends past the bottom of the 874 pt screen. The agent said this is normal scrolling, not a defect. | Correct. It is the last visible row of a scrolling list. |

The agent also noted:

- The back button's label, "Settings", is the previous screen's title. That's the standard iOS pattern.
- It audited only what was on screen. It didn't scroll, and it didn't try larger Dynamic Type sizes.

**Result:** General has no real accessibility problems at the default text size. Finding 4 shows the audit is only
as good as its view of the tree. The agent flagged that doubt instead of reporting a bug it couldn't confirm.

## What chauffeur provided

| Evidence | Command |
|---|---|
| Every element's role, label, value and ref | `snapshot` |
| Each element's frame in points (`@x,y,w,h`), used for the 44×44 check | `snapshot --all` (MCP: `snapshot` with `all`) |
| The pixels, to compare the on-screen text against the tree | `screenshot` (1 px = 1 pt) |
| Getting there, with each step's change confirmed | `act tap` on Settings, then on General, and `snapshot General` to wait for the screen |

## Limits

- **The tree isn't the screen.** The audit sees what the accessibility tree exposes, which is what VoiceOver sees. It
  doesn't see every pixel. Text that is clipped on screen but whole in the tree, or the reverse, needs a screenshot.
- **Sizes are accessibility frames.** They are what the app reports to accessibility, not hit-tested touch areas. An
  app can draw a small control inside a larger frame, or the reverse.
- **Text over 80 characters is shortened in snapshots**, as finding 4 shows. Read the screenshot for long text.
- **One screen, one text size.** Many truncation bugs only appear at the larger accessibility sizes. Turn them on in
  Settings › Accessibility › Display & Text Size, which the agent can do too, then run the same prompt again.
