# nudge-scheduler

A Swift package that decides which friends to remind you to contact, and when to send each reminder so it never lands in your quiet hours. It never reads the clock or system calendar itself, so every result can be tested and replayed exactly.

![Report: legacy comparison, cap sweep and overdue strip](docs/report.png)

## Highlights

- **Zero quiet-hour violations in 638 deliveries** over a simulated year, against 82 of 244 for the old behavior it replaces.
- **Longest wait for a reminder cut to 2 / 3 / 4 days** for inner, close and outer friends, down from 48 / 80 / 54.
- **Daylight-saving safe**: tests cover all 576 quiet-hour start/end pairs around both 2026 clock changes.
- **Reproducible**: the same seed gives byte-identical simulation output.

## Run it

```sh
swift build
swift test
swift run -c release nudge-sim --seed 42 --out site   # about 55 s
open site/index.html
```

Needs Swift 6 (Xcode 16 or later). No dependencies.

## How it works

- Each contact sits in a ring (inner, close, outer, distant) that sets how often you should talk: every 10, 20 or 40 days, or never for distant.
- Overdue contacts and upcoming birthdays get a priority score; the engine keeps at most one reminder per contact and returns the top few, up to a daily cap.
- The planner spreads those reminders across the hours outside your quiet window, including windows that wrap past midnight.
- Every call takes the current time and calendar as arguments, which makes edge cases like leap-day birthdays easy to test.
- `nudge-sim` plays out a year for 40 invented contacts and compares the engine with the old rules.

## Limitations

- The simulation uses one synthetic friend group with assumed reply and snooze rates, so it compares settings rather than forecasting.
- The old behavior was re-implemented from a description, not the original code.
