defmodule Cldr.Locale.RuntimeStoreIntegrationTest do
  use ExUnit.Case, async: false

  # NoFallback.Cldr only has "en" and "es-US" compiled,
  # so RuntimeStore fallback is testable for other locales.
  @backend NoFallback.Cldr
  @dynamic_locale :"fr-CA"

  setup do
    on_exit(fn ->
      Cldr.Locale.RuntimeStore.unload_locale(@backend, @dynamic_locale)
    end)

    :ok
  end

  describe "validate_locale with RuntimeStore" do
    test "compiled locale still works (no regression)" do
      assert {:ok, tag} = @backend.validate_locale(:en)
      assert tag.cldr_locale_name == :en
      assert tag.backend == @backend
    end

    test "dynamically loaded locale validates successfully" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      assert {:ok, tag} = @backend.validate_locale(@dynamic_locale)
      assert tag.cldr_locale_name == @dynamic_locale
      assert tag.backend == @backend
    end

    test "unloaded dynamic locale falls through to existing behavior" do
      # fr-CA is not compiled and not loaded — falls through to
      # Cldr.Locale.new/2 which can't match since fr is not configured
      assert {:error, _} = @backend.validate_locale(@dynamic_locale)
    end
  end

  describe "known_locale_name? with RuntimeStore" do
    test "compiled locale returns true" do
      assert @backend.known_locale_name?(:en)
    end

    test "returns true after loading dynamic locale" do
      refute @backend.known_locale_name?(@dynamic_locale)

      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      assert @backend.known_locale_name?(@dynamic_locale)
    end
  end

  describe "known_locale_names with RuntimeStore" do
    test "includes compiled locales" do
      names = @backend.known_locale_names()
      assert :en in names
    end

    test "includes dynamically loaded locales" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      names = @backend.known_locale_names()
      assert @dynamic_locale in names
    end
  end

  describe "quote_marks_for with RuntimeStore" do
    test "compiled locale quote still works (no regression)" do
      result = @backend.quote("hello", locale: :en)
      assert is_binary(result)
      assert String.contains?(result, "hello")
    end

    test "dynamically loaded locale quote works" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      result = @backend.quote("hello", locale: @dynamic_locale)
      assert is_binary(result)
      assert String.contains?(result, "hello")
    end
  end

  describe "ellipsis_chars_for with RuntimeStore" do
    test "compiled locale ellipsis still works (no regression)" do
      result = @backend.ellipsis("hello", locale: :en)
      assert is_binary(result)
      assert String.contains?(result, "…")
    end

    test "dynamically loaded locale ellipsis works" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      result = @backend.ellipsis("hello", locale: @dynamic_locale)
      assert is_binary(result)
      assert String.contains?(result, "…")
    end
  end

  describe "script_direction_from_locale with RuntimeStore" do
    test "compiled locale script direction still works (no regression)" do
      assert @backend.Locale.script_direction_from_locale(:en) == :ltr
    end

    test "dynamically loaded locale returns correct script direction" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      assert @backend.Locale.script_direction_from_locale(@dynamic_locale) == :ltr
    end
  end

  describe "lenient_parse_map with RuntimeStore" do
    test "compiled locale normalize_lenient_parse still works (no regression)" do
      result = @backend.normalize_lenient_parse("1,234", :number, :en)
      assert is_binary(result)
    end

    test "dynamically loaded locale normalize_lenient_parse works" do
      {:ok, _} = Cldr.Locale.RuntimeStore.load_locale(@backend, @dynamic_locale)

      result = @backend.normalize_lenient_parse("1,234", :number, @dynamic_locale)
      assert is_binary(result)
    end
  end
end
