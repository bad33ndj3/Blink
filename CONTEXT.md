# Blink

A macOS menu bar tool that interrupts screen time with fullscreen look-away breaks, while respecting deep focus sessions and meetings.

## Language

**Interval**:
The target time between the end of one Break and the trigger of the next. Default 20 min, user-configurable. Not treated as a hard rule — evidence for the exact "20-20-20" numbers is weak, so this is a tunable default rather than a fixed law.

**Typing Activity**:
Keyboard input only (not mouse/scroll movement), used as the signal that the user is in active work and a Break should be debounced.
_Avoid_: Activity, input (too broad — must stay keyboard-specific)

**Deep Session Cap**:
A hard ceiling on how long continued Typing Activity can postpone a Break. Once reached, the Break fires regardless of ongoing typing.
_Avoid_: Max delay, timeout

**Break**:
The fullscreen overlay pause itself. ~20-30s, shows a countdown and a short look-away instruction. Fades in over ~2-3s rather than appearing instantly. Captures keyboard/mouse input for its duration — it cannot be typed or clicked through.
_Avoid_: Reminder, prompt (reserve for smaller/non-fullscreen interruptions)

**Snooze**:
A one-time postponement of a triggered Break, available once per Break before it becomes blocking.

**Meeting Mode**:
A state — entered either manually via a button (toggle) or automatically when the camera is in use — that suppresses the fullscreen Break so it doesn't interrupt a call. Screen-sharing-without-camera is not auto-detected (no reliable macOS API); the manual button covers that case. Fullscreen-immune for its whole duration, even past the Deep Session Cap. Ends automatically when the camera stops, or manually via the button for the fallback case.
_Avoid_: Do Not Disturb, quiet mode (reserve for a possible future distinct feature)

**Nudge**:
The small, non-blocking notification shown instead of a Break while Meeting Mode is active. The first trigger during a meeting is suppressed silently; every trigger after that shows a Nudge, for as long as the meeting continues.
_Avoid_: Reminder, alert (reserve "Break" for the fullscreen form)
