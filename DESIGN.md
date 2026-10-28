---
version: alpha
name: SmartSpend
description: SmartSpend's design language — a phone-first personal-finance app in a warm earth palette. Calm sand and charcoal surfaces carry rounded cards, large bold titles and big tabular money figures; each spending category owns one muted earth colour (terracotta, slate blue, dusty rose, pistachio...) that is used for its dot, chart and card and nowhere else. Light and dark mode share the same category colours. Interaction is quiet but always answers: everything tappable grows a little under the pointer and shrinks when pressed.

colors:
  # Surfaces and text, light mode (AppColors.light)
  background: "#E8E2D6"
  card: "#FBF8F2"
  raised: "#E0D9CC"
  line: "#E3DCCF"
  text: "#1C1B1F"
  muted: "#7D766C"
  good: "#4F7A45"
  good-tint: "#DCE8D3"
  warn: "#A86F12"
  bad: "#B4483A"
  button: "#1C1B1F"
  on-button: "#FBF8F2"
  card-shadow: "#3C281447"
  # Surfaces and text, dark mode (AppColors.dark)
  background-dark: "#171513"
  card-dark: "#2B2825"
  raised-dark: "#3A3632"
  line-dark: "#423D38"
  text-dark: "#F5F2EC"
  muted-dark: "#9C958B"
  good-dark: "#7FB36F"
  good-tint-dark: "#2E3A28"
  warn-dark: "#E0A84E"
  bad-dark: "#E07A6A"
  button-dark: "#F5F2EC"
  on-button-dark: "#1C1B1F"
  card-shadow-dark: "#00000059"
  # Category colours, same in both modes (AppPalette); text on them is always ink
  ink: "#1C1B1F"
  food: "#D28A5A"
  transport: "#7E9DB5"
  shopping: "#C98D97"
  bills: "#B5BE78"
  subscriptions: "#A897BC"
  entertainment: "#DDB45C"
  housing: "#A97C5E"
  health: "#7DB2AC"
  fees: "#9C8C7C"
  cash: "#E3B8A0"
  other: "#BFB4A2"
  income: "#7DAE6E"
  # Wallet cards, in account order, and the All Accounts card
  wallet-1: "#35506D"
  wallet-2: "#B08F55"
  wallet-3: "#6E5A7E"
  wallet-4: "#7A5A48"
  wallet-5: "#4F6B78"
  wallet-all: "#46604E"
  # Desk behind the phone frame on wide screens
  desk: "#D8D1C6"
  desk-dark: "#0B0A09"

typography:
  large-title:
    fontFamily: system sans (SF Pro on Apple devices)
    fontSize: 34px
    fontWeight: 700
    letterSpacing: -0.9px
  money-hero:
    fontFamily: system sans
    fontSize: 34px
    fontWeight: 700
    letterSpacing: -0.8px
  money-card:
    fontFamily: system sans
    fontSize: 32px
    fontWeight: 700
    letterSpacing: -0.6px
  section-title:
    fontFamily: system sans
    fontSize: 20px
    fontWeight: 700
    letterSpacing: -0.4px
  body-strong:
    fontFamily: system sans
    fontSize: 15px
    fontWeight: 500
  body:
    fontFamily: system sans
    fontSize: 15px
    fontWeight: 400
  body-sm:
    fontFamily: system sans
    fontSize: 13px
    fontWeight: 400
  caption:
    fontFamily: system sans
    fontSize: 12px
    fontWeight: 400
  pill:
    fontFamily: system sans
    fontSize: 12.5px
    fontWeight: 700
  segment:
    fontFamily: system sans
    fontSize: 13px
    fontWeight: 600
  tab-label:
    fontFamily: system sans
    fontSize: 10.5px
    fontWeight: 700

rounded:
  sm: 10px
  md: 12px
  wallet: 16px
  card: 22px
  phone: 44px
  full: 9999px

spacing:
  xxs: 4px
  xs: 6px
  sm: 8px
  md: 12px
  row-inset: 14px
  gutter: 16px
  lg: 20px
  xl: 24px

