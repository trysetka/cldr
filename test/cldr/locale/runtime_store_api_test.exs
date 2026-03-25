defmodule Cldr.Locale.RuntimeStoreApiTest do
  use ExUnit.Case, async: false

  @backend NoFallback.Cldr
  @dynamic_locale :"fr-CA"

  setup do
    on_exit(fn ->
      Cldr.Locale.RuntimeStore.unload_locale(@backend, @dynamic_locale)
    end)

    :ok
  end

  describe "Cldr.load_locale/2" do
    test "loads a locale and returns :ok" do
      assert :ok = Cldr.load_locale(@backend, @dynamic_locale)
      assert Cldr.locale_loaded?(@backend, @dynamic_locale)
    end

    test "is idempotent" do
      assert :ok = Cldr.load_locale(@backend, @dynamic_locale)
      assert :ok = Cldr.load_locale(@backend, @dynamic_locale)
    end

    test "returns error for non-existent locale" do
      assert {:error, _reason} = Cldr.load_locale(@backend, :"zz-ZZ")
    end
  end

  describe "Cldr.unload_locale/2" do
    test "unloads a loaded locale and returns :ok" do
      :ok = Cldr.load_locale(@backend, @dynamic_locale)
      assert :ok = Cldr.unload_locale(@backend, @dynamic_locale)
      refute Cldr.locale_loaded?(@backend, @dynamic_locale)
    end

    test "returns error for not-loaded locale" do
      assert {:error, :not_found} = Cldr.unload_locale(@backend, @dynamic_locale)
    end
  end

  describe "Cldr.loaded_locale_names/1" do
    test "returns empty list when no dynamic locales loaded" do
      names = Cldr.loaded_locale_names(@backend)
      assert is_list(names)
    end

    test "includes dynamically loaded locale" do
      :ok = Cldr.load_locale(@backend, @dynamic_locale)

      names = Cldr.loaded_locale_names(@backend)
      assert @dynamic_locale in names
    end
  end

  describe "Cldr.locale_loaded?/2" do
    test "returns false for never-loaded locale" do
      refute Cldr.locale_loaded?(@backend, @dynamic_locale)
    end

    test "returns true after loading" do
      :ok = Cldr.load_locale(@backend, @dynamic_locale)
      assert Cldr.locale_loaded?(@backend, @dynamic_locale)
    end

    test "returns false after unloading" do
      :ok = Cldr.load_locale(@backend, @dynamic_locale)
      :ok = Cldr.unload_locale(@backend, @dynamic_locale)
      refute Cldr.locale_loaded?(@backend, @dynamic_locale)
    end
  end

  describe "Backend shorthand functions" do
    test "Backend.load_locale/1 loads locale" do
      assert :ok = @backend.load_locale(@dynamic_locale)
      assert @backend.locale_loaded?(@dynamic_locale)
    end

    test "Backend.unload_locale/1 unloads locale" do
      :ok = @backend.load_locale(@dynamic_locale)
      assert :ok = @backend.unload_locale(@dynamic_locale)
      refute @backend.locale_loaded?(@dynamic_locale)
    end

    test "Backend.loaded_locale_names/0 lists loaded locales" do
      :ok = @backend.load_locale(@dynamic_locale)
      assert @dynamic_locale in @backend.loaded_locale_names()
    end

    test "Backend.locale_loaded?/1 checks if loaded" do
      refute @backend.locale_loaded?(@dynamic_locale)
      :ok = @backend.load_locale(@dynamic_locale)
      assert @backend.locale_loaded?(@dynamic_locale)
    end
  end
end
