# 28 — The task-port message

> `Unable to obtain a task name port right for pid 461: (os/kern) failure (0x5)`

Reported as a runtime message from Elephruit, and suspected of being connected to the Tasks module.
It is neither ours nor connected to Tasks. This is the evidence, so that nobody has to gather it
twice.

## What emits it

The format string

```
Unable to obtain a task name port right for pid %i: %{public}s (0x%x)
```

lives in the dyld shared cache, inside Apple's private **BaseBoard** framework. Every occurrence is
logged under subsystem `com.apple.BaseBoard`, category `Common`.

It is an `os_log` message rather than a write to `stderr`, which is why Xcode's console shows it and
a redirected `stderr` captures nothing. That difference is what made it look like it might be coming
from our own logging.

## What pid 461 is

```
$ ps -p 461 -o comm=
/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
```

Not the app, not a helper, not a preview process, not a system service the app talks to. It is the
window server, and every windowed process on the machine has a connection to it.

## It is symmetric

Every occurrence is a **pair**, logged in the same millisecond by both ends of one connection:

```
07:03:12.300  WindowServer[461]   … for pid 91163
07:03:12.300  Elephruit[91163]    … for pid 461
```

Neither side can obtain a task name port for the other. That is a property of the handshake, not of
either participant.

## Every GUI application does it

Distinct emitters over twelve hours on one Mac:

| Count | Process |
|---|---|
| 39 | WindowServer |
| 38 | Podcasts |
| 9 | com.apple.SafariPlatformSupport.Helper |
| 8 | **Elephruit** |
| 3 | com.apple.appkit.xpc.openAndSavePanelService |
| 3 | QuickLookUIService |
| 2 | WindowManager |
| 1 each | Xcode, Mail, **Calendar**, **Contacts**, **Reminders**, Craft, Claude, ChatGPT, ThemeWidgetControlViewService, RemoteCatalystPosterExtension, DocumentPopoverViewService, AKAppSSOExtension_macOS, AKAuthorizationRemoteViewService |

Apple's own Reminders, Calendar and Contacts log the identical message about the identical pid.
Elephruit is not over-represented; Podcasts produces nearly five times as many.

## It is not the Tasks module

Elephruit logs it at most **once per process**, during the window-server activation handshake, before
any module has been chosen — the app opens on Today, in the primary navigation, with no module
entered at all. Eight launches over twelve hours produced eight messages:

```
19:43:10.753  Elephruit[98619]      06:04:08.469  Elephruit[80393]
20:57:26.514  Elephruit[6794]       06:11:12.781  Elephruit[83421]
21:45:00.816  Elephruit[16951]      07:03:12.300  Elephruit[91163]
05:58:21.940  Elephruit[78307]      07:03:56.435  Elephruit[91363]
```

A launched instance that never came to the front — pid 91587, alive from 07:07:17 to 07:07:42 —
logged nothing at all, which places the trigger at the frontmost/activation handshake rather than at
process start. The precise condition inside the window server that makes it fire on some connections
and not others is in a private framework and is not observable from here; that is stated rather than
guessed at.

## What the app does not do

A scan of the whole source tree finds no `task_for_pid`, `task_name_for_pid`, `processor_set_tasks`,
`proc_pidinfo`, `proc_listpids`, `AXUIElementCreateApplication`, `AXIsProcessTrusted`,
`CGWindowListCopyWindowInfo`, global `NSEvent` monitor, `NSAppleScript`, or `NSAppleEventDescriptor`.
`ProcessAccessTests` is that scan, run on every build, so the answer stays checkable rather than
remembered.

The app holds five entitlements — sandbox, user-selected files, app-scoped bookmarks, calendars,
address book, reminders — and none of them grants task-port access. Nothing was weakened, and nothing
needed to be: the message is not a symptom of a missing capability.

## What was changed

One thing, and it was a real defect that this investigation surfaced rather than the cause of the
message.

`QuickJotController` gave focus back by calling `NSRunningApplication.activate()` on whatever was
frontmost when the capture panel opened. That reaches *into another process* to bring it forward. It
is deprecated as of macOS 14, it is the sort of operation the sandbox is entitled to refuse, and it
fails outright once the target has quit — which is not a rare case for a floating panel that exists
precisely so somebody can capture a thought *while doing something else*. The `NSRunningApplication`
was also held after the panel closed, so a terminated process stayed referenced indefinitely.

It now calls `NSApplication.yieldActivation(to:)`, added in macOS 14 for exactly this: the app gives
up its own activation and names who should receive it, and the window server does the rest. Nothing
is asked of the other process, so there is nothing for a dead one to refuse. `isTerminated` is
checked first, and the reference is released the moment the panel closes.

That change removes the app's only cross-process activation call. It does not remove the message,
and it was never going to — see everything above.

## What to tell somebody who reports it again

It is Apple's, it affects every windowed application including Apple's own, it fires at most once per
launch, and it has no effect on anything. Tasks — including the Reminders link, which is the app's
only integration that writes — works exactly as before; the full suite passes and the module was
exercised by hand after the change.
