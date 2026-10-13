# Tests that hit the real Eurostat APIs are excluded by default:
#
#   mix test --include integration   # Eurostatx against the live APIs
#   mix test --only restatapi        # Eurostatx vs. the official R package (requires Docker)
ExUnit.start(exclude: [:integration, :restatapi])
