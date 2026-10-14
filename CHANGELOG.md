# Changelog

## Unreleased

- Livebooks: *The EU in Charts* replaces *The European Economy* and reproduces the charts of the
  [demo](https://jaimeiniesta.com/en/eurostatx), map included. *Getting Started* and *Exploring
  Datasets* are simpler.

## v0.1.0

Initial release.

- Coverage of every API described in the Eurostat API guides: Statistics, SDMX 3.0 and 2.1 data
  and structure queries, Catalogue (table of contents, RSS, DCAT, metabase), asynchronous and files
  APIs.
- Eurostat, Comext/Prodcom (selected automatically for `DS-` datasets) and the REDISSTAT agencies
  (`:ecfin`, `:empl`, `:grow`, `:taxud`).
- Data frames: `Eurostatx.Statistics.data_as_data_frame/2` and
  `Eurostatx.Data.get_as_data_frame/2`, with long (tidy) and wide data frames, labels in English,
  French or German, and dates for every period type.
- Validated, documented options (`NimbleOptions`) translated into the parameters of each API:
  filters, keys, time ranges, observation limits, formats (JSON-stat, SDMX-CSV, TSV, SDMX-ML),
  detail and references.
- Parsed metadata: datasets with their annotations, data structures, availability, codes and labels
  used by each dimension, code lists, table of contents (TXT and XML) and search, RSS feed,
  metabase, inventories and directory listings.
- Transparent handling of compressed and asynchronous responses, normalization of the Eurostat
  error responses into `Eurostatx.Error`.
- Telemetry events and a built-in logger.
- Livebook notebooks.
- Test suite with recorded responses, integration tests and a cross-check against `restatapi`.
