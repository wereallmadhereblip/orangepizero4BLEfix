# AIC8800 Bluetooth Setup & Troubleshooting Guide
### Orange Pi Zero 4 (Debian Trixie / Kernel 6.6.x sun60iw2)

This guide documents the root cause and permanent solution for enabling onboard Bluetooth on the **Orange Pi Zero 4** equipped with the **AicSemi AIC8800D80** SDIO/UART combo chip.

---

## 1. Problem Overview

Out of the box on Debian Trixie (and similar Armbian/Orange Pi vendor builds), Wi-Fi functions normally, but Bluetooth fails to initialize. Common symptoms include:

- `hciconfig` displays `BD Address: 00:00:00:00:00:00` and `DOWN`.
- Running `hciconfig hci0 up` results in:
  ```text
  Can't init device hci0: Connection timed out (110)
  ```
- Kernel log (`dmesg`) reports:
  ```text
  Bluetooth: hci0: Opcode 0x1003 failed: -110
  Bluetooth: hci0: command 0x1003 tx timeout
  ```
- Python libraries using Bleak fail with:
  ```text
  ('No powered Bluetooth adapters found. Turn on Bluetooth and try again.', <BleakBluetoothNotAvailableReason.POWERED_OFF: 3>)
  ```

---

## 2. Root Causes Identified

1. **Wi-Fi-Only Firmware Loaded at Boot:**  
   The wireless kernel driver (`aic8800_fdrv`) defaults to loading `fmacfw_8800d80_u02.bin`, which lacks Bluetooth support. The combo microcode (`fmacfwbt_8800d80_u02.bin`) must be booted over SDIO to bring up the internal Bluetooth controller core.

2. **Missing `aichw.conf` Configuration:**  
   The driver fails to read `aic8800d80/aichw.conf` (error `-2`), preventing the driver from properly assigning clock rates and pin-mux states.

3. **Low-Power Management (LPM) Sleep State:**  
   The vendor `bluesleep` driver puts the chip into low-power sleep unless explicitly woken up via `/proc/bluetooth/sleep/btwrite`.

4. **UART Line Discipline & Baud Requirements:**  
   The AIC8800 UART driver requires hardware flow control (`flow`), `nosleep`, and a baud rate of `1500000` over `/dev/ttyS1`. It rejects 115200 baud without flow control.

5. **Phantom `hci0` Interface vs Active `hci1`:**  
   When the chip negotiates after previous failed attempts, the working controller often initializes as `hci1`, while the dead phantom device remains at `hci0`. Python's `bleak` defaults to `hci0` unless explicitly directed to `hci1`.

---

## 3. Automated One-Step Fix

Run the consolidated automated setup script below to apply all patches and configure the persistent background service.

### `fix_all_aic_bt.sh`

