# The usage rail

The usage rail is a floating panel pinned to the right edge of the primary screen. Each
provider gets a ring: the provider mark, an arc for the share of its leading allowance that
is already spent, and the percentage below. Pointing at a ring opens a bubble listing every
account and limit behind that number.

It is an additional surface, not a replacement. The menu bar extra keeps its tray icon,
tooltip, and provider filter. The rail is shown by default and can be turned off under
Settings → Usage rail (`limits.rail.enabled`). It is suppressed during UI tests, where an
always-on-top window would cover the fixtures the suite drives.

## Geometry

Every length in `UsageRailMetrics` is a measurement taken from the reference mockup in that
image's own pixels, scaled once through `UsageRailMetrics.scale`. Changing that one constant
resizes the whole surface and keeps the proportions intact; the numbers stay auditable
against the source image.

Colours in `UsageRailPalette` are sampled from the same mockup and declared in Display P3.
The mockup is a P3 capture, so reading those samples as sRGB renders them visibly
desaturated on a wide-gamut screen.

The panel is borderless, non-activating, and sits at status-bar level across all spaces. It
is only as wide as the rail itself, because a transparent panel still consumes every click
inside its frame, and it widens leftward while a bubble is open with its right edge pinned so
the pointer stays inside the hovered ring. Hover and clicks come from an `NSTrackingArea`
with `.activeAlways`; SwiftUI's `onHover` only fires while the app is frontmost, and the rail
has to react while any other app is in front.

## What each ring reports

| Provider | Ring | Bubble |
| --- | --- | --- |
| Codex | The current account's weekly allowance | One line per signed-in account |
| Claude | The current session | Every window the bridge reported |

Codex publishes several overlapping allowances. Only the weekly one earns a line, and where
an account has more than one weekly, the rail shows the one furthest consumed, since that is
what binds first. Accounts are listed current-first, and account names only appear when there
is more than one to tell apart.

Rows carry `windowMinutes`, so a surface picks a window by duration rather than by matching a
localized title.

## Freshness

`LimitsFreshnessPolicy.defaultTTL` is fifteen minutes. The tray and the widget hold to it
strictly. The rail does not: a reading that has aged out is shown dimmed and dated
("Updated 1h 32m ago") rather than dropped, because a 5h or 7d allowance stays meaningful
well past the point where its snapshot stops counting as current. Accounts other than the
active one are only re-probed occasionally and would otherwise spend most of their life
looking empty.

## Where Claude's numbers come from

Claude Code exposes no usage API to the app. Limits installs a status line bridge into
`~/.claude/settings.json`; Claude Code runs it and pipes a JSON payload in, and the script
keeps the rate limit windows and nothing else. The emitted script carries a version marker
(`limits-statusline-bridge v4`), and `upgradeBridgeScriptIfNeeded()` rewrites it during the
normal probe — `installBridge()` returns early once the bridge is configured, so without that
an existing install would keep running an older script forever.

The payload's `rate_limits` object carries exactly two windows:

```
rate_limits: {
  five_hour: { used_percentage, resets_at },
  seven_day: { used_percentage, resets_at, overage: { spend_limit } }
}
```

Two consequences follow, and both are constraints of the source rather than gaps in the app.

**The per-model weekly allowance is not available.** Claude's own settings screen and its
`/status` panel show a separate weekly limit for the top model, but that window is absent
from the status line payload. `ClaudeStatuslineBridgeSnapshot` decodes a `seven_day_opus` key
and the script extracts it, so the row appears on its own if the key is ever added; today it
never arrives and the row is simply omitted.

Note for anyone re-deriving this: `seven_day_opus` *does* appear in the Claude Code bundle,
but as a rate-limit-type identifier in the quota auto-resume code, tens of thousands of lines
away from the status line schema. Proximity in the string table is the signal; co-occurrence
in the binary is not.

**The numbers only refresh during an interactive session.** The status line runs from the
Claude Code TUI. Measured behaviour:

| Trigger | Status line runs | `rate_limits` present |
| --- | --- | --- |
| `claude -p "…"`, headless turn | no | — |
| `claude` in a pty, no prompt sent | yes, about 3s in | null |
| Idle TUI held for 75s | once | null |
| `claude -p "/status"` | not applicable | `/status` is unavailable outside the TUI |

The window data arrives with API responses, so it is populated only after a turn. A pty can
run the status line for free but learns nothing, and refreshing through a real turn would
spend quota in order to measure quota. The rail therefore shows Claude's last known reading,
dimmed and dated, between sessions.

That first empty payload used to be published, which replaced a good snapshot with an empty
object on every session start and blanked the Claude numbers until the first reply came back.
The script now publishes only a reading that carries a window with a percentage in it — a bare
`{"five_hour":{}}` satisfies a key-existence check while carrying no number, so testing for the
key alone was not enough.

Freshness is judged where it is needed rather than where the data is produced. The probe keeps
a reading that belongs to the account in use however old it is, and each surface decides: the
tray and widget require a current one, the rail shows the aged one and dates it. Checking the
age in the probe instead would hand every surface nil and defeat the fallback. For the same
reason, first learning who is signed in is not treated as an account switch — doing so rejected
every snapshot written before launch, which on a cold start is all of them.

## Known limitation

The detail bubble is an overlay, so its height does not enter the panel's layout, and the panel
is sized from the rail column alone. A Codex user with roughly five or more accounts would get a
bubble taller than the panel and see it clipped. Fixing it needs both the bubble's height
reported to the window controller and its vertical position clamped, since the bubble centres on
its ring and would otherwise run past the top of the screen.

## Deliberately not done: reading Claude's usage API

`/status` builds its Usage panel from `GET https://claude.ai/api/oauth/usage`, whose response
carries `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, and more. One
authenticated request would deliver every window, including the top-model weekly, with no
quota spent and no session required.

Limits does not make that request. The app performs no authenticated network calls at all:
its only egress is the public OpenAI pricing documents, it sends no credential anywhere, and
that property is what its privacy posture rests on. Reading the usage API would mean sending
the user's Claude OAuth token over the network — to its own issuer, on the user's behalf,
read-only, the same request Claude Code itself makes, but a token leaving the machine
nonetheless.

That is a product decision rather than an implementation detail, and it was taken as: not
now. Should it be revisited, it belongs behind an explicit opt-in that is off by default,
with `PRIVACY.md` and the README updated to describe the new egress.
