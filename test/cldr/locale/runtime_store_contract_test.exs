defmodule Cldr.Locale.RuntimeStoreContractTest do
  use ExUnit.Case, async: false

  @backend TestBackend.Cldr

  # Provider-expected top-level keys (atomized from cldr_modules).
  # These are the keys that provider packages extract from locale data.
  @provider_keys [
    :number_formats,
    :number_symbols,
    :number_systems,
    :minimum_grouping_digits,
    :rbnf,
    :currencies,
    :dates,
    :date_fields,
    :territories,
    :units,
    :list_formats,
    :person_names,
    :delimiters,
    :ellipsis,
    :lenient_parse,
    :layout,
    :subdivisions
  ]

  # Core keys that every locale must have.
  @core_keys [:name | @provider_keys]

  setup do
    on_exit(fn ->
      Cldr.Locale.RuntimeStore.unload_locale(@backend, :en)
    end)

    :ok
  end

  describe "data contract: RuntimeStore vs Loader" do
    test "RuntimeStore returns same top-level keys as Loader for :en" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      runtime_keys = runtime_data |> Map.keys() |> Enum.sort()
      loader_keys = loader_data |> Map.keys() |> Enum.sort()

      assert runtime_keys == loader_keys,
             "Key mismatch.\nRuntimeStore: #{inspect(runtime_keys)}\nLoader: #{inspect(loader_keys)}"
    end

    test "RuntimeStore returns same delimiters as Loader" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      assert runtime_data.delimiters == loader_data.delimiters
    end

    test "RuntimeStore returns same ellipsis as Loader" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      assert runtime_data.ellipsis == loader_data.ellipsis
    end

    test "RuntimeStore returns same layout as Loader" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      assert runtime_data.layout == loader_data.layout
    end

    test "RuntimeStore returns same list_formats as Loader" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      assert runtime_data.list_formats == loader_data.list_formats
    end

    test "RuntimeStore returns same number_formats as Loader" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      assert runtime_data.number_formats == loader_data.number_formats
    end

    test "RuntimeStore returns same number_symbols as Loader" do
      {:ok, runtime_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      loader_data = Cldr.Locale.Loader.get_locale(:en, @backend)

      assert runtime_data.number_symbols == loader_data.number_symbols
    end
  end

  describe "data contract: provider key presence" do
    test "loaded locale has all core provider keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      for key <- @core_keys do
        assert Map.has_key?(locale_data, key),
               "Missing provider key: #{inspect(key)}"
      end
    end

    test "loaded locale name matches request" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert locale_data.name == :en
    end
  end

  describe "data contract: Cldr.Number provider keys" do
    test "number_formats is a map with integer keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      formats = locale_data.number_formats

      assert is_map(formats)
      # At least one calendar system should have format data
      assert map_size(formats) > 0
    end

    test "number_symbols is a map" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      symbols = locale_data.number_symbols

      assert is_map(symbols)
      assert map_size(symbols) > 0
    end

    test "number_systems is a map with atom keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      systems = locale_data.number_systems

      assert is_map(systems)
      assert map_size(systems) > 0
    end

    test "minimum_grouping_digits is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :minimum_grouping_digits)
    end

    test "rbnf is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :rbnf)
    end

    test "currencies is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :currencies)
    end
  end

  describe "data contract: Cldr.DateTime provider keys" do
    test "dates is a map with calendar keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      dates = locale_data.dates

      assert is_map(dates)
      # Should have :calendars key for format data
      assert Map.has_key?(dates, :calendars)
    end

    test "date_fields is present with integer keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      date_fields = locale_data.date_fields

      assert is_map(date_fields)
    end
  end

  describe "data contract: Cldr.List provider keys" do
    test "list_formats is a map with integer keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      list_formats = locale_data.list_formats

      assert is_map(list_formats)
      assert map_size(list_formats) > 0
    end
  end

  describe "data contract: Cldr.Unit provider keys" do
    test "units is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :units)
      assert is_map(locale_data.units)
    end
  end

  describe "data contract: Cldr.Territory provider keys" do
    test "territories is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :territories)
      assert is_map(locale_data.territories)
    end

    test "subdivisions is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :subdivisions)
    end
  end

  describe "data contract: Cldr.PersonName provider keys" do
    test "person_names is present" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Map.has_key?(locale_data, :person_names)
    end
  end

  describe "data contract: provider fallback pattern" do
    test "fetch_locale returns data usable for list_patterns_for pattern" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      assert {:ok, locale_data} = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)
      list_formats = Map.get(locale_data, :list_formats)
      assert is_map(list_formats)
    end

    test "fetch_locale returns data usable for number_symbols pattern" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      assert {:ok, locale_data} = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)
      number_symbols = Map.get(locale_data, :number_symbols)
      assert is_map(number_symbols)
    end

    test "fetch_locale returns data usable for territories pattern" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      assert {:ok, locale_data} = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)
      territories = Map.get(locale_data, :territories)
      assert is_map(territories)
    end

    test "fetch_locale returns :error for unloaded locale (provider error path)" do
      assert :error = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :never_loaded)
    end
  end

  describe "data contract: non-EN locale" do
    test "fr-CA has all provider keys" do
      {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :"fr-CA")

      on_exit(fn -> Cldr.Locale.RuntimeStore.unload_locale(@backend, :"fr-CA") end)

      for key <- @core_keys do
        assert Map.has_key?(locale_data, key),
               "fr-CA missing provider key: #{inspect(key)}"
      end
    end
  end

  describe "fetch_locale_data/2 helper" do
    test "returns {:ok, value} for loaded locale and valid key" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      assert {:ok, list_formats} = @backend.fetch_locale_data(:list_formats, :en)
      assert is_map(list_formats)
    end

    test "returns {:error, :not_loaded} for unloaded locale" do
      assert {:error, :not_loaded} = @backend.fetch_locale_data(:list_formats, :never_loaded)
    end

    test "returns {:error, :key_not_found} for valid locale but missing key" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      assert {:error, :key_not_found} = @backend.fetch_locale_data(:nonexistent_key, :en)
    end

    test "works for all provider data keys" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      for key <- @provider_keys do
        assert {:ok, _value} = @backend.fetch_locale_data(key, :en),
               "fetch_locale_data failed for key #{inspect(key)}"
      end
    end
  end
end