```bash
#!/usr/bin/env bash
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Please run as root (sudo $0)"
    exit 1
fi

echo "=========================================================="
echo "  AIC8800 Bluetooth Permanent Fix for Orange Pi Zero 4   "
echo "=========================================================="

FW_DIR="/lib/firmware/aic8800d80"
COMBO_FW="fmacfwbt_8800d80_u02.bin"
TARGET_FW="fmacfw_8800d80_u02.bin"
USER_CONF="aic_userconfig_8800d80.txt"
HW_CONF="aichw.conf"
ENV_FILE="/etc/environment"
SERVICE_PATH="/etc/systemd/system/aic-bluetooth.service"

# 1. Firmware & Hardware Config
echo "[1/6] Setting up AIC8800 firmware & configs..."
if [ -d "$FW_DIR" ]; then
    cd "$FW_DIR"
    if [ -f "$TARGET_FW" ] && [ ! -f "${TARGET_FW}.bak" ]; then
        cp -f "$TARGET_FW" "${TARGET_FW}.bak"
    fi
    if [ -f "$COMBO_FW" ]; then
        cp -f "$COMBO_FW" "$TARGET_FW"
        echo "  [+] Active firmware set to combo BT+Wi-Fi binary."
    fi
    if [ -f "$USER_CONF" ]; then
        cp -f "$USER_CONF" "$HW_CONF"
        echo "  [+] Generated $HW_CONF from user config."
    fi
fi

# 2. Kernel Module Configuration
echo "[2/6] Writing module parameters to /etc/modprobe.d/aic8800.conf..."
cat << 'EOF' > /etc/modprobe.d/aic8800.conf
options aic8800_fdrv testmode=0
options aic8800_bsp btmode=1
EOF

# 3. Systemd Auto-Attach Service
echo "[3/6] Installing persistent aic-bluetooth.service..."
cat << 'EOF' > "$SERVICE_PATH"
[Unit]
Description=AIC8800 Bluetooth UART Initialization & Wake Service
After=syslog.target network.target bluetooth.service
Before=bluetooth.target

[Service]
Type=forking
ExecStartPre=/usr/sbin/rfkill unblock bluetooth
ExecStartPre=/bin/sh -c 'echo 1 > /proc/bluetooth/sleep/btwrite 2>/dev/null || true'
ExecStart=/usr/bin/hciattach -s 1500000 /dev/ttyS1 any 1500000 flow nosleep
ExecStartPost=/bin/sleep 2
ExecStartPost=/bin/sh -c '/usr/bin/hciconfig hci1 up 2>/dev/null || /usr/bin/hciconfig hci0 up 2>/dev/null || true'
ExecStartPost=/bin/sh -c '/usr/bin/bluetoothctl power on || true'
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_PATH"
systemctl daemon-reload
systemctl enable aic-bluetooth.service
echo "  [+] Enabled aic-bluetooth.service."

# 4. Global Environment Variable for Bleak
echo "[4/6] Exporting BLEAK_ADAPTER=hci1 to /etc/environment..."
if ! grep -q "BLEAK_ADAPTER" "$ENV_FILE" 2>/dev/null; then
    echo 'BLEAK_ADAPTER="hci1"' >> "$ENV_FILE"
else
    sed -i 's/BLEAK_ADAPTER=.*/BLEAK_ADAPTER="hci1"/' "$ENV_FILE"
fi

# 5. Inject into Application Services
echo "[5/6] Patching systemd services with BLEAK_ADAPTER..."
for s in $(find /etc/systemd/system -name "*meshcore*" -o -name "*madhat*" 2>/dev/null); do
    if [ -f "$s" ] && ! grep -q "BLEAK_ADAPTER" "$s"; then
        sed -i '/\[Service\]/a Environment="BLEAK_ADAPTER=hci1"' "$s"
        echo "  [+] Patched $s"
    fi
done

# 6. Apply Live Settings
echo "[6/6] Initializing Bluetooth interfaces..."
systemctl stop aic-bluetooth.service 2>/dev/null || true
killall -9 hciattach 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true
echo 1 > /proc/bluetooth/sleep/btwrite 2>/dev/null || true

systemctl start aic-bluetooth.service || true
sleep 2

hciconfig hci1 up 2>/dev/null || true
bluetoothctl select hci1 2>/dev/null || true
bluetoothctl power on 2>/dev/null || true

echo "=========================================================="
echo "Done! Run 'hciconfig -a' or 'bluetoothctl show' to verify."
echo "=========================================================="
```

---

## 4. Verification Commands

### Check Interface Status
```bash
hciconfig -a
```
Look for `hci1` (or `hci0`) showing a non-zero MAC address and state `UP RUNNING`:
```text
hci1:   Type: Primary  Bus: UART
        BD Address: B4:65:DC:BA:35:4F  ACL MTU: 1021:9  SCO MTU: 255:4
        UP RUNNING
        RX bytes:698 acl:0 sco:0 events:40 errors:0
        TX bytes:443 acl:0 sco:0 commands:40 errors:0
```

### Check BlueZ Daemon
```bash
bluetoothctl show
```
Ensure `Powered: yes` is displayed.

### Test BLE Discovery (CLI)
```bash
bluetoothctl --timeout 5 scan on
```

---

## 5. Python / Bleak Configuration

Because the functional controller operates on `hci1`, ensure any Python scripts utilizing Bleak route to `hci1`:

### Environment Variable
```bash
export BLEAK_ADAPTER="hci1"
python3 your_application.py
```

### In Python Code
```python
import asyncio
import os
from bleak import BleakScanner

async def scan():
    adapter = os.environ.get("BLEAK_ADAPTER", "hci1")
    scanner = BleakScanner(adapter=adapter)
    devices = await scanner.discover(timeout=5.0)
    for dev in devices:
        print(f"Found: {dev.name or 'Unknown'} [{dev.address}] ({dev.rssi} dBm)")

asyncio.run(scan())
```