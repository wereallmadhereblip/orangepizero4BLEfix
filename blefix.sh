#!/usr/bin/env bash
set -e

# Must be run as root
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

# --- 1. FIRMWARE & CONFIG PREPARATION ---
echo "[1/6] Setting up AIC8800 firmware & hardware configs..."
if [ -d "$FW_DIR" ]; then
    cd "$FW_DIR"
    # Ensure backup exists
    if [ -f "$TARGET_FW" ] && [ ! -f "${TARGET_FW}.bak" ]; then
        cp -f "$TARGET_FW" "${TARGET_FW}.bak"
    fi
    # Link or copy combo Wi-Fi + BT firmware
    if [ -f "$COMBO_FW" ]; then
        cp -f "$COMBO_FW" "$TARGET_FW"
        echo "  [+] Active firmware set to combo BT+Wi-Fi binary."
    fi
    # Provide missing aichw.conf needed by driver
    if [ -f "$USER_CONF" ]; then
        cp -f "$USER_CONF" "$HW_CONF"
        echo "  [+] Generated $HW_CONF from userconfig."
    fi
else
    echo "  [!] Warning: $FW_DIR not found. Ensure kernel firmware is installed."
fi

# --- 2. MODULE CONFIGURATION ---
echo "[2/6] Writing module parameters to /etc/modprobe.d/aic8800.conf..."
cat << 'EOF' > /etc/modprobe.d/aic8800.conf
options aic8800_fdrv testmode=0
options aic8800_bsp btmode=1
EOF

# --- 3. SYSTEMD WAKE & UART ATTACH SERVICE ---
echo "[3/6] Generating permanent systemd Bluetooth attach service..."
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

# --- 4. PERSIST BLEAK / PYTHON ENVIRONMENT ---
echo "[4/6] Exporting BLEAK_ADAPTER=hci1 globally..."
if ! grep -q "BLEAK_ADAPTER" "$ENV_FILE" 2>/dev/null; then
    echo 'BLEAK_ADAPTER="hci1"' >> "$ENV_FILE"
else
    sed -i 's/BLEAK_ADAPTER=.*/BLEAK_ADAPTER="hci1"/' "$ENV_FILE"
fi

# --- 5. PATCH ANY MESHCORE / BOT SYSTEMD SERVICES ---
echo "[5/6] Injecting environment variables into meshcore bot service (if present)..."
for s in $(find /etc/systemd/system -name "*meshcore*" -o -name "*madhat*" 2>/dev/null); do
    if [ -f "$s" ] && ! grep -q "BLEAK_ADAPTER" "$s"; then
        sed -i '/\[Service\]/a Environment="BLEAK_ADAPTER=hci1"' "$s"
        echo "  [+] Patched $s with BLEAK_ADAPTER=hci1"
    fi
done

# --- 6. ATTEMPT LIVE INITIALIZATION ---
echo "[6/6] Initializing Bluetooth interfaces..."
systemctl stop aic-bluetooth.service 2>/dev/null || true
killall -9 hciattach 2>/dev/null || true
rfkill unblock bluetooth 2>/dev/null || true
echo 1 > /proc/bluetooth/sleep/btwrite 2>/dev/null || true

systemctl start aic-bluetooth.service || true
sleep 2

# Bring up working node
hciconfig hci1 up 2>/dev/null || true
bluetoothctl select B4:65:DC:BA:35:4F 2>/dev/null || bluetoothctl select hci1 2>/dev/null || true
bluetoothctl power on 2>/dev/null || true

echo "=========================================================="
echo "Fix complete! Current Bluetooth interfaces:"
hciconfig -a || true
echo "=========================================================="
echo "Note: If rebooting or flashing fresh, keep this script in your"
echo "repo or /root/ to run once after fresh installs."