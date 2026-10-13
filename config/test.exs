import Config

# Route every request through Req.Test stubs (see test/support/eurostat_case.ex).
# Integration tests (`mix test --include integration`) override this.
config :eurostatx,
  req_options: [plug: {Req.Test, Eurostatx.Client}, retry: false],
  async_interval: 0

config :logger, level: :warning
