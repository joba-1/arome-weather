# arome-weather

A small Linux service that polls the [open-meteo.com](https://open-meteo.com)
**MeteoFrance** API (AROME for short-range hourly forecasts, ARPEGE for the
longer-range daily forecast) and writes the results into an
[InfluxDB 1.x](https://docs.influxdata.com/influxdb/v1/) database. Grafana
(or anything else that speaks InfluxQL) can then chart the forecast next to
measured data.

The repo ships with a handful of European capitals as example locations
(`locations.conf`); replace them with whatever you care about.

## What it does

`aromeweather.py` runs as a long-lived systemd service. Every hour it:

1. For each configured `lat,lon`, requests the MeteoFrance forecast from
   `api.open-meteo.com/v1/meteofrance` (hourly + daily fields, timezone
   `Europe/Berlin`).
2. Converts each row of the response into an InfluxDB line-protocol point.
   Measurements are `hourly` and `daily`; tag keys are `lat`/`lon`
   (2-decimal precision), the timestamp is rounded to the hour.
3. POSTs the points to `http://<INFLUX_HOST>:8086/write?db=aromeweather`.

A separate `location` measurement maps each `lat,lon` to a human-readable
name so dashboards can resolve coordinates to a place name.

## Repository layout

| File                       | Purpose                                              |
|----------------------------|------------------------------------------------------|
| `aromeweather.py`          | The polling script.                                  |
| `aromeweather.sh`          | Wrapper that activates the Python env and execs `aromeweather.py`. |
| `aromeweather.service.in`  | systemd unit template (`@HOME@`, `@USER@`, `@LOCATIONS@` are filled in by the installer). |
| `locations.conf.example`   | Template list of `lat,lon  name` pairs (the installer copies this to `locations.conf` on first run; the copy is gitignored and never overwritten afterwards). |
| `install.sh`               | End-to-end installer (env, files, InfluxDB, systemd). |

## Requirements

* Linux with systemd
* Python 3 with `requests` and `python-dateutil`
  * The installer creates a conda env named `aromeweather` if `conda` is
    found on `$PATH`, otherwise it falls back to a venv at
    `~/.venvs/aromeweather`.
* Network access to `api.open-meteo.com`
* InfluxDB 1.x reachable at `AROME_INFLUX_HOST` (default `localhost`)
  port 8086, with no authentication; the `influx` CLI is used by the
  installer to create the database and insert location markers.

## Install

```
git clone <this repo>
cd arome-weather
./install.sh
```

The installer is idempotent — re-run it after editing `locations.conf` to
update the polled set and the location markers, then it will restart the
service.

Override defaults via environment variables:

```
AROME_INFLUX_HOST=other-host AROME_INFLUX_DB=weather ./install.sh
```

The Python script honours the same `AROME_INFLUX_HOST`,
`AROME_INFLUX_PORT`, `AROME_INFLUX_DB` env vars at runtime.

## Adding a location

1. Append a line to `locations.conf` (`lat,lon  Name`). On a fresh
   checkout this file is created from `locations.conf.example` on the
   first installer run.
2. Re-run `./install.sh`.

The installer regenerates the systemd unit's `ExecStart`, re-inserts the
location markers into InfluxDB, and restarts the service.

Your `locations.conf` is gitignored and is **not** overwritten by
subsequent installer runs or by `git pull`, so it is safe to maintain
the production list in-place.

## Backfilling history

Open-meteo serves up to 92 days of past data. To pull history for a single
location without disturbing the running service:

```
~/bin/aromeweather.sh -1 49.26,8.59
```

`-1` / `--one-shot` runs once with `past_days=92`, writes to InfluxDB, and
exits.

## Inspecting the data

```
influx -host localhost -database aromeweather
> show measurements
> select * from location
> select temperature_2m from hourly where lat = 48.78 and lon = 9.18 order by time desc limit 5
```

## Notes / caveats

* The coordinate precision in InfluxDB tags is 2 decimals (≈1 km). Two
  locations rounded to the same 2-decimal `lat,lon` will collide — pick
  representative coordinates accordingly.
* No retry/backoff: if open-meteo or InfluxDB is down for an hour, that
  hour's update is lost. The next hourly tick re-fetches and overwrites
  the affected timestamps anyway, since open-meteo always returns the
  full forecast window.
* Keep the `lat,lon` in `locations.conf` and the InfluxDB `location`
  marker in sync (the installer does this for you); otherwise dashboards
  that join on coordinates will fail to resolve the location name.
