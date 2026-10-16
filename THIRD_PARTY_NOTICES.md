# Third-party notices

Pi Voice depends on third-party software. Those projects retain their own copyrights and licenses.

## Vendored pi-intercom package

`vendor/pi-intercom/pi-intercom-0.17.3.tgz` contains the exact source and generated client package used by Pi Voice. It is derived from [nicobailon/pi-intercom](https://github.com/nicobailon/pi-intercom) and is distributed under the MIT License.

The required license text is available at [`vendor/pi-intercom/LICENSE`](vendor/pi-intercom/LICENSE) and inside the archive as `package/LICENSE`.

## WebRTC native dependencies

The native clients use separately maintained WebRTC distributions. Their license and notice files are retained at:

- [`native/mac/Resources/ThirdPartyNotices`](native/mac/Resources/ThirdPartyNotices)
- [`native/phone/ThirdPartyNotices`](native/phone/ThirdPartyNotices)

## Package-manager dependencies

JavaScript and Swift dependencies resolved by the package manifests are not vendored in this repository, except for the pi-intercom archive above. Their package manifests and lockfiles identify the exact resolved packages. Installation remains subject to each dependency's license.
