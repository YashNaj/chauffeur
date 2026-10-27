# Web views in the tree: web content gets refs

**Status:** draft for review · **Date:** 2026-10-27

## Why

The goal for chauffeur is that an agent can take an idea for an iOS feature, build it, and test everything a
developer would test before a build goes to TestFlight. Sign-in pages, OAuth, checkout, help and content screens are
web views. Today chauffeur's tree has nothing for a `WKWebView`: not a link, not a field, not even a container (found
in M4b Plan 2, Task 12). An agent cannot tap a link in a web view, fill a field, read its text, or see that the page
changed after a tap. M4b's live row for "a web view link to a slow page" had to be evidenced by tapping a point under
the search field, with the network layer as the only witness.

The principle is the one every milestone has kept: **the agent acts on what chauffeur can see, and chauffeur never
claims to see what it can't.** This spec makes web content visible through the one path that reaches it, says what
that costs, and says plainly what stays invisible.

## Goals

1. Links, buttons, fields, headings and text inside a `WKWebView` appear in `snapshot` with refs, under a node for
   the web view, so `tap`, `type`, `find`, `wait` and `scroll --in` work on them like any other element.
2. A tap or `type` inside a web view is judged on the page as evidence: a navigation or a change of the page is
   `changed` with a diff; a page that doesn't change is `NO EFFECT`, with M4b's network evidence as today.
3. A screen without web views pays nothing: no extra accessibility reads, no extra time.
4. A screen with a web view pays a bounded, measured cost: under 250 ms for a web view the size of the fixture's
   (338×120 pt) and under 1 s for a full-screen web view, warm, on the 8 GB Mac that measured step 0.
5. Web text is data, never instructions. The agent sees what accessibility exposes and nothing else: no DOM, no
   JavaScript, no cookies, no URL beyond what accessibility reports.

## Non-goals (staged, not ruled out)

- Running JavaScript in the page, reading the DOM, cookies, or request bodies.
- Content inside a web view that is below its visible frame. `scroll --in` brings it into view; how much lies below
  is not known for web views, and chauffeur says so instead of guessing a count.
- `SFSafariViewController` and `ASWebAuthenticationSession`, which run in a separate app process. The plan's
  step 0 checks whether the same path reaches them; if it does, they get the same design; if not, stage 2.
