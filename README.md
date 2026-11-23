# nudge-scheduler

A Swift package that decides which friends to remind you to contact, and when to send each reminder so it never lands in your quiet hours. It never reads the clock or system calendar itself, so every result can be tested and replayed exactly.

**[Read the report →](https://allenwang0.github.io/nudge-scheduler/)**

![Delivery times by hour for two quiet-hour windows and the legacy rules](docs/report.png)

## Highlights

<!-- results:start -->
- **1,246 of 1,246 simulated reminders landed outside quiet hours**: 608 with quiet hours 22:00–08:00 and 638 with 01:00–07:00 (seed 42, cap 3).
- **Clock changes are tested**: all 576 quiet-hour start/end pairs around both 2026 daylight-saving changes; the same seed gives byte-identical output.
- **Short waits at the default cap of 3**: 90% of overdue friends get a reminder within 1 day, the longest wait is 6 days (20 seeds pooled).
- **Against the old rules** (re-implemented from a description): with quiet hours 01:00–07:00 they put 82 of 244 reminders inside the window; with 22:00–08:00, 2 of 238. The package sends 2.6× as many reminders per day.
<!-- results:end -->

## Run it

```sh
swift build
swift test
swift run -c release nudge-sim --seed 42 --out site   # about 45 s; writes site/results.json
python3 scripts/build_report.py --readme README.md    # rebuilds site/index.html and this list
open site/index.html
```

Needs Swift 6 (Xcode 16 or later) and Python 3.10+. No dependencies.

## How it works

- Each contact sits in a ring (inner, close, outer, distant) that sets how often you should talk.
- Overdue contacts and birthdays get a priority score; the engine keeps one reminder per contact, up to a daily cap.
- The planner spaces reminders across the hours outside quiet hours, including windows that wrap past midnight.
- `nudge-sim` plays out a year of invented contacts and compares the engine with the old rules.

## Limitations

- One synthetic friend group with assumed reply and snooze rates: it compares settings, it does not forecast.
- The old behavior was re-implemented from a description, not the original code.
