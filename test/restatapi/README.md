# Cross-check against restatapi

[restatapi](https://github.com/eurostat/restatapi) is the R client of the Eurostat SDMX API
published by Eurostat in its GitHub organization. This directory runs the same queries with
restatapi and with Eurostatx and compares the results: data values, flags, periods, the codes and
labels of the data structures and code lists, and the table of contents.

```sh
mix test --only restatapi
```

The test builds a Docker image with R and restatapi (`Dockerfile`), runs `queries.R` inside it and
compares its output with Eurostatx calls made against the live APIs. Docker is the only requirement.

To iterate faster, run the R queries once and reuse their output:

```sh
docker build -t eurostatx-restatapi test/restatapi
docker run --rm -v "$PWD/test/restatapi:/work" eurostatx-restatapi Rscript queries.R output
RESTATAPI_OUTPUT=$PWD/test/restatapi/output mix test --only restatapi
```
