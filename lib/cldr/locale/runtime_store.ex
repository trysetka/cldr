defmodule Cldr.Locale.RuntimeStore do
  @moduledoc """
  Manages runtime locale data through a tiered cache.

  Locales are loaded on first request, staged in an ETS table,
  and promoted to `:persistent_term` in the background.

  ## Architecture

  ```
  fetch_locale/2
       |
       v
  :persistent_term.get  (20ns, promoted locales)
       |
       v
  ETS lookup            (50ns, loading/staging)
       |
       v
  Load JSON + decode    (10-50ms, first request)
  ```

  """

  use GenServer

  require Logger

  @table_name :cldr_runtime_locales
  @index_table_name :cldr_runtime_locale_index
  @gen_server_name :cldr_runtime_store
  @persistent_term_prefix Cldr.Locale.RuntimeStore

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Ensures the RuntimeStore GenServer and ETS table are started.
  """
  def ensure_started do
    case Process.whereis(@gen_server_name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        GenServer.start(__MODULE__, [], name: @gen_server_name)
    end
  end

  @doc """
  Fetches locale data for a backend and locale name.

  Checks `:persistent_term` first, then ETS.
  Returns `{:ok, locale_data}` or `:error`.
  """
  @spec fetch_locale(module(), atom()) :: {:ok, map()} | :error
  def fetch_locale(backend, locale_name) when is_atom(backend) and is_atom(locale_name) do
    key = persistent_term_key(backend, locale_name)

    case :persistent_term.get(key, :__not_found__) do
      :__not_found__ ->
        fetch_from_ets(backend, locale_name)

      data ->
        {:ok, data}
    end
  end

  @doc """
  Loads a locale by reading the JSON file, decoding, and caching.

  Only one process will perform the actual load for a given locale;
  concurrent callers will wait for the result.
  """
  @spec load_locale(module(), atom()) :: {:ok, map()} | {:error, term()}
  def load_locale(backend, locale_name) when is_atom(backend) and is_atom(locale_name) do
    ensure_started()

    case fetch_locale(backend, locale_name) do
      {:ok, data} ->
        {:ok, data}

      :error ->
        do_load_locale(backend, locale_name)
    end
  end

  @doc """
  Unloads a locale from both `:persistent_term` and ETS.
  Returns `:ok` or `{:error, :not_found}`.
  """
  @spec unload_locale(module(), atom()) :: :ok | {:error, :not_found}
  def unload_locale(backend, locale_name) when is_atom(backend) and is_atom(locale_name) do
    pt_key = persistent_term_key(backend, locale_name)
    ets_key = {backend, locale_name}

    pt_existed = :persistent_term.get(pt_key, :__not_found__) != :__not_found__
    ets_existed = :ets.member(@table_name, ets_key)

    if pt_existed or ets_existed do
      if pt_existed, do: :persistent_term.erase(pt_key)
      if ets_existed, do: :ets.delete(@table_name, ets_key)
      :ets.delete(@index_table_name, {backend, locale_name})
      :ok
    else
      {:error, :not_found}
    end
  rescue
    ArgumentError ->
      {:error, :not_found}
  end

  @doc """
  Returns true if the locale is loaded for the given backend.
  """
  @spec loaded?(module(), atom()) :: boolean()
  def loaded?(backend, locale_name) when is_atom(backend) and is_atom(locale_name) do
    key = persistent_term_key(backend, locale_name)

    case :persistent_term.get(key, :__not_found__) do
      :__not_found__ ->
        try do
          :ets.member(@table_name, {backend, locale_name})
        rescue
          ArgumentError -> false
        end

      _data ->
        true
    end
  end

  @doc """
  Returns a list of locale atoms that are loaded for the given backend.
  """
  @spec known_loaded_locales(module()) :: [atom()]
  def known_loaded_locales(backend) when is_atom(backend) do
    try do
      :ets.match_object(@index_table_name, {{backend, :_}, true})
      |> Enum.map(fn {{_backend, locale_name}, _} -> locale_name end)
    rescue
      ArgumentError -> []
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_args) do
    create_ets_table!()
    create_index_table!()
    {:ok, %{migration_queue: [], migration_timer: nil}}
  end

  @impl true
  def handle_info({:migrate, backend, locale_name}, state) do
    do_migrate(backend, locale_name)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_migrations, %{migration_queue: queue} = state) do
    for {backend, locale_name} <- Enum.uniq(queue) do
      do_migrate(backend, locale_name)
    end

    {:noreply, %{state | migration_queue: [], migration_timer: nil}}
  end

  @impl true
  def handle_info(:queue_migration, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:enqueue_migration, backend, locale_name}, _from, state) do
    new_queue = [{backend, locale_name} | state.migration_queue]

    new_timer =
      case state.migration_timer do
        nil ->
          Process.send_after(self(), :flush_migrations, 0)

        timer ->
          timer
      end

    {:reply, :ok, %{state | migration_queue: new_queue, migration_timer: new_timer}}
  end

  # ── Private ─────────────────────────────────────────────────────

  defp do_load_locale(backend, locale_name) do
    config = backend.__cldr__(:config)

    case Cldr.Config.locale_path(locale_name, config) do
      {:ok, path} ->
        load_and_insert(backend, locale_name, path)

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp load_and_insert(backend, locale_name, path) do
    ets_key = {backend, locale_name}

    # Try to claim the load slot with insert_new (atomic)
    case :ets.insert_new(@table_name, {ets_key, :__loading__}) do
      true ->
        # We won the race — perform the load
        try do
          locale_data =
            path
            |> Cldr.Locale.Loader.read_locale_file!()
            |> Cldr.Config.json_library().decode!()
            |> transform_locale_data(locale_name)

          # Replace the loading sentinel with actual data
          :ets.insert(@table_name, {ets_key, locale_data})
          :ets.insert(@index_table_name, {{backend, locale_name}, true})

          # Queue migration to persistent_term
          GenServer.call(@gen_server_name, {:enqueue_migration, backend, locale_name})

          {:ok, locale_data}
        rescue
          e ->
            # Clean up on failure
            :ets.delete(@table_name, ets_key)
            {:error, {:load_error, Exception.message(e)}}
        end

      false ->
        # Another process is loading — poll until data appears
        poll_for_locale(backend, locale_name, 5000)
    end
  end

  defp poll_for_locale(backend, locale_name, timeout) when timeout <= 0 do
    case fetch_locale(backend, locale_name) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :timeout}
    end
  end

  defp poll_for_locale(backend, locale_name, timeout) do
    ets_key = {backend, locale_name}

    case :ets.lookup(@table_name, ets_key) do
      [{^ets_key, :__loading__}] ->
        Process.sleep(10)
        poll_for_locale(backend, locale_name, timeout - 10)

      [{^ets_key, data}] ->
        {:ok, data}

      [] ->
        Process.sleep(10)
        poll_for_locale(backend, locale_name, timeout - 10)
    end
  end

  defp transform_locale_data(content, locale_name) do
    content
    |> Cldr.Map.integerize_keys(filter: "list_formats")
    |> Cldr.Map.integerize_keys(filter: "number_formats")
    |> Cldr.Map.integerize_keys(filter: "date_fields")
    |> Cldr.Map.atomize_values(filter: "number_systems")
    |> Cldr.Map.atomize_keys(
      filter: "locale_display_names",
      skip: ["language", "language_variants"]
    )
    |> Cldr.Map.atomize_keys(
      filter: "languages",
      only: [
        "default",
        "menu",
        "short",
        "long",
        "variant",
        "standard",
        "medium",
        "core",
        "extension",
        "alt"
      ]
    )
    |> Cldr.Map.atomize_keys(filter: "lenient_parse", only: ["date", "general", "number"])
    |> Cldr.Map.atomize_keys(filter: remaining_modules())
    |> Cldr.Map.atomize_values(filter: :layout)
    |> Cldr.Map.atomize_values(only: :usage)
    |> structure_date_formats()
    |> Cldr.Map.atomize_keys(level: 1..1)
    |> parse_version()
    |> Map.put(:name, locale_name)
  end

  @remaining_modules Cldr.Config.required_modules() --
                       ["locale_display_names", "languages", "lenient_parse", "dates"]

  defp remaining_modules, do: @remaining_modules

  defp parse_version(content) do
    case Map.get(content, :version) do
      nil -> content
      version -> Map.put(content, :version, Version.parse!(version))
    end
  end

  defp structure_date_formats(content) do
    dates =
      content
      |> Map.get("dates")
      |> Cldr.Map.integerize_keys(only: Cldr.Config.keys_to_integerize())
      |> Cldr.Map.deep_map(fn
        {"number_system", value} ->
          {:number_system,
           Cldr.Map.atomize_values(value) |> Cldr.Map.stringify_keys(except: :all)}

        other ->
          other
      end)
      |> Cldr.Map.atomize_keys(
        only: [
          "exemplar-city",
          "long",
          "standard",
          "generic",
          "short",
          "daylight",
          "formal",
          "generic",
          "type"
        ]
      )
      |> Cldr.Map.atomize_keys(filter: "calendars", skip: :number_system)
      |> Cldr.Map.atomize_keys(filter: "time_zone_names", level: 1..2)
      |> Cldr.Map.atomize_values(filter: :date_formats)
      |> Cldr.Map.atomize_values(filter: :time_formats)
      |> Cldr.Map.atomize_values(only: [:type])
      |> Cldr.Map.atomize_keys(level: 1..1)

    Map.put(content, :dates, dates)
  end

  defp do_migrate(backend, locale_name) do
    ets_key = {backend, locale_name}
    pt_key = persistent_term_key(backend, locale_name)

    case :ets.lookup(@table_name, ets_key) do
      [{^ets_key, data}] when data != :__loading__ ->
        :persistent_term.put(pt_key, data)
        :ets.delete(@table_name, ets_key)

      _ ->
        :ok
    end
  end

  defp fetch_from_ets(backend, locale_name) do
    ets_key = {backend, locale_name}

    try do
      case :ets.lookup(@table_name, ets_key) do
        [{^ets_key, :__loading__}] ->
          :error

        [{^ets_key, data}] ->
          {:ok, data}

        [] ->
          :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  defp persistent_term_key(backend, locale_name) do
    {@persistent_term_prefix, backend, locale_name}
  end

  defp create_ets_table! do
    case :ets.info(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:named_table, :public, {:read_concurrency, true}])

      _ ->
        :ok
    end
  end

  defp create_index_table! do
    case :ets.info(@index_table_name) do
      :undefined ->
        :ets.new(@index_table_name, [:named_table, :public, {:read_concurrency, true}])

      _ ->
        :ok
    end
  end
end
