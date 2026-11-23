# Sing VPN for iOS

The routing application in `PrototypeApp/` is the primary application on `main`.
It supports VLESS and VK TURN with application-owned DNS and routing rule sets.
The **Роутинги** tab selects the existing RoscomVPN rules or **Russia inside**
from [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains).
Russia inside sends listed domains through the VPN and all other traffic directly.
Changing routing automatically reconnects an active VPN; an offline VPN stays off.
The vipin-v2 subscription delivers both profiles and their binary rule sets in one response.
The next VPN start uses the latest validated revision, including starts from iOS Settings.
Bundled profiles allow offline startup before the first routing update.
The original standalone iOS interface has been retired; shared libraries and
other upstream platform targets remain available where required.

```sh
git clone --recurse-submodules https://github.com/acurofobia/sing-box-for-apple.git
cd sing-box-for-apple
scripts/build_vk_turn_prototype.sh
```

Build requirements, daily Git commands and dependency updates are documented in
[the development guide](docs/development.md). Device and runtime checks are in
[the routing application verification notes](docs/testing/vk-turn-prototype.md).

## Service WDTT release input

Release builds of the iOS app read `build/private/ServiceWDTT.json` by default.
Export the active revision on the backend with `python -m scripts.export_service_wdtt`
and redirect its stdout directly to that private file using a local umask of 077.
Debug builds use a synthetic fixture. Override the Xcode setting
`SERVICE_WDTT_RESOURCE` to exercise a real service connection on a test device.

The backend checks candidate credentials with `/usr/local/bin/service-wdtt-probe`
before publishing them. To rebuild the Linux amd64 executable from this checkout:

```sh
cd upstream/sing-box
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags '-s -w -checklinkname=0' \
  -tags 'with_gvisor,with_wireguard,badlinkname' -o ../../build/service-wdtt-probe ../../scripts/service-wdtt/probe.go
```

## License

```
Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.
```
