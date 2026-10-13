# R + restatapi, the R package published by Eurostat in its GitHub organization,
# used to cross-check Eurostatx against it. See test/restatapi/README.md.
FROM rocker/r-ver:4

RUN install2.r --error --skipinstalled restatapi jsonlite

WORKDIR /work
