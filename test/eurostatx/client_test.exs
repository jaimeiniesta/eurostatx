defmodule Eurostatx.ClientTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Client
  alias Eurostatx.Error

  doctest Eurostatx.Client, only: [base_url: 1, agency_id: 1]

  describe "build_url/3" do
    test "joins the base URL of the agency and the path" do
      assert Client.build_url(:eurostat, "statistics/1.0/data/TPS00001", []) ==
               "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/TPS00001"

      assert Client.build_url(:comext, "sdmx/2.1/data/DS-045409", []) ==
               "https://ec.europa.eu/eurostat/api/comext/dissemination/sdmx/2.1/data/DS-045409"

      assert Client.build_url(:taxud, "sdmx/2.1/dataflow/TAXUD/all", []) ==
               "https://webgate.ec.europa.eu/taxation_customs/redisstat/api/dissemination/sdmx/2.1/dataflow/TAXUD/all"
    end

    test "percent-encodes the params, including the brackets of the component filters" do
      url =
        Client.build_url(:eurostat, "x", [
          {"c[geo]", "DE,FR"},
          {"c[TIME_PERIOD]", "ge:2020+le:2021"}
        ])

      assert url =~ "?c%5Bgeo%5D=DE%2CFR&c%5BTIME_PERIOD%5D=ge%3A2020%2Ble%3A2021"
    end
  end

  describe "get/3" do
    test "returns the decoded JSON and sends the params in order, keeping repeated keys" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      assert {:ok, %{"class" => "dataset", "size" => [1, 1, 1, 2, 3]}} =
               Client.get(["statistics", "1.0", "data", "nama_10_gdp"], [
                 {"geo", "DE"},
                 {"geo", "FR"},
                 {"lastTimePeriod", nil},
                 {:lang, "EN"}
               ])

      assert assert_eurostat_request("statistics/1.0/data/nama_10_gdp") ==
               [{"geo", "DE"}, {"geo", "FR"}, {"lang", "EN"}]
    end

    test "keeps the characters of SDMX keys and REDISSTAT ids in the path" do
      stub_eurostat({200, "{}"})

      assert {:ok, %{}} =
               Client.get(["sdmx", "2.1", "data", "LMP_EXPME$HR", "A..DE+FR"], [], agency: :empl)

      assert [%{agency: :empl, endpoint: "sdmx/2.1/data/LMP_EXPME$HR/A..DE+FR"}] =
               eurostat_requests()
    end

    test "decompresses gzipped bodies without a Content-Encoding header" do
      stub_eurostat({:gzip, {:fixture, "sdmx3_data_nama_10_gdp.tsv"}})

      assert {:ok, tsv} = Client.get(["sdmx", "3.0", "data"])
      assert tsv == fixture("sdmx3_data_nama_10_gdp.tsv")
    end

    test "decodes gzipped JSON" do
      stub_eurostat({:gzip, {:fixture, "sdmx3_data_nama_10_gdp.json"}})

      assert {:ok, %{"class" => "dataset"}} = Client.get(["sdmx", "3.0", "data"])
    end

    test "decode: :text decompresses but does not decode JSON" do
      stub_eurostat({:gzip, {:fixture, "codelist_freq.json"}})

      assert {:ok, "{" <> _json} = Client.get(["sdmx"], [], decode: :text)
    end

    test "decode: :binary returns the body untouched" do
      stub_eurostat({:fixture, "metabase.txt.gz"})

      assert {:ok, <<0x1F, 0x8B, _rest::binary>>} = Client.get(["files", ""], [], decode: :binary)
    end

    test "returns other formats as binaries" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.csv"})

      assert {:ok, "STRUCTURE,STRUCTURE_ID," <> _rest} = Client.get(["sdmx"])
    end

    test "sends a user agent" do
      stub_eurostat({200, "{}"})
      assert {:ok, _json} = Client.get(["statistics"])

      assert [%{headers: headers}] = eurostat_requests()
      assert {"user-agent", "eurostatx/" <> _version} = List.keyfind(headers, "user-agent", 0)
    end
  end

  describe "errors" do
    test "SOAP faults with an unknown dimension value" do
      stub_eurostat({400, {:fixture, "fault_invalid_value.xml"}})

      assert {:error, %Error{type: :invalid_query, status: 400, code: "150", message: message}} =
               Client.get(["sdmx"])

      assert message =~ "INVALID_QUERY_DIMENSION_VALUE"
      # XML entities are decoded
      assert message =~ "structure's definition"
    end

    test "SOAP faults for an invalid key" do
      stub_eurostat({400, {:fixture, "fault_invalid_key.xml"}})

      assert {:error,
              %Error{type: :invalid_query, code: "140", message: "INVALID_URL_VALUE" <> _}} =
               Client.get(["sdmx"])
    end

    test "SOAP faults for unknown datasets" do
      stub_eurostat({404, {:fixture, "fault_not_found.xml"}})

      assert {:error, %Error{type: :not_found, status: 404, code: "100"}} = Client.get(["sdmx"])
    end

    test "SOAP faults for extractions above the limit" do
      stub_eurostat({413, {:fixture, "fault_too_big.xml"}})

      assert {:error,
              %Error{type: :too_big, status: 413, code: "413", message: "EXTRACTION_TOO_BIG" <> _}} =
               Client.get(["sdmx"])
    end

    test "JSON errors of the Statistics API (a list)" do
      stub_eurostat({400, {:fixture, "statistics_error_geo_level.json"}})

      assert {:error, %Error{type: :invalid_query, status: 400, code: "400", message: message}} =
               Client.get(["statistics"])

      assert message =~ "'geo' parameter and 'geoLevel' parameter cannot be set at the same time"
    end

    test "JSON errors for unknown datasets and big extractions" do
      stub_eurostat({404, {:fixture, "statistics_error_not_found.json"}})
      assert {:error, %Error{type: :not_found, code: "100"}} = Client.get(["statistics"])

      stub_eurostat({413, {:fixture, "statistics_error_too_big.json"}})
      assert {:error, %Error{type: :too_big, code: "413"}} = Client.get(["statistics"])
    end

    test "JSON errors of the SDMX API with format=json" do
      stub_eurostat({400, {:fixture, "sdmx3_error_invalid_time.json"}})

      assert {:error, %Error{type: :invalid_query, code: "150"}} = Client.get(["sdmx"])
    end

    test "HTML pages of the files API" do
      stub_eurostat({404, {:fixture, "files_404.html"}})

      assert {:error,
              %Error{
                type: :not_found,
                message: "File nope.zip does not exist or is not readable on the server"
              }} = Client.get(["files", ""])
    end

    test "unexpected statuses" do
      stub_eurostat({500, "Request failed."})

      assert {:error, %Error{type: :api_error, status: 500, message: "Request failed."}} =
               Client.get(["sdmx"])
    end

    test "invalid JSON" do
      stub_eurostat({200, "{not json"})
      assert {:error, %Error{type: :decode_error}} = Client.get(["sdmx"])
    end

    test "invalid gzip" do
      stub_eurostat({200, <<0x1F, 0x8B, 1, 2, 3>>})
      assert {:error, %Error{type: :decode_error}} = Client.get(["sdmx"])
    end

    test "transport errors" do
      stub_eurostat(&Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{type: :request_error, status: nil, message: message}} =
               Client.get(["sdmx"])

      assert message =~ "connection refused"
    end
  end

  describe "asynchronous responses" do
    @data "sdmx/2.1/data/DS-045409/A.FI.CA..2.SUPPLEMENTARY_QUANTITY"
    @status "1.0/async/status/91430d7b-0fdc-4dac-9d06-3b7126518120"
    @async_data "1.0/async/data/91430d7b-0fdc-4dac-9d06-3b7126518120"

    test "waits for the data of queued SDMX requests" do
      stub_eurostat(%{
        @data => {:fixture, "async_queued.xml"},
        @status => [
          {:fixture, "async_status_submitted.xml"},
          {:fixture, "async_status_available.xml"}
        ],
        @async_data => {:fixture, "async_data.csv"}
      })

      assert {:ok, "DATAFLOW,LAST UPDATE," <> _rest} =
               Client.get(String.split(@data, "/"), [], agency: :comext)

      assert Enum.map(eurostat_requests(), &{&1.agency, &1.endpoint}) == [
               {:comext, @data},
               {:comext, @status},
               {:comext, @status},
               {:comext, @async_data}
             ]
    end

    test "returns a :queued error with the request id when async_timeout is 0" do
      stub_eurostat(%{@data => {:fixture, "async_queued.xml"}})

      assert {:error, %Error{type: :queued, request_id: "91430d7b-0fdc-4dac-9d06-3b7126518120"}} =
               Client.get(String.split(@data, "/"), [], agency: :comext, async_timeout: 0)
    end

    test "returns a :queued error when the data is not ready in time" do
      stub_eurostat(%{
        @data => {:fixture, "async_queued.xml"},
        @status => {:fixture, "async_status_submitted.xml"}
      })

      assert {:error, %Error{type: :queued, request_id: "91430d7b-" <> _}} =
               Client.get(String.split(@data, "/"), [],
                 agency: :comext,
                 async_timeout: 30,
                 async_interval: 10
               )
    end

    test "repeats the Statistics requests answered asynchronously" do
      stub_eurostat(%{
        "statistics/1.0/data/x" => [
          {413, {:fixture, "statistics_asynchronous.json"}},
          {413, {:fixture, "statistics_asynchronous.json"}},
          {:fixture, "statistics_nama_10_gdp.json"}
        ]
      })

      assert {:ok, %{"class" => "dataset"}} = Client.get(["statistics", "1.0", "data", "x"])
      assert length(eurostat_requests()) == 3
    end

    test "returns a :queued error without request id for the Statistics API" do
      stub_eurostat({413, {:fixture, "statistics_asynchronous.json"}})

      assert {:error, %Error{type: :queued, request_id: nil}} =
               Client.get(["statistics", "1.0", "data", "x"], [], async_timeout: 0)
    end

    # The format shown in the "API - Detailed guidelines - API Statistics" guide
    test "repeats the Statistics requests answered with the documented asynchronous warning" do
      warning =
        ~s({"warning":{"status":413,"label":"ASYNCHRONOUS_RESPONSE. Your request will be treated asynchronously. Please try again later."}})

      stub_eurostat(%{
        "statistics/1.0/data/x" => [
          {200, warning},
          {200, warning},
          {:fixture, "statistics_nama_10_gdp.json"}
        ]
      })

      assert {:ok, %{"class" => "dataset"}} = Client.get(["statistics", "1.0", "data", "x"])
      assert length(eurostat_requests()) == 3
    end
  end
end
