# App Media Runtime

`rctlappmedia` runs inside the current foreground application. It provides the
live camera capture path and the virtual microphone injection point required by
calling applications.

The daemon coordinates sessions; this library owns app-process hooks, bounded
buffers, and cleanup. Preserve iOS 14, `arm64`, and `arm64e` support and test the
real foreground-app lifecycle, not only compilation.
