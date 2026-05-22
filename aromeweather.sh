#!/bin/bash
# Wrapper used by the systemd unit. Activates the conda env (if any) and
# execs the Python script with all forwarded arguments.
set -e
if [ -f "$HOME/.bashrc" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.bashrc"
fi
if command -v conda >/dev/null 2>&1 && conda env list | awk '{print $1}' | grep -qx aromeweather; then
    # shellcheck disable=SC1091
    conda activate aromeweather
elif [ -f "$HOME/.venvs/aromeweather/bin/activate" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.venvs/aromeweather/bin/activate"
fi
exec python -u "$HOME/bin/aromeweather.py" "$@"
