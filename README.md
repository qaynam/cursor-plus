<div align="center">

# Cursor+

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/cursor-hero-dark.svg">
  <img alt="Cursor+ tracing a human path and clicking a zone" src="docs/cursor-hero-light.svg" width="760">
</picture>

**A macOS menu bar app that keeps your Mac awake by moving the cursor the way a hand would, not the way a metronome would.**

![Platform](https://img.shields.io/badge/macOS-14%2B-black?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9-f05138?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-58a6ff)
![Dependencies](https://img.shields.io/badge/dependencies-none-3fb950)

</div>

Cursor+ keeps your Mac looking active by nudging your real mouse cursor around. Not a twitchy jiggle, actual motion: it picks a spot, picks a speed, and follows a curved path there, with a faint hand tremor and the occasional slow scroll. The moment you touch your own mouse or keyboard it gets out of the way, and it only comes back once you have gone quiet. You can kill it any time by tapping Esc three times quickly.

Out of the box it only moves and scrolls. If you want, you can draw **click areas**, rectangles you place on screen, and it will every so often curve into one and click a spot inside it. It only ever clicks inside the rectangles you draw, never random empty space, so put them on things that are safe to click.

You can also draw **avoid areas**, rectangles the cursor is not allowed to enter. It never picks a destination inside one, never aims at one, and when a move would have cut through one it curves around instead. Put them over a Close button, a Send button, a video call window, anything you would rather it kept clear of.

> [!NOTE]
> This is a personal tool for your own machine. It synthesizes input and listens for the Esc stop gesture, so do not run it on a work-managed (MDM) Mac.

## What it actually does, in a loop

Moving the cursor is what resets the system idle timer, which is the whole reason this works. Cursor+ runs a small state machine that wanders, sometimes scrolls, sometimes visits a click zone, then rests, over and over, and hands control straight back to you the instant you touch anything.

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Moving: Start
  Moving --> Scrolling: now and then
  Moving --> ApproachingClick: if you set a click zone
  Moving --> Resting: most of the time
  Scrolling --> Resting
  ApproachingClick --> ClickDwell
  ClickDwell --> Clicking
  Clicking --> Resting
  Resting --> Moving: after a short pause
  Moving --> Paused: you touch the mouse, or Secure Input
  Paused --> Moving: once you go quiet
  Moving --> Idle: Esc Esc Esc
  note left of Paused : pause and the triple-Esc stop<br/>work from any state, not just Moving
  note right of Moving : every destination and every path<br/>routes around your avoid areas
```

Each move samples a speed class, from very slow to very fast, then a real velocity inside it, and follows a curved path with a band-limited 8 to 12 Hz tremor layered on, the same frequency as a real hand. Four presets shift where that speed lives.

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/cursor-speed-dark.svg">
  <img alt="Four motion presets and their speed-class weights" src="docs/cursor-speed-light.svg" width="760">
</picture>
</div>

## Going around what you told it to leave alone

An avoid area is not a fence the cursor bumps into. Clamping motion at the edge of a box would make it slide along an invisible wall, which looks worse than the motion it is there to protect. So the avoiding happens before a path exists, not while one is playing.

Each area is grown by a comfort margin that is re-rolled on every single move, so the distance it keeps is never a fixed number you could measure. Destinations are picked outside that margin, so the cursor never even aims at one. If the straight line to a destination would still cut through, a shortest way round is worked out through the corners of the grown boxes, and those corners become via-points rather than stops: the path physics hands over to the next one while still well clear of it, carrying its velocity through the turn. What comes out is one continuous curve, not a straight line with a corner bolted onto it. Momentum through a turn carries wide, and wide is the side away from the box.

Two checks sit behind all that, one on the finished path and one on every point before it is posted. The margin is wide enough to absorb the natural wander of the motion, so in practice neither of them has anything to correct, which is the whole point: nothing ever gets clamped, so nothing ever looks clamped. Detoured moves come out with the same speed profile and the same heading changes as ordinary ones.

If you park the cursor inside an avoid area yourself and walk away, it does not snap out. It just leaves the way a hand would, and then stays out.

## How it knows its own moves, and how it stays safe

A jiggler that pauses when you touch the mouse has a problem: it has to tell its own motion apart from yours, or it will pause on itself and never move. Cursor+ does this out of band. It keeps a small private log of every move it just posted, and the kill switch checks against that log instead of stamping a marker on the events. It never tags its own output. The one thing no app can hide is the process ID macOS attaches to every posted event, but nothing Cursor+ itself adds gives the motion away.

- It only clicks inside the areas you define, never random or empty space. With no areas set it just moves and scrolls.
- It stays out of any avoid areas you draw, and will not click inside a click area that one covers.
- It auto pauses the instant you use the mouse or keyboard, and comes back once you go idle.
- It freezes while a password field or the lock screen is focused, so the Esc kill gesture is never in doubt.
- The triple Esc kill switch runs on its own self-healing global tap with a backup monitor, completely separate from the motion. Cursor+ never synthesizes key events, so nothing it does can interfere with the stop.

## Build

You need the Swift toolchain on macOS 14 or newer. I built and tested it on macOS 26 on Apple Silicon.

```bash
./scripts/build_app.sh
open "Cursor+.app"
```

A cursor icon shows up in your menu bar. Running `swift build` on its own only gives you the bare binary, the menu bar behavior needs the assembled `.app`. To make the Accessibility grant survive rebuilds, sign with a stable identity. The instructions are at the top of [`scripts/build_app.sh`](scripts/build_app.sh).

## First run and permissions

macOS will ask for permission and deep link you to the right pane:

**System Settings, Privacy and Security, Accessibility**, then turn on **Cursor+**.

That one grant covers moving the cursor, scrolling, and watching for your input. If the menu says it needs permission or that the kill switch is unavailable, finish the grant and relaunch.

## Using it

Click the menu bar icon:

- **Start and Stop** turn it on and off. Stop is always a reliable kill.
- **Motion speed**: Calm, Balanced, Lively, Wild.
- **Wander interval**: 10 to 20s, 20 to 40s, 30 to 60s, or 60 to 120s, how long it roams before resting.
- **Occasional scrolling** lets it emit a rare slow scroll.
- **Human idle pauses** drop short, natural pauses between bursts.
- **Occasional long pauses** is off by default. Turn it on and it will rarely take a 30 to 90 second break. Heads up: during a long pause the Mac can read as away to presence based status, even though the display stays awake.
- **Click defined areas** toggles whether it clicks inside your zones at all.
- **Add or Edit click area** opens the overlay editor: drag to add a rectangle, click to select, drag the handles to resize, Delete to remove, Esc or Return when done.
- **Clear click areas** removes all of them.
- **Avoid defined areas** toggles whether it honours your no-go areas at all. Turning it off leaves the rectangles in place.
- **Add or Edit avoid area** opens the same overlay editor, in red. Tab switches between click areas and avoid areas without leaving it, and whichever kind you are not editing stays visible behind, dimmed, so you can see where the two overlap.
- **Clear avoid areas** removes all of them.
- **Prevent display sleep** also holds the screen awake.

To stop at any time, tap Esc three times quickly, or click Stop.

## How it is put together

| File | What it does |
|---|---|
| `Sources/CursorPlus/InputEngine.swift` | posts real cursor moves and scrolls with CGEvent, with hardware consistent deltas |
| `Sources/CursorPlus/MovementEngine.swift` | speed classes, velocity sampling, the curved path geometry, tremor, and the scroll player |
| `Sources/CursorPlus/StateMachine.swift` | the rhythm: wander, maybe scroll, maybe visit a click zone, rest, repeat |
| `Sources/CursorPlus/AvoidZones.swift` | picking targets, routing paths and the two checks that keep the cursor out of your no-go areas |
| `Sources/CursorPlus/AutoPause.swift`, `SyntheticInputLog.swift` | hands control back the moment you touch input, and tells its own motion from yours |
| `Sources/CursorPlus/KillSwitch.swift` | the self-healing global tap behind the triple Esc stop |
| `Sources/CursorPlus/ZoneRect.swift`, `ZoneEditor.swift` | the click and avoid rectangles, and the full screen editor for drawing both |

## License

[MIT](LICENSE). Copyright 2026 Ahmed Ufuk Serce. Personal tool. Whatever you do with it is on you, including running it somewhere it is actually allowed.
