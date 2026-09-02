# Harbor 95

An unofficial desktop client for [Harbor](https://harbor.social/) built with a
Tcl/Tk 9 interface and the published Polycentric TypeScript/Rust SDK. It
connects to Harbor's production servers, supports creating or pairing an
identity, reads the public feed, and publishes signed text or image posts.

This is a standalone application: cloning the Harbor monorepo and compiling
its Rust workspace are not required.

## Requirements

- Linux with Tcl/Tk 9 and `wish`
- Node.js 22
- pnpm 10.34.5 (Corepack can install the pinned version)

On a Debian-derived system:

```sh
sudo apt install tk9.0
corepack enable
```

## Run

```sh
git clone https://github.com/SomewhatJustin/harbor-95.git
cd harbor-95
pnpm install
pnpm dev
```

The client uses the public Polycentric package registry configured in
`.npmrc`. It connects to `https://srv.harbor.social` and
`https://srv.polycentric.io` by default.

Local identity and post data is written to the ignored
`harbormaster-95-PROTOTYPE-data/` directory. Keep that directory private.
Deleting it resets this client's local identity.

## Pair an existing identity

1. Open **Settings > Pair Identity** at [harbor.social](https://harbor.social/)
   and create a pairing session.
2. Copy the pairing code.
3. In Harbor 95, select **Pair Identity**, paste the code, and continue.
4. Approve the pending key in Harbor Web.

The composer supports up to four local images per post. Images are converted
to Harbor's JPEG variants before upload.

## Configuration

Override the production servers with a comma-separated list:

```sh
POLYCENTRIC_SEED_SERVERS=https://example.invalid pnpm dev
```

Set `HARBOR95_DATA_DIR` to move the local database and blob directory.

## Status

This is experimental prototype software. It talks to production by default, so
posts and uploaded images are real and public.

## License and attribution

Harbor and Polycentric are projects of FUTO. This unofficial client was first
developed as a modification within FUTO's Harbor codebase and uses its
published SDK packages. It is distributed under the
[Source First License 1.1](LICENSE), including its non-commercial-use
limitation.
