# pi-intercom dependency binding

Pi Voice consumes the repository-relative package at `vendor/pi-intercom/pi-intercom-0.17.3.tgz`.

- Package version: `0.17.3`
- SHA-256: `ffe3d8921aea5edccb80e48285d1f713042ec80c7141e6e7b330055630555616`
- SHA-512 integrity: `sha512-IZHpKNG7YoI3ufYDGwzcHy7Gup4mTQr/wmkRgvNbG4UWHBC29fsnJC+tqxhzg96RvcQ5MnTRU3Z7XsZD2mH/ig==`

The archive contains its source, generated standalone client, declarations, and MIT license. It is a source-built, identity-sanitized successor to the reviewed package archive with SHA-256 `dec796c0a1aebbb94d2e3a06a201409a57c85ce6d1427c558e7d1e10b4de78ad`. Exactly two of its 52 members differ: `package/README.md` uses a generic voice-client example, and `package/broker/paths.test.ts` uses a generic example home username. The changes are nonfunctional identity sanitization; the other 50 archive members are byte-exact.

The package keeps Pi-host-provided SDK packages and `typebox` declared as optional peers. Pi can supply those packages when loading the extension, while standalone `pi-intercom/client` consumers do not install them.

Run `npm run check:vendored-intercom` to verify the archive hashes, lockfile binding, required files, license, and runtime client export.