components:
  card:
    backgroundColor: "{colors.card}"
    textColor: "{colors.text}"
    rounded: "{rounded.card}"
  wallet-card:
    backgroundColor: "{colors.wallet-1}"
    textColor: "{colors.card}"
    typography: "{typography.money-card}"
    rounded: "{rounded.wallet}"
  button-primary:
    backgroundColor: "{colors.button}"
    textColor: "{colors.on-button}"
    rounded: "{rounded.md}"
  button-outline:
    backgroundColor: transparent
    textColor: "{colors.text}"
    borderColor: "{colors.line}"
    rounded: "{rounded.md}"
  button-text:
    backgroundColor: transparent
    textColor: "{colors.text}"
  icon-button-circle:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.text}"
    rounded: "{rounded.full}"
    size: 34px
  pill:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.text}"
    typography: "{typography.pill}"
    rounded: "{rounded.full}"
  segmented-control:
    backgroundColor: "{colors.raised}"
    thumbColor: "{colors.card}"
    thumbColorDark: "{colors.line-dark}"
    typography: "{typography.segment}"
    rounded: "{rounded.full}"
  text-input:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.text}"
    labelColor: "{colors.muted}"
    errorColor: "{colors.bad}"
    rounded: "{rounded.md}"
  tab-bar:
    backgroundColor: "{colors.card}"
    textColor: "{colors.muted}"
    selectedTextColor: "{colors.text}"
    typography: "{typography.tab-label}"
    rounded: "{rounded.full}"
    height: 62px
  category-dot:
    backgroundColor: "{colors.food}"
    textColor: "{colors.ink}"
    rounded: "{rounded.full}"
    size: 34px
  snackbar:
    backgroundColor: "{colors.button}"
    textColor: "{colors.on-button}"
---

# SmartSpend Design System

