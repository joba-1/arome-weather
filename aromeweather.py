#!/usr/bin/env python3
"""Poll open-meteo.com MeteoFrance forecasts and write them to InfluxDB.

Usage:
    aromeweather.py [--one-shot|-1] lat,lon [lat,lon ...]

Without arguments the default location is used. The script loops forever,
fetching a fresh forecast every hour, unless --one-shot is given (then it
fetches once with 92 days of history and exits).
"""

import os
import sys
import time
import requests
import dateutil.parser as dp


DEFAULT_LATITUDE = 48.83
DEFAULT_LONGITUDE = 9.11

INFLUX_HOST = os.environ.get("AROME_INFLUX_HOST", "localhost")
INFLUX_PORT = int(os.environ.get("AROME_INFLUX_PORT", "8086"))
INFLUX_DB = os.environ.get("AROME_INFLUX_DB", "aromeweather")

HOURLY_FIELDS = (
    "temperature_2m,relativehumidity_2m,dewpoint_2m,precipitation,snowfall,"
    "weathercode,pressure_msl,surface_pressure,cloudcover,"
    "et0_fao_evapotranspiration,vapor_pressure_deficit,"
    "windspeed_10m,winddirection_10m,windgusts_10m,"
    "shortwave_radiation,direct_radiation,diffuse_radiation,"
    "direct_normal_irradiance,terrestrial_radiation"
)
DAILY_FIELDS = (
    "weathercode,temperature_2m_max,temperature_2m_min,sunrise,sunset,"
    "precipitation_sum,precipitation_hours,"
    "windspeed_10m_max,windgusts_10m_max,winddirection_10m_dominant,"
    "shortwave_radiation_sum,et0_fao_evapotranspiration"
)


def get_positions(argv):
    """Parse 'lat,lon' arguments and the --one-shot flag."""
    locs = []
    one_shot = False
    for arg in argv[1:]:
        if arg in ("-1", "--one-shot"):
            one_shot = True
            continue
        try:
            lat, lon = arg.split(",", 1)
            locs.append((float(lat), float(lon)))
        except ValueError:
            print(f"ignoring parameter '{arg}'. Expected 'lat,lon'")
    if not locs:
        locs.append((DEFAULT_LATITUDE, DEFAULT_LONGITUDE))
    return locs, one_shot


def get_weather_meteofrance(lat, lon, days=None):
    url = "https://api.open-meteo.com/v1/meteofrance"
    query = {
        "latitude": lat,
        "longitude": lon,
        "hourly": HOURLY_FIELDS,
        "daily": DAILY_FIELDS,
        "timezone": "Europe/Berlin",
    }
    if days is not None:
        query["past_days"] = days  # api max: 92
    r = requests.get(url, query, timeout=30)
    r.raise_for_status()
    return r.json()


def put_table_influx(pos, name, table):
    url = f"http://{INFLUX_HOST}:{INFLUX_PORT}/write"
    query = {"db": INFLUX_DB, "precision": "h"}
    lat, lon = pos
    count = 0
    for index, _ in enumerate(table["time"]):
        try:
            line = f"{name},lat={lat:.2f},lon={lon:.2f}"
            sep = " "
            t_in_hours = 0
            for key in table.keys():
                data = table[key][index]
                if key == "time":
                    t_in_hours = int(dp.parse(data).timestamp() // 3600)
                elif data is not None:
                    if isinstance(data, (int, float)):
                        line += f"{sep}{key}={data}"
                    else:
                        line += f'{sep}{key}="{data}"'
                    sep = ","
            line += f" {t_in_hours}"
            r = requests.post(url, params=query, data=line, timeout=30)
            r.raise_for_status()
            count += 1
        except Exception as e:
            print(e)
    return count


def put_weather_influx(json_weather):
    pos = (json_weather["latitude"], json_weather["longitude"])
    h = put_table_influx(pos, "hourly", json_weather["hourly"])
    d = put_table_influx(pos, "daily", json_weather["daily"])
    print(f"InfluxDB updated {h} hours and {d} days for {pos}")


def main():
    locs, one_shot = get_positions(sys.argv)
    if one_shot:
        for lat, lon in locs:
            json_weather = get_weather_meteofrance(lat, lon, days=92)
            put_weather_influx(json_weather)
        return

    while True:
        try:
            for lat, lon in locs:
                json_weather = get_weather_meteofrance(lat, lon)
                put_weather_influx(json_weather)
        except Exception as e:
            print(e)
        time.sleep(3600)


if __name__ == "__main__":
    main()
