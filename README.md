# nudge-scheduler

A Swift package that decides whom to nudge to stay in touch, and when to deliver each nudge. You give it contacts (opaque IDs), relationship rings, last-contact dates, birthdays, quiet hours, a daily cap and snoozes. It returns a ranked list and delivery times. It never reads the clock, `UserDefaults` or `Calendar.current`: every call takes `now` and a `Calendar`.

A CLI, `nudge-sim`, replays a seeded synthetic year and writes a static HTML report.

![Report: legacy comparison, cap sweep and overdue strip](docs/report.png)

## Quickstart

Requires Swift 6 (Xcode 16 or later). No dependencies.

```sh
swift build
swift test
swift run -c release nudge-sim --seed 42 --out site   # about 55 s on an M-series Mac
open site/index.html
```

## Usage

```swift
import NudgeScheduler

let settings = try NudgeSettings(dailyCap: 3, quietHours: try QuietHours(startHour: 22, endHour: 8))
let engine = NudgeEngine(settings: settings)

var snoozes = SnoozeBook()
snoozes.snooze(ContactID("a1"), now: now, calendar: calendar)   // 7 days by default

let nudges = engine.nudges(for: contacts, now: now, calendar: calendar, snoozes: snoozes)
let times = DeliveryPlanner.dates(count: nudges.count, now: now, quietHours: settings.quietHours, calendar: calendar)
```

## Rules

| Rule | Behavior |
|---|---|
| Rings | inner 10 days, close 20, outer 40, distant never drifts. `Contact.cadenceDays` overrides. |
| Drift priority | 50 + min(days overdue, 40), so it peaks at 90 |
| Birthday priority | 100 on the day, 95 the day before, 80 a week before |
| Leap-day birthdays | Feb 29 is observed on Feb 28 in common years |
| One slot per contact | If a contact has a birthday and a drift nudge on one day, only the higher priority one is kept |
| Order | priority, then kind (birthday, drift, check-in), then ring, then contact ID. Input order never matters. |
| Daily cap | `NudgeSettings.dailyCap`, 1 to 10, the only cap. Out-of-range values throw. |
| Quiet hours | Any start and end hour. 22:00 to 08:00 wraps midnight, 01:00 to 07:00 does not, equal start and end means none. Windows that leave less than an hour a day throw. |
| Delivery | At least 15 minutes after `now`, spread evenly over the rest of the current allowed window, or over the next window if fewer than 15 minutes per nudge remain |
| Snoozes | Keyed by `ContactID` with an expiry. Expired entries are ignored and `prune(now:)` removes them. |

## What the tests check

`swift test` runs 26 tests in 4 suites (swift-testing). Each rule in the table has a regression test named after the bug it prevents. These include quiet hours 01:00 to 07:00 with 3 nudges at 23:00, cap 5 with 5 overdue contacts, and a Feb 29 birthday on 2027-02-28.

Property tests use a seeded SplitMix64 generator, so any failure reproduces exactly:

- Every pair of quiet-hour start and end hours (576 pairs), counts 1 to 10, and 12 instants per case sampled from 3-day windows around both 2026 DST changes in America/Los_Angeles: no delivery inside quiet hours, none before `now`, strictly increasing.
- Every 15-minute instant in those windows for three quiet-hour settings, with 10 nudges.
- 200 generated contact sets per cap from 1 to 10: never more than the cap, never a repeated contact, priorities non-increasing.
- 100 seeded shuffles of one input give identical output.
- A full simulated year at caps 1, 3 and 10 has 0 quiet-hour violations, and the same seed produces byte-identical JSON.

## The simulation

Each run has 40 invented contacts: 5 inner, 10 close, 15 outer and 10 distant. It covers every day of 2026 in America/Los_Angeles. Each day the simulated user opens the app at a random minute. The engine picks nudges and the planner times them. The user replies with probability 0.6, and snoozes 25% of the nudges they do not reply to. Contact also happens without a nudge at a fixed daily rate per ring. These rates are assumptions chosen for the simulation, not measurements. "Wait" is the number of days from the first overdue day to the first nudge.

The report compares this engine with a re-implementation of the behavior it replaces (`LegacyBaseline.swift`). That baseline has a hard cap of 3, a drift priority that stops at 80, no per-contact dedupe, snoozes that never expire, and a planner that assumes quiet hours wrap midnight.

Results for seed 42 (from `site/results.json`):

| | This package | Legacy |
|---|---|---|
| Deliveries inside quiet hours, quiet 01:00 to 07:00, cap 3 | 0 of 638 | 82 of 244 |
| Max wait at cap 3, inner / close / outer (days) | 2 / 3 / 4 | 48 / 80 / 54 |
| Overdue episodes never nudged by year end | 0 | 9 |
| Slots spent on a second nudge for one contact | 0 | 1 |

Legacy snoozes never expire, so every snoozed contact drops out for the rest of the year. That is why the legacy run delivers 0.65 nudges a day against 1.67 for this package. This table does not separate how much each legacy bug adds to the wait.

Cap sweep, pooled over seeds 42 to 61 (20 simulated years per cap). Each cell shows the p90 wait in days, then the max:

| Cap | Inner | Close | Outer | Outer episodes never nudged | Nudges per day |
|---|---|---|---|---|---|
| 1 | 17, 30 | 18, 39 | 20, 37 | 57 of 1722 | 1.00 |
| 2 | 3, 9 | 3, 10 | 4, 12 | 9 of 1922 | 1.61 |
| 3 | 1, 6 | 1, 5 | 1, 5 | 2 of 1936 | 1.70 |
| 4 | 0, 4 | 0, 6 | 1, 5 | 0 of 2005 | 1.71 |

At cap 1 the outer ring waits longest: 57 outer episodes end the year without a nudge, against 35 inner and 44 close. From cap 3 up, the cap rarely binds (about 1.7 nudges a day on average), so raising it further changes little for this synthetic group.

`site/card.json` holds the cap sweep in the portfolio card format.

## Layout

```
Sources/NudgeScheduler/   engine, quiet hours, planner, snoozes, simulation, legacy baseline
Sources/nudge-sim/        CLI, HTML report, card.json
Tests/NudgeSchedulerTests/
site/                     generated report, results.json, card.json
```

## Limitations

- The simulation models one user and one synthetic group of contacts. The reply, snooze and contact rates are assumptions. Treat the cap sweep as a way to compare settings, not as a forecast.
- The legacy baseline is a re-implementation written from a description of the old behavior, not the original code.
- Delivery times are minute precision. The planner does not account for notifications the host app has already scheduled.
- The report needs a browser for its hover text, cap selector and ring filter. Without JavaScript it shows the default cap.
- The sweep takes about 55 seconds because it runs 200 simulated years, and most of that time goes to `Calendar` arithmetic.

## License

MIT, see [LICENSE](LICENSE).
