# Device Control Client

This Vite/React application is the current control UI for both local and relay
sessions. The production build is a self-contained `dist/index.html` embedded in
the device package.

Use `npm ci`, `npm run build`, and browser/device testing. Keep local and relay
capability negotiation aligned; `legacy/` is reference-only and must not receive
new product work.
