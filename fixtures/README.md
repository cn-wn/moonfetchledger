# Public data fixture

`earthquakes-2024-01-01.csv` is an unmodified USGS response downloaded 2026-10-09:

https://earthquake.usgs.gov/fdsnws/event/1/query?format=csv&starttime=2024-01-01&endtime=2024-01-02&minmagnitude=2&orderby=time-asc

- Scope: 2024-01-01 UTC, magnitude >= 2, ascending event time.
- Size: 28008 bytes.
- SHA-256: `dca55780e807e6b6dc5dafe53a621bf99929681551ab85bb4a27f5142e208042`.
- Public-domain US government data; policy:
  https://www.usgs.gov/information-policies-and-instructions/copyrights-and-credits

The live catalog can be revised. Tests use this committed snapshot offline.
The tool treats it as binary data and does not interpret the measurements.