> Format: the DESIGN.md format from Google Stitch (https://stitch.withgoogle.com/docs/design-md/overview/), laid out like the files in VoltAgent/awesome-design-md (MIT, https://github.com/VoltAgent/awesome-design-md). Every value here comes from the app's own code: `ssdemo_1/lib/app/app_theme.dart` (colours, buttons, inputs, motion) and `ssdemo_1/lib/widgets/common/ui.dart` (shared components). When the code and this file disagree, the code wins; update this file.

## Overview

SmartSpend should feel like a well-kept paper ledger in a warm room, not a trading terminal. The light surface is sand (`{colors.background}`) with near-white cards (`{colors.card}`); dark mode is warm charcoal (`{colors.background-dark}`, `{colors.card-dark}`), never pure black. Both modes use the same layout, the same category colours and the same components; only the surface and text tokens swap.

The page structure is iOS-like: a large bold title at the top of each tab (`{typography.large-title}`), rounded cards on the page background, and a floating glass tab bar at the bottom. Numbers are the content: the big figure on each card (net worth, budget left) is the loudest thing on the screen, and everything else steps back in `{colors.muted}`.

Colour carries meaning, not decoration. Each spending category owns one muted earth colour and uses it for its dot, its chart segment and its budget card, nowhere else, so a colour always means the same category. Green (`{colors.good}`) means under budget or money in, amber (`{colors.warn}`) means close to the limit, red (`{colors.bad}`) means over budget or an error; none of them is used for decoration.

**Key characteristics:**
- Warm sand and charcoal surfaces; cards lift by fill colour, with only soft shadows where cards stack.
- One large bold title per page; big tabular money figures; muted secondary text.
- Twelve category colours, identical in light and dark mode, with dark ink text on top.
- Black primary buttons in light mode, cream ones in dark mode (`{colors.button}` / `{colors.on-button}`).
- Rounded everything: 22 px squircle cards, 12 px controls, full pills and segmented controls.
- Every tappable element gives hover and press feedback; motion is short and turns off with reduced motion.

## Colors

### Surfaces and text (switch with light/dark mode)
| Token | Light | Dark | Use |
|---|---|---|---|
| `background` | #E8E2D6 | #171513 | Page behind cards |
| `card` | #FBF8F2 | #2B2825 | Cards, dialogs, segmented thumb (light) |
| `raised` | #E0D9CC | #3A3632 | Chips, segmented track, inputs, circle icon buttons |
| `line` | #E3DCCF | #423D38 | Dividers, outlines, segmented thumb (dark) |
| `text` | #1C1B1F | #F5F2EC | Primary text and icons |
| `muted` | #7D766C | #9C958B | Secondary text, labels, inactive tabs |
| `good` / `good-tint` | #4F7A45 / #DCE8D3 | #7FB36F / #2E3A28 | Under budget, money in, success |
| `warn` | #A86F12 | #E0A84E | Near the limit |
| `bad` | #B4483A | #E07A6A | Over budget, errors, destructive actions |
| `button` / `on-button` | #1C1B1F / #FBF8F2 | #F5F2EC / #1C1B1F | Primary button and snackbar |

Read surface colours from `context.colors` (the `AppColors` theme extension). Never hard-code a hex in a widget.

### Category colours (same in both modes)
Food terracotta #D28A5A, Transport slate blue #7E9DB5, Shopping dusty rose #C98D97, Bills pistachio #B5BE78, Subscriptions lavender #A897BC, Entertainment mustard #DDB45C, Housing walnut #A97C5E, Health teal #7DB2AC, Fees mocha #9C8C7C, Cash peach #E3B8A0, Other stone #BFB4A2, Income leaf green #7DAE6E.

Text and icons on a category colour are always `{colors.ink}` (#1C1B1F), in both modes. Get them from `AppPalette` through `colorForDetailedCategory`; a new category gets a new colour that no other category uses.

### Wallet cards
Accounts take #35506D, #B08F55, #6E5A7E, #7A5A48, #4F6B78 in order; the All Accounts card is #46604E, or a gradient of the account colours when there is more than one account. Text on wallet cards is cream (#FBF8F2), secondary text the same at 75%.

### Known gap
In light mode, `muted` on `background` is about 3.5:1 and the field placeholder about 3.2:1, below WCAG AA's 4.5:1 for small text. A darker muted such as #655E55 would pass; this is not changed yet.

## Typography

### Font family
No custom font is bundled. The theme uses iOS typography on every platform (`ThemeData(platform: TargetPlatform.iOS)`), so text renders in the system sans: San Francisco on Apple devices, the platform default elsewhere.

### Hierarchy
| Role | Token | Size / weight / tracking | Where |
|---|---|---|---|
| Page title | `large-title` | 34 / 700 / -0.9 | Top of each tab, sign-in heading (`largeTitleStyle`) |
| Hero money | `money-hero` | 34 / 700 / -0.8 | Budget "left to spend" |
| Card money | `money-card` | 32 / 700 / -0.6 | Net worth on the wallet card |
| Section title | `section-title` | 20 / 700 / -0.4 | `SectionHeader` ("Last 7 days") |
| Row title | `body-strong` | 15 / 500 | Transaction name |
| Body | `body` | 15 / 400 | Paragraphs, subtitles |
| Small body | `body-sm` | 13 / 400 | Card details, notices |
| Caption | `caption` | 12 / 400, muted | Dates, account endings, helper text |
| Pill | `pill` | 12.5 / 700 | `StatusPill` ("$54 over pace") |
| Segment | `segment` | 13 / 600 selected, 500 not | `SegmentedTabs` |
| Tab label | `tab-label` | 10.5 / 700 selected, 500 not | Floating tab bar |

### Principles
- Money: `dollars()` / `formatMoney()` from `utils/formatters.dart`; spending shows as "-$12.34", money in as "+$12.34" in `good`, using the true minus sign (U+2212).
- Short labels (titles, buttons, chips, tabs) carry no end punctuation: "Forgot password", "Create Account".
- Sentences in notices and errors keep their full stop.

## Layout

### Spacing
Page gutter 16 px; card inner padding 14 px; rows 9 px top and bottom; gaps of 4, 6, 8, 12, 16, 20 and 24 px. Pick from this set, not ad-hoc values.

### Phone-first frame
The app is laid out for a 393 x 852 pt phone. On a wider window (Chrome on a laptop) it is shown at that size, centred, in a phone frame with 44 px corners and a soft shadow, on a `desk` background (#D8D1C6 light, #0B0A09 dark). It never stretches cards across a desktop screen.

### Page structure
Large title, optional scope line ("Oct 2026"), then cards. Scrolling content leaves room at the bottom for the floating tab bar (`tabBarClearance`). The sign-in page sits a fixed gap from the top rather than centred, so rows that appear under the form don't move it.

### Touch targets
Small controls get a 44 x 44 pt hit area without changing their look (`TapTarget`).

## Elevation & Depth
Most depth comes from fill colour: `card` on `background`, `raised` inside a card. Shadows appear only where things float or stack:
- Floating tab bar: `card-shadow`, blur 24, y 8; frosted glass (blur 18, card colour at 70% light / 62% dark) with a faint light rim.
- Stacked wallet cards: `card-shadow`, blur 16. Stacked budget cards: `card-shadow`, blur 12.
- Segmented thumb in light mode: black at 12%, blur 8, y 3. Dark mode uses `line` as the thumb with no shadow.
- Phone frame: black at 33%, blur 40, y 16.

## Shapes
| Token | Radius | Use |
|---|---|---|
| `card` | 22 px, continuous (squircle) | `Section`, cards (`cardShape`, `cardDecoration`) |
| `wallet` | 16 px | Wallet cards |
| `md` | 12 px | Buttons, inputs, pull-down menus (`menuRadius`) |
| `sm` | 10 px | Selector fields, search box |
| `full` | pill | Chips, pills, segmented control, tab bar, icon buttons, category dots |

## Components

### Cards
`Section` is the default card: `card` fill, 22 px squircle, 14 px padding, 16 px side margin. A tappable card is a `Material` with an `InkWell`, clipped to its shape, so the highlight shows on the card and never under its fill.

### Buttons
- Primary: `FilledButton`, `button` fill, `on-button` label, 12 px radius.
- Secondary: `OutlinedButton` with a `line` outline; destructive ones use `bad` for the label.
- Text: `TextButton` in `text` (or `muted` for low-priority links such as "Forgot password").
- Labels name the action ("Create Account", "Save"), never "Yes/No" or "OK" where an action name fits.
- The theme draws button fills itself (`pressableFill` in `app_theme.dart`): a fill rests at 99%, grows to full size on hover and shrinks 3% when pressed; text-button labels grow 4%.

### Inputs
Filled with `raised`, no outline, 12 px radius, label inside the box that shrinks to the top when typing (`UnderlineInputBorder` with no line, set in the theme). Errors show under their own field in `bad`; the label turns `bad` too. Helper text (e.g. "At least 6 characters") is `muted` and turns into the error when the rule fails.

### Segmented control
`SegmentedTabs`: a `raised` capsule track with one capsule thumb that slides to the chosen segment (320 ms, a little spring between segments, none at the ends). Optional small ‹ › arrows step the selected segment's period.

### Navigation
Floating glass tab bar, 62 px tall, 16 px from the sides and 8 px from the bottom: Wallet, Activity, Ask (round `button` coloured centre button), Budget, Subs. The selected tab has a soft capsule behind it that slides between tabs (360 ms).

### Lists and rows
Transactions sit in a card as rows: 34 px category dot, name in `body-strong`, a line of caption details (date, category tag, account ending), amount on the right. Rows pad themselves 14 px so their tap highlight fills the card edge to edge; dividers are 0.5 px `line`, inset 14 px. Settings rows follow the same pattern with an icon, title, trailing value and chevron.

### Pills, chips and tags
`StatusPill` (12.5 / 700) for states such as "$54 over pace", tinted with the state colour. Filter chips and the AI ask chip are `raised` pills; selected filters fill with the category colour or `button`. Category tags show a small coloured dot and the name.

### Feedback and overlays
- Result feedback: a snackbar (`button` fill, `on-button` text), e.g. "Reset link sent to ...".
- Errors tied to the form: inline under the field or above the submit button, with an icon.
- Pickers open as pull-down menus lined up under their control (`showOptionSheet`); longer flows use a bottom sheet.
- A reversible action happens at once; only irreversible ones ask first, with the action named on the button.

### Interaction feedback
Every tappable element answers hover and press:
- Material buttons: through the theme (above).
- Custom controls (tab items, wallet cards, segments and arrows, month cells, chips, pills, icon buttons, category links): wrap in `Pressable` (`ui.dart`): grows 4% on hover, shrinks to 95% while pressed, click cursor. Large surfaces use 1.01 / 0.98, small arrows 1.15 / 0.88.
- Full-width rows (transactions, settings) use a full-width highlight instead of scaling.

### Motion
| What | Duration |
|---|---|
| Press and hover scale | 150 ms |
| Text style change, small fades | 160–200 ms |
| Expand and collapse | 200–220 ms |
| Swapping content (old fades out, then new fades in, so they never overlap) | 250 ms |
| Page fade between sign-in and the app | 300 ms |
| Segmented thumb / tab bar thumb | 320 / 360 ms |

Curves are `easeOutCubic` in, `easeInCubic` out, with `easeOutBack` only for thumbs moving between middle segments. When the system asks for reduced motion, durations become zero (`motionDuration(context, ms)`).

### Loading states
Never a lone spinner. Show the shape of what is coming:
- **Skeletons** (`SkeletonBox` inside `SkeletonShimmer`): blocks in `raised`, radius 6 by default, with a soft diagonal band of light (white at 45% in light mode, 7% in dark) sweeping left to right every 1.5 s. Use them for lists and cards whose layout is known, such as first-launch rows and the budget AI analysis.
- **Delay before a skeleton** (`DelayedSkeleton`): wait 300 ms before showing it, then fade it in over 150 ms, so a quick load goes straight to the result with nothing flashing by.
- **Content arriving** (`FadeSlideIn`): fade in while rising 8 px over 250 ms; blocks that arrive together are staggered 60 ms apart (`FadeSlideIn.staggered`).
- **AI reply pending** (`TypingDots`): three 7 px dots in `muted` that rise 4 px and brighten one after another, a 1.2 s cycle.

With reduced motion the shimmer holds still, the dots rest at 40% opacity, and content appears in place.

## Do's and Don'ts

### Do
- Read colours from `context.colors` and `AppPalette`; add a token here and in `app_theme.dart` before using a new colour.
- Keep each category's colour unique and use it only for that category.
- Put the number first: one big figure per card, details in `muted`.
- Use the shared components in `ui.dart` (`Section`, `SegmentedTabs`, `StatusPill`, `CircleIconButton`, `Pressable`, `LargeTitle`) before writing a new one.
- Give every tappable element hover and press feedback, and every element that appears or disappears an animation.
- Prefer Material rounded icons (`Icons.*_rounded`) in new UI; older screens still mix in outlined ones.
- Check both light and dark mode, and the phone frame on a wide window.

### Don't
- Don't use emoji anywhere in the UI.
- Don't use red, amber or green for decoration; they mean over budget, near the limit and good.
- Don't use pure black or pure white surfaces; use the tokens.
- Don't draw a tappable highlight on a widget that sits under a decorated `Container`; put it on a `Material`.
- Don't cross-fade two texts in the same spot; fade the old one out before the new one comes in.
- Don't put outline borders on text fields, or labels that float outside the box.
- Don't add punctuation to short labels and buttons.

## Responsive Behavior
- One layout, phone-first. Up to 433 pt wide the app fills the window; wider, it is shown in the centred 393 x 852 phone frame.
- The sign-in form is at most 420 pt wide.
- Touch targets are at least 44 x 44 pt.
- The keyboard pushes the sign-in form up (`resizeToAvoidBottomInset`).

## Agent Prompt Guide

### Quick reference
- Light: background #E8E2D6, card #FBF8F2, raised #E0D9CC, text #1C1B1F, muted #7D766C, button #1C1B1F on #FBF8F2.
- Dark: background #171513, card #2B2825, raised #3A3632, text #F5F2EC, muted #9C958B, button #F5F2EC on #1C1B1F.
- States: good #4F7A45 / #7FB36F, warn #A86F12 / #E0A84E, bad #B4483A / #E07A6A.
- Radii: cards 22 squircle, controls 12, pills full. Gutter 16, card padding 14.
- Type: titles 34/700/-0.9, sections 20/700/-0.4, body 15, captions 12 muted.

### Example prompts
- "Add a Savings Goals card to the Wallet tab in SmartSpend's style: a `Section` with a `SectionHeader`, the goal amount in money-card type, progress in the category colour, details in muted caption text, and `Pressable` feedback if the card opens a page."
- "Build a settings row group following DESIGN.md: `Section` with zero padding, rows with a rounded icon, title, muted trailing value and chevron, 0.5 px dividers inset 14 px, full-width highlight on tap."
- "Make this dialog match DESIGN.md: `card` fill, 22 px corners, title in section-title type, actions as a text button and a filled button named after the action, no outline on the input, label inside the field."
