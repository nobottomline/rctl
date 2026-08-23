# SpringBoard Agent

This thin injected component owns screen capture, orientation-aware input
injection, and SpringBoard-only actions. The daemon communicates with it through
the bounded IPC protocol in `core/ipc`.

Avoid network ownership and long-running policy here. Changes require physical
device validation across portrait/landscape, lock/unlock, respring, and viewer
disconnect paths.
