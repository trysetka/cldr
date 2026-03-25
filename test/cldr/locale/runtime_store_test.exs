defmodule Cldr.Locale.RuntimeStoreTest do
  use ExUnit.Case, async: false

  @backend TestBackend.Cldr

  setup do
    # Clean up any test locales from both stores
    on_exit(fn ->
      Cldr.Locale.RuntimeStore.unload_locale(@backend, :en)
      Cldr.Locale.RuntimeStore.unload_locale(@backend, :"fr-CA")
    end)

    :ok
  end

  describe "fetch_locale/2" do
    test "returns :error for unloaded locale" do
      assert :error = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :nonexistent_locale)
    end
  end

  describe "load_locale/2" do
    test "loads a locale and returns correct data shape" do
      assert {:ok, locale_data} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert is_map(locale_data)
      assert Map.has_key?(locale_data, :delimiters)
      assert Map.has_key?(locale_data, :ellipsis)
      assert Map.has_key?(locale_data, :name)
    end

    test "after loading, fetch_locale returns the data" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert {:ok, locale_data} = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)
      assert is_map(locale_data)
    end

    test "load_locale is idempotent" do
      {:ok, data1} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      {:ok, data2} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert data1 == data2
    end

    test "loading a nonexistent locale returns error tuple" do
      assert {:error, _reason} =
               Cldr.Locale.RuntimeStore.load_locale(@backend, :nonexistent_locale_xyz)
    end
  end

  describe "unload_locale/2" do
    test "removes loaded locale from all stores" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert {:ok, _} = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)

      assert :ok = Cldr.Locale.RuntimeStore.unload_locale(@backend, :en)
      assert :error = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)
    end

    test "returns error for unloading a never-loaded locale" do
      assert {:error, :not_found} =
               Cldr.Locale.RuntimeStore.unload_locale(@backend, :never_loaded_xyz)
    end
  end

  describe "loaded?/2" do
    test "returns false for unloaded locale" do
      refute Cldr.Locale.RuntimeStore.loaded?(@backend, :en)
    end

    test "returns true for loaded locale" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      assert Cldr.Locale.RuntimeStore.loaded?(@backend, :en)
    end

    test "returns false after unload" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      :ok = Cldr.Locale.RuntimeStore.unload_locale(@backend, :en)
      refute Cldr.Locale.RuntimeStore.loaded?(@backend, :en)
    end
  end

  describe "known_loaded_locales/1" do
    test "returns empty list when nothing loaded" do
      assert [] = Cldr.Locale.RuntimeStore.known_loaded_locales(@backend)
    end

    test "returns list of loaded locale atoms for a backend" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :"fr-CA")

      loaded = Cldr.Locale.RuntimeStore.known_loaded_locales(@backend)
      assert :en in loaded
      assert :"fr-CA" in loaded
    end
  end

  describe "migration to persistent_term" do
    test "after migration, fetch_locale hits persistent_term" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      # Give migration time to complete
      Process.sleep(100)

      # Verify data is available via persistent_term
      key = {Cldr.Locale.RuntimeStore, @backend, :en}
      assert term_data = :persistent_term.get(key)
      assert is_map(term_data)
      assert Map.has_key?(term_data, :delimiters)
    end

    test "after migration, ETS entry is cleaned up" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, :en)

      # Give migration time to complete
      Process.sleep(100)

      # ETS should no longer have the entry
      ets_key = {@backend, :en}
      table = :cldr_runtime_locales
      assert :ets.lookup(table, ets_key) == []
    end
  end

  describe "concurrent load_locale/2" do
    @tag :concurrent
    test "only one process loads, all get result" do
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Cldr.Locale.RuntimeStore.load_locale(@backend, :en)
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # All tasks should get {:ok, _}
      for result <- results do
        assert {:ok, data} = result
        assert is_map(data)
      end

      # Only one persistent_term entry should exist
      assert {:ok, _} = Cldr.Locale.RuntimeStore.fetch_locale(@backend, :en)
    end
  end
end
