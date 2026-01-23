# Stratipi

Stratipi turns a Raspberry Pi into a highly accurate Stratum-1 NTP network time server by using a connected GPS receiver under FreeBSD.

---

## Features

* Uses GPS with PPS for precise timekeeping
* Runs on FreeBSD via Raspberry Pi
* Provides Stratum-1 NTP service

---

## Hardware Requirements

* Raspberry Pi 4 (other board support will come in the future)
* [Adafruit Ultimate GPS HAT for Raspberry Pi](https://www.adafruit.com/product/2324)
* GPS Antenna
* Ethernet/network connectivity (wired only, no wireless)
* SD card (industrial card recommended)

---

## Installation

1. Flash Stratipi image onto the SD card.
2. Insert flashed SD card into the Raspberry Pi.
3. Attach the GPS HAT to the Raspberry Pi.
3. Plug in Ethernet cable to Raspbery Pi.
4. Power on the Raspberry Pi.
5. ...
6. PROFIT!

---

## Contributing

Contributions are welcome.
Please submit issues and pull requests ot make Stratipi more AWESOME!

---

## License

This project is licensed under the BSD License.
See [`LICENSE`](https://github.com/circuitrewind/stratipi/blob/main/LICENSE) file for details.
