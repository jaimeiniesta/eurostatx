# Queries run with restatapi, the R package published by Eurostat. Their
# results are compared with the ones of Eurostatx by
# test/restatapi/cross_check_test.exs.
#
# Usage (from the project root):
#
#   docker build -t eurostatx-restatapi test/restatapi
#   docker run --rm -v "$PWD/test/restatapi:/work" eurostatx-restatapi Rscript queries.R output
#
# Every query writes a JSON file (one object per data frame row) in the output dir.
# Requests are made one at a time, as Eurostat asks.

library(restatapi)
library(jsonlite)

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) > 0) args[[1]] else "output"
dir.create(out, showWarnings = FALSE, recursive = TRUE)

save <- function(name, df) {
  write_json(df, file.path(out, paste0(name, ".json")),
             dataframe = "rows", na = "null", null = "null",
             auto_unbox = TRUE, digits = NA, pretty = TRUE)
  cat(sprintf("%-28s %6d rows\n", name, if (is.null(nrow(df))) length(df) else nrow(df)))
}

# Data ------------------------------------------------------------------------

# Filters by dimension code and a range of years (SDMX REST API)
save("data_nama_10_gdp",
     get_eurostat_data("nama_10_gdp",
                       filters = list(geo = c("DE", "FR"), unit = "CP_MEUR", na_item = "B1GQ"),
                       date_filter = "2015:2020", keep_flags = TRUE, stringsAsFactors = FALSE))

# Monthly data with a key string
save("data_prc_hicp_minr",
     get_eurostat_data("prc_hicp_minr", filters = "M.RCH_A.TOTAL.EA+DE",
                       date_filter = "2025-01:2025-12", keep_flags = TRUE,
                       stringsAsFactors = FALSE))

# Quarterly data
save("data_namq_10_gdp",
     get_eurostat_data("namq_10_gdp",
                       filters = list(geo = "ES", unit = "CLV_PCH_PRE", s_adj = "SCA", na_item = "B1GQ"),
                       date_filter = "2022:2024", keep_flags = TRUE, stringsAsFactors = FALSE))

# A whole (small) dataset from the TSV download, with flags
save("raw_tps00001",
     get_eurostat_raw("tps00001", mode = "txt", keep_flags = TRUE, stringsAsFactors = FALSE))

# Metadata ---------------------------------------------------------------------

save("dsd_nama_10_gdp", get_eurostat_dsd("nama_10_gdp"))
save("dsd_tps00001_de", get_eurostat_dsd("tps00001", lang = "de"))
save("codelist_freq", get_eurostat_codelist("freq"))
save("codelist_unit_fr", get_eurostat_codelist("unit", lang = "fr"))
save("toc_txt", get_eurostat_toc(mode = "txt"))
