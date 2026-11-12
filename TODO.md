# TODO

## Accessories

- [ ] **MX Master on a Bolt receiver: test the slot scan.** The MX connector finds the mouse by scanning Bolt/Unifying
  slots 1–6 (pairing record = mouse, name = MX Master) and ignores reports from other slots. Untested with real
  hardware: the MX Master has only been used over Bluetooth. Pair it to the Bolt receiver on a free Easy-Switch
  channel (it should land in slot 3 next to the two keyboards), quit Logi Options+, then check that it's found in that
  slot, configured there, and that keyboard reports on the same receiver are ignored.
- [ ] **MX Master: re-test input features since they moved to HID++ diversion** — scroll direction, smooth scrolling,
  scroll speed, thumbwheel actions, Middle/Back/Forward remaps and hold-and-drag gestures. Check scroll and thumbwheel
  direction (a sign flip each if wrong) and the thumbwheel's horizontal-scroll speed (2 px per step is a guess).
- [ ] **G2 Superstrike: test 8 kHz report rate.** Only 1 kHz and 2 kHz have been tried; some receivers need a special
  mode for 8 kHz. Its report rate is currently 125 Hz — set it back to 1000 Hz unless that was intended.
- [ ] **G2 Superstrike: test the onboard-profile write with the USB cable connected.** The profile stores report rate
  twice (probably wired and wireless); the app writes the same value to both.
- [ ] **G2 Superstrike over USB cable.** The G515 is found over its cable (its own product ID, HID++ index 0xFF);
  the G2 needs its wired product ID added to `wiredProductIDs` the same way.
