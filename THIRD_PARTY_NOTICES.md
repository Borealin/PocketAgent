# Third-party notices

- AgentKit, AkinoKaede contributors, MIT. Pinned revision in dependencies.json: the Borealin/AgentKit fork branch
  `codex/pocketagent-bounded-consume`, upstream plus a bounded provider response API.
  License bundled as AgentKit-LICENSE.txt.
- AgentKit's Swift dependencies, ScrubberKit and SwiftSoup, MIT. Release builds
  include their original notices and a manifest of the pinned revisions from
  Package.resolved in SwiftLicenses.
- idevice, Jackson Coxson, MIT. Native/idevice-LICENSE.txt applies to generated
  FFI headers and local patch. Rust transitive dependency licenses remain in
  their Cargo source packages; release builds bundle their license texts and
  a sanitized package manifest generated from the locked Cargo dependency graph.
- WebDriverAgent, Facebook/Appium contributors, BSD-3-Clause.
  Native/WebDriverAgent-LICENSE.txt is bundled in the companion runner IPA.

- iSH (ish-app/ish), Theodore Dubois and contributors: GPL-3.0, with
  contributions additionally licensed GPL-2.0 so it can be linked with Linux
  (LICENSE.md) and the additional permission in LICENSE.IOS. The iSH Linux
  kernel fork is GPL-2.0-only; libarchive is BSD-2-Clause. The combined runtime,
  and therefore the PocketAgent app binary that links it, is distributed under
  the terms of the GNU GPL version 2. PocketAgent's own source (MIT) and its
  patches to iSH and Linux in Native/ish/patches are offered under terms
  compatible with that license. Pinned archives are listed in dependencies.json.
  Release builds bundle the license texts in iSHLicenses and publish
  PocketAgent-iSH-source-<version>.tar.gz next to each IPA: the PocketAgent
  source tree, the pinned iSH, Linux and libarchive archives, the Swift package
  and idevice sources and the vendored Rust crates used by the build.
- Alpine Linux 3.19 i386 packages in the bundled rootfs (bash, python3, py3-pip,
  nodejs, npm, ca-certificates and their dependencies) keep their own licenses;
  /etc/pocketagent-packages inside the rootfs lists exact versions, whose sources
  are in the Alpine v3.19 repositories.
- Operit2 (AGPL-3.0) was studied as a reference for embedding iSH; none of its
  code, patches or scripts are copied into this repository.

Apple SDK/runtime components retain Apple's license. No private pairing data,
provisioning profiles, signing credentials or third-party application data are
part of the source or distribution artifacts.
