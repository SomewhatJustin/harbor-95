# AGENTS.md

## Architecture

Harbor 95 is a standalone Tcl/Tk desktop client. `ui.tcl` owns presentation
and launches `src/bridge.ts` as a child process. The bridge uses published
Polycentric core, storage, and Rust/WASM packages through the SQLite/filesystem
adapter in `src/node-client.ts`, and exchanges flat newline-delimited JSON with
Tcl.

## Development

- Install dependencies with `pnpm install`.
- Launch with `pnpm dev`.
- Validate changes with `pnpm check`.
- Keep Tcl/Tk UI code in `ui.tcl` and SDK integration in `src/bridge.ts`.
- Pin all `@polycentric/*` packages to the same exact release.

## Safety

- Treat `harbormaster-95-PROTOTYPE-data/` as private identity material. Never
  inspect, commit, publish, move, or delete a user's copy without an explicit
  request.
- The default endpoints are production. Do not publish test posts or upload
  fixtures unless the user explicitly authorizes that external effect.
- For smoke tests, set `HARBOR95_DATA_DIR` to a fresh temporary directory and
  `POLYCENTRIC_SEED_SERVERS` to a local unreachable URL.
- Preserve `LICENSE` and the attribution notice in `README.md`.

## Bridge protocol

- Keep the NDJSON bridge backward-compatible between `ui.tcl` and
  `src/bridge.ts`.
- Do not introduce nested JSON in Tcl-generated requests. Values crossing the
  bridge should remain flat strings, numbers, booleans, or encoded strings.
- Send diagnostics to stderr because stdout is reserved for protocol messages.
