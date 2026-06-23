# Terminal Architecture Notes

Goal: provide a browser terminal that behaves like an SSH/VPS console while
running locally inside `rctld` as root.

## Current design

The terminal is a real PTY, not a line-based `/v1/exec` wrapper.

```text
Browser xterm.js
    |
    | WebSocket /ws/term
    v
rctld Term bridge
    |
    | forkpty()
    v
/bin/sh as root
```

This gives proper ANSI colors, cursor movement, Ctrl-C/Ctrl-D, interactive
programs, terminal resize, prompts, and streaming output.

## Runtime pieces

- `core/net/Term.mm`: WebSocket handshake, PTY lifecycle, frame parsing, resize,
  shell spawn, cleanup.
- `core/net/HttpStreamServer.mm`: routes `/ws/term`.
- `web/`: React/Vite control app; xterm is bundled into the single-file
  `web/dist/index.html` staged onto the device.
- `web/legacy/`: old vanilla client and vendored xterm assets, reference only.

## WebSocket protocol

Browser to daemon uses binary frames:

```text
[1][UTF-8 input bytes]          write to PTY
[2][2B BE cols][2B BE rows]     resize PTY
```

Daemon to browser uses binary frames containing raw PTY bytes. The browser passes
them directly to xterm.js, so ANSI colors and cursor-control sequences are
handled by the terminal renderer.

## Shell environment

The PTY starts `/bin/sh` with:

```text
TERM=xterm-256color
HOME=/var/root
USER=root
LOGNAME=root
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

Default working directory is `/var/root`.

## Safety rules

- Closing the WebSocket closes the PTY and sends `SIGHUP` to the child shell.
- Output is streamed; commands are not logged by default.
- The terminal is root-equivalent. It must remain LAN/private until auth and
  internet transport are implemented.
- `/v1/exec` can be added later for bounded automation commands, but the primary
  operator interface should remain the PTY terminal.
