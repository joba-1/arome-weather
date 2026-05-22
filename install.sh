#!/bin/bash
# Installer for the aromeweather service.
#
# Steps:
#   1. parse locations.conf
#   2. install Python deps (conda env 'aromeweather' if conda is present,
#      otherwise a venv at ~/.venvs/aromeweather)
#   3. copy aromeweather.py and aromeweather.sh into ~/bin
#   4. create the InfluxDB database and insert location markers
#   5. install, enable and (re)start the systemd unit
#
# Re-running the installer is safe; existing installations are updated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCATIONS_FILE="${SCRIPT_DIR}/locations.conf"
LOCATIONS_TEMPLATE="${SCRIPT_DIR}/locations.conf.example"
SERVICE_IN="${SCRIPT_DIR}/aromeweather.service.in"

# Bootstrap locations.conf from the template on first run. The file is
# gitignored, so it survives 'git pull' and subsequent installer runs.
if [ ! -f "$LOCATIONS_FILE" ]; then
    if [ ! -f "$LOCATIONS_TEMPLATE" ]; then
        echo "Neither $LOCATIONS_FILE nor $LOCATIONS_TEMPLATE exists." >&2
        exit 1
    fi
    echo "Creating $LOCATIONS_FILE from template (edit it and re-run to customise)."
    cp "$LOCATIONS_TEMPLATE" "$LOCATIONS_FILE"
fi

INFLUX_HOST="${AROME_INFLUX_HOST:-localhost}"
INFLUX_DB="${AROME_INFLUX_DB:-aromeweather}"
SERVICE_USER="${SUDO_USER:-$USER}"
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"

if [ -z "$SERVICE_HOME" ]; then
    echo "Could not determine home directory for user '$SERVICE_USER'" >&2
    exit 1
fi

echo "Installing for user: $SERVICE_USER  (home: $SERVICE_HOME)"

# --- 1. parse locations.conf ---------------------------------------------
declare -a COORDS=()
declare -a NAMES=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line## }"
    line="${line%% }"
    [ -z "$line" ] && continue
    # split first whitespace-separated token (coords) from the rest (name)
    coord="$(echo "$line" | awk '{print $1}')"
    name="$(echo "$line" | awk '{$1=""; sub(/^ +/, ""); print}')"
    [ -z "$coord" ] && continue
    COORDS+=("$coord")
    NAMES+=("$name")
done < "$LOCATIONS_FILE"

if [ ${#COORDS[@]} -eq 0 ]; then
    echo "No locations found in $LOCATIONS_FILE" >&2
    exit 1
fi
echo "Found ${#COORDS[@]} locations."

# --- 2. Python environment ------------------------------------------------
install_with_conda() {
    # shellcheck disable=SC1091
    source "$(conda info --base)/etc/profile.d/conda.sh"
    if ! conda env list | awk '{print $1}' | grep -qx aromeweather; then
        echo "Creating conda env 'aromeweather'..."
        conda create -y -n aromeweather python requests python-dateutil
    else
        echo "Updating conda env 'aromeweather'..."
        conda install -y -n aromeweather requests python-dateutil
    fi
}

install_with_venv() {
    local venv="$SERVICE_HOME/.venvs/aromeweather"
    mkdir -p "$SERVICE_HOME/.venvs"
    if [ ! -d "$venv" ]; then
        echo "Creating venv $venv ..."
        python3 -m venv "$venv"
    fi
    "$venv/bin/pip" install --upgrade pip
    "$venv/bin/pip" install requests python-dateutil
}

if sudo -u "$SERVICE_USER" bash -lc 'command -v conda' >/dev/null 2>&1; then
    sudo -u "$SERVICE_USER" bash -lc "$(declare -f install_with_conda); install_with_conda"
else
    sudo -u "$SERVICE_USER" bash -lc "$(declare -f install_with_venv); SERVICE_HOME='$SERVICE_HOME' install_with_venv"
fi

# --- 3. copy scripts ------------------------------------------------------
install -d -o "$SERVICE_USER" -g "$(id -gn "$SERVICE_USER")" "$SERVICE_HOME/bin"
install -m 0755 -o "$SERVICE_USER" -g "$(id -gn "$SERVICE_USER")" \
    "$SCRIPT_DIR/aromeweather.py" "$SERVICE_HOME/bin/aromeweather.py"
install -m 0755 -o "$SERVICE_USER" -g "$(id -gn "$SERVICE_USER")" \
    "$SCRIPT_DIR/aromeweather.sh" "$SERVICE_HOME/bin/aromeweather.sh"

# --- 4. InfluxDB ----------------------------------------------------------
if command -v influx >/dev/null 2>&1; then
    echo "Ensuring InfluxDB database '$INFLUX_DB' exists on $INFLUX_HOST..."
    influx -host "$INFLUX_HOST" -execute "create database $INFLUX_DB"

    echo "Inserting location markers..."
    for i in "${!COORDS[@]}"; do
        coord="${COORDS[$i]}"
        name="${NAMES[$i]}"
        [ -z "$name" ] && continue
        lat="${coord%%,*}"
        lon="${coord##*,}"
        # tag values cannot contain spaces; replace with underscores
        tagname="${name// /_}"
        influx -host "$INFLUX_HOST" -database "$INFLUX_DB" -precision h \
            -execute "insert location,name=$tagname lat=$lat,lon=$lon" \
            || echo "  warn: failed to insert $name"
    done
else
    echo "WARNING: 'influx' CLI not found; skipping database setup." >&2
    echo "Run on a host with influx CLI access to $INFLUX_HOST:" >&2
    echo "  influx -host $INFLUX_HOST -execute \"create database $INFLUX_DB\"" >&2
fi

# --- 5. systemd unit ------------------------------------------------------
LOC_ARGS="${COORDS[*]}"
TMP_UNIT="$(mktemp)"
sed -e "s|@HOME@|$SERVICE_HOME|g" \
    -e "s|@USER@|$SERVICE_USER|g" \
    -e "s|@LOCATIONS@|$LOC_ARGS|g" \
    "$SERVICE_IN" > "$TMP_UNIT"

if [ "$(id -u)" -eq 0 ]; then
    install -m 0644 "$TMP_UNIT" /etc/systemd/system/aromeweather.service
    systemctl daemon-reload
    systemctl enable aromeweather.service
    systemctl restart aromeweather.service
    systemctl --no-pager status aromeweather.service || true
else
    echo "Not running as root; installing unit via sudo..."
    sudo install -m 0644 "$TMP_UNIT" /etc/systemd/system/aromeweather.service
    sudo systemctl daemon-reload
    sudo systemctl enable aromeweather.service
    sudo systemctl restart aromeweather.service
    sudo systemctl --no-pager status aromeweather.service || true
fi
rm -f "$TMP_UNIT"

echo
echo "Installation complete."