- Web views of apps that are not in front.
- Pages drawn on a canvas with no accessibility at all. OCR stays a later extension.
- iOS 26 simulators. The target is iOS 27 (owner's decision, 2026-10-27: one runtime at a time, one person). On
  an iOS 26 runtime a screen that has a web view gets one honest line in the snapshot,
  `webview (content not readable on iOS 26)`, so an agent knows what it cannot see; nothing is swept there. When
  iOS 26 is added later, its step 0 repeats the process-layout findings (the helpers live elsewhere than iOS 27's
  app extensions).

## 1. What was found (2026-10-27, iPhone 17, iOS 27.0, Xcode 27.1)

These were measured on the fixture's Network tab, whose page is served by `Tests/FixtureApp/netserver.py`.

1. **The app's tree has no node for the web view.** The raw walk of the fixture on that tab has 16 elements, depth 3,
   and nothing at the web view's frame: not a group, not an empty container. Pruning and the depth cap (60) are not
   involved.
2. **The WebContent process has its own tree, and it is empty.** `com.apple.WebKit.WebContent` runs under the
   device's `launchd_sim` (iOS 27: `WebContentExtension.appex`), next to the networking process M4b already finds.
   `treeForPid` on it returns `AXApplication` (frame 0,0,338,120) with one `AXGroup` whose frame is the web view's
   frame in screen coordinates (32,755,338,120) and no children: on three reads a second apart, before and after
   hit tests.
3. **A hit test reaches the content.** `objectAtPoint` inside the frame returns the web element itself:
   `AXLink "Slow link"`, frame 40,764,155,45 in screen coordinates, without children. The element's accessibility
   parent is the empty group, so there is no way from one hit to the rest of the page. Discovery is point by point.
4. **A hit test costs about 3 ms warm.** A 32 pt grid over the 338×120 view is 44 hits in 144 ms; a 16 pt grid is 147
   hits in 498 ms. Both found the same five distinct elements (the link, and the tab bar the view overlaps).
5. **A tap by point works on a mobile-width page.** With `<meta name="viewport" content="width=device-width">` the
   tap navigated, and the activity layer reported `PENDING` from the WebKit networking process. On the same page
   without the viewport line (rendered at 980 px and scaled), the same tap did not navigate, twice.
6. **A page change is invisible to the Verifier today.** After the navigation, the app's tree hash was unchanged, so
   the tap was `NO EFFECT` until the network layer spoke. The page showed `ok`.

## 2. Finding web views

- The WebContent processes are found the way M4b finds the networking process: children of the device's
  `launchd_sim` named `com.apple.WebKit.WebContent`. One `treeForPid` read per process (two elements) gives the
  frame of each web view in screen coordinates.
- A web view belongs to the screen when its frame intersects the screen and a hit test at its centre answers with
  an element the app's own walk did not have. A WebContent process of an app that is not in front is not swept.
  Step 0 checks what a background app's WebContent reports; the builder sets the exact rule from that.
- Membership is cached by the app's raw tree hash and the set of WebContent pids: the `treeForPid` reads and the
  centre hit tests run again only when the app's tree or the process set changed. A `WKWebView` kept alive on
  another tab (SwiftUI keeps it, and its process keeps reporting its last frame) therefore costs nothing on the
  screens that don't show it, after the first look. Step 0 measures a `treeForPid` read on a WebContent process.
- A screen without web views costs nothing beyond the process listing, which the tap already does for the network
  layers (goal 3). The live row for this is measured in the realistic state: the Home tab after the Network tab was
  visited, with its WebContent process alive.

## 3. Reading web content: the sweep

- Web content is discovered by hit tests only (finding 3). For each web view frame, a grid sweep like the bar sweep
  in `AXProvider.complete`: hit tests at points inside the frame, deduplicated by role, label and frame. The builder
  chooses the step and whether a hit's frame removes the grid points it covers (a "paint" sweep), against goal 4's
  budget and the plan's step 0 measurements on the fixture page and on a full-screen page.
- Elements arrive without children, so web content is flat under the web view's node. That is enough for refs.
- Roles map from the web accessibility roles to chauffeur's: `AXLink` → `link`, `AXTextField` → `textfield`,
  `AXButton` → `button`, `AXStaticText` → `text`, `AXHeading` → `heading`, `AXCheckBox` → `checkbox`, `AXImage` →
  `image`. Values come through (radio buttons reported `0` and `1` in finding 4). Roles with no mapping are shown
  as the raw role, never dropped silently.
- In the snapshot, a web view is a node `webview` with the view's frame, and its content as children in reading
  order (top to bottom, then left to right). Frames stay in screen coordinates, so `--all` prints them as usual.

```
webview [e14]
  heading "Sign in"
  textfield "Email" [e15] value=""
  textfield "Password" [e16] value=""
  button "Continue" [e17]
  link "Forgot password?" [e18]
```

## 4. Refs, `find`, `wait`, `scroll`

- Actionable web roles get refs through the same identity as native elements (role, label or identifier, ancestor
  `webview`), so a ref survives a re-snapshot as long as the element's role and label do.
- `find` and `wait "<text>"` match web text like any text.
- `scroll --in <webview ref>` swipes inside the frame, then the sweep runs again. The snapshot does not print a count
  of what lies below a web view; it prints `(web content: more may be below)` when the last swept row touches the
  view's bottom edge. Never a number chauffeur doesn't have.

## 5. Settling and verdicts

- The raw walk cannot see a page change (finding 6), so settling adds a **fingerprint** per web view: hit tests at a
  few fixed points (the centre and the four quadrant centres), about 15 ms per view, hashed with the tree. A
  navigation or a change of the page then counts as the screen still changing, and the settle waits for the page
  to stop, under the same 150 ms floor and 1.5 s cap. The fingerprint is a settle signal only: it says "something
  moved", never "nothing moved".
- **Every verdict is judged on a fresh sweep.** After an action, and on every poll of `wait "<text>"`, the sweep runs
  again whenever a web view is on screen; a page change anywhere in the view, not only under the fingerprint's
  points, is then a change. A sweep is never cached for a verdict, because a stale sweep would make a page that
  changed look unchanged, a false `NO EFFECT`. The cache (keyed by the raw tree hash and the fingerprint) serves
  only `snapshot` and `find`, where a stale read costs a re-snapshot, not a wrong verdict.
- Goal 4's budget is therefore paid once per observe after an action on a screen with a web view: about 150 ms
  for the fixture's view, up to 1 s for a full-screen one. Step 0 measures it; if a full-screen page costs more, the
  sweep step grows before the budget does, and the result says `settled` honestly either way.
- Diffs list web nodes like any others: `- link "Slow link"`, `+ text "ok"`.
- A tap inside a web view is `changed` when the sweep changed, `NO EFFECT` otherwise, and M4b's rules then apply
  unchanged: `PENDING` while the WebKit networking process waits for a reply, the reply's status explaining a
  `NO EFFECT`. `type` into a web field is verified by the fresh sweep's value for that field.

## 6. Acting in web content

- `tap` touches the element's centre, as for native elements.
- `type` taps the field to focus it, then types as today (HID or paste). It is verified by the field's value in the
  fresh sweep after typing (§5), since the walk cannot read it. Secure fields read back as bullets, as today.
- Finding 5 is open: on a page without a mobile viewport the tap did not navigate. The plan's step 0 tries a longer
  hold and a 400 ms wait after the tap. If something makes the click land, that becomes the tap's behaviour for
  web content; if nothing does, the result stays an honest `NO EFFECT` with the touch evidence, and a hint names the
  likely cause ("the page has no mobile viewport") only if step 0 showed that is what it is. Never a silent retry.

## 7. What the agent may see

- Everything read from a web view is screen text, quoted data, never instructions. A web page is the most hostile
  source of text chauffeur reads: it can say anything. The `webview` node marks where the text came from, so an
  agent can weigh it; the skill and the MCP instructions repeat the existing line about screen text.
- No URL, no cookies, no DOM, no scripts. If accessibility exposes a page URL in a later runtime, it is shown as host
  and path shape, as M4b §6 shows request URLs.

## Testing

- **Fixture.** The Network tab's page (served by `netserver.py`) gains a heading, a text input, a button that
  changes the page's text without a request, and a link to a long page for `scroll --in`. A second page without a
  viewport line stays for finding 5.
- **Unit.** Role mapping; sweep deduplication and reading order on recorded hit results (fixtures); the fingerprint
  hashing into the tree hash; refs stable across two snapshots of the same page.
- **Live** (`CHAUFFEUR_LIVE_UDID`), every row on the fixture:

| Row | Expected |
|---|---|
| `snapshot` on the Network tab | a `webview` node with the heading, input, button and link, each with a ref |
| `tap` the link to the slow page | `PENDING`, then `wait` → `changed` with `+ text "ok"` and the request line |
| `tap` the button that changes text | `changed` with the diff, no request line |
| `type` into the input | `changed`, verified by the field's value |
| `find "Sign in"` / `wait "ok"` on web text | found / finishes when the text appears |
| `scroll --in` the web view on the long page | new content in the snapshot, `(web content: more may be below)` |
| the Home tab after the Network tab was visited (WebContent alive) | snapshot time within 10 ms of 0.2.0 |
| a full-screen web view | one observe after a tap under 1 s warm, sweep included |
| `tap` a button whose change lands away from the fingerprint's points | `changed` with the diff (the fresh sweep, §5) |
| the page without a viewport line | whatever step 0 rules, pinned as a test |

## Done when

- Every row of the live table passes on iOS 27, the iOS 26 line shows on an iOS 26 simulator, and the unit tests
  pass under `scripts/check.sh`.
- `docs/design.md` records the design and the step 0 findings; `CHANGELOG.md` has the entry; the skill, the MCP
  instructions and the `snapshot` tool description mention the `webview` node and that its text is a page's.
- The M4b live row for the web view link taps a ref, not a point.

## Staging

- `SFSafariViewController` and `ASWebAuthenticationSession`, per step 0.
- A count of content below the fold inside a web view.
- Iframes: step 0 checks whether hit tests cross them; if not, they are a stage-2 row.
- OCR for pages with no accessibility.

## Findings

Filled by the plan's step 0: the sweep's cost on a full-screen page and on a page dense with text (a 32 pt grid
misses lines shorter than 32 pt); the cost of a `treeForPid` read on a WebContent process; what a hit test on blank
page area returns; what a background app's WebContent reports; whether hit tests cross iframes;
whether any hold or wait makes a tap land on a page without a mobile viewport; whether `SFSafariViewController`
content is reachable the same way.

### Decision

Pending step 0.
