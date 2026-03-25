# Dynamic Runtime Locale Loading — Implementation Plan

## Context

Currently, ex_cldr bakes all configured locale data into compiled function clauses at compile time. This produces excellent runtime performance but has two problems:

1. Compile time scales linearly with locale count (`locales: :all` takes minutes)
2. Locales must be known at compile time — no runtime flexibility

This plan introduces a tiered runtime locale store that loads locale data on first request, promotes it to `:persistent_term` in the background, and integrates with the existing compiled function clause dispatch transparently.

## Design

### Architecture

```
                    ┌─────────────────────────┐
                    │   validate_locale(:en)   │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │  Compiled function clause │ ← existing fast path (5ns)
                    │  (do_validate_locale/1)   │
                    └────────────┬────────────┘
                                 │ no clause match
                    ┌────────────▼────────────┐
                    │  :persistent_term.get/1   │ ← promoted locales (20ns)
                    └────────────┬────────────┘
                                 │ miss
                    ┌────────────▼────────────┐
                    │  ETS lookup              │ ← loading/staging (50ns)
                    │  (read_concurrency)       │
                    └────────────┬────────────┘
                                 │ miss
                    ┌────────────▼────────────┐
                    │  Load JSON + decode      │ ← first request pays ~10-50ms
                    │  Insert into ETS          │
                    │  Queue migration          │
                    └─────────────────────────┘
```

### Modules

| Module | Responsibility |
|--------|---------------|
| `Cldr.Locale.RuntimeStore` | ETS table owner, load logic, migration coordinator |
| `Cldr.Backend` (modified) | Extended fallback clauses for dynamic locale dispatch |

### Data Flow

1. **Read path**: `persistent_term` → ETS → load from disk
2. **Load path**: JSON file → decode → transform → insert ETS → return
3. **Promote path**: ETS → `:persistent_term.put/2` → delete from ETS (background)

### Concurrency

- First load uses `:ets.insert_new/2` as a mutex — winner loads, losers poll
- Migration is serialized through a single background process to batch GC sweeps
- ETS table is `:public` with `read_concurrency: true` — no reader contention

### Memory

- ETS stores terms off-heap (shared, no per-process copies)
- After promotion to `:persistent_term`, ETS entry is deleted
- Each loaded locale: ~200-800KB raw data (500KB JSON → decoded map)
- Final state (`:persistent_term` only): same memory, faster reads, no ETS overhead

---

## Files to Read Before Starting

- [ ] `lib/cldr.ex` — main module, public API, `put_locale`/`get_locale`
- [ ] `lib/cldr/backend/compiler.ex` — `@before_compile` hook, code generation
- [ ] `lib/cldr/backend/cldr_backend.ex` — generated functions, `do_validate_locale/1`, `quote_marks_for/1`, `ellipsis_chars_for/1`, `lenient_parse_map/2`
- [ ] `lib/cldr/backend/locale.ex` — `script_direction_from_locale/1` generation
- [ ] `lib/cldr/locale/loader.ex` — JSON loading, decoding, transformation
- [ ] `lib/cldr/locale/cache.ex` — existing compile-time ETS cache (reference for patterns)
- [ ] `lib/cldr/config/config.ex` — `locale_path/2`, config struct
- [ ] `lib/cldr/locale.ex` — `canonical_language_tag/3`, locale resolution
- [ ] `lib/cldr/config/dependents.ex` — provider dispatch mechanism
- [ ] `mix.exs` — deps, project config
- [ ] `test/` directory — existing test patterns, test helpers

---

## Phase 1: `Cldr.Locale.RuntimeStore` Core

### Goal

Build the tiered cache module in isolation with no integration into the backend. Pure unit tests.

### Steps

- [x] Create `lib/cldr/locale/runtime_store.ex` with module skeleton
- [x] Implement ETS table lifecycle:
  - [x] `init/1` — create named ETS table (`:set`, `:public`, `read_concurrency: true`)
  - [x] Table name: `:cldr_runtime_locales`
  - [x] GenServer started via `Cldr.Locale.RuntimeStore.ensure_started/0`
- [x] Implement read path:
  - [x] `fetch_locale(backend, locale_name)` — check `:persistent_term`, then ETS
  - [x] Returns `{:ok, locale_data}` or `:error`
  - [x] Key format: `{backend, locale_name}` (atom)
- [x] Implement load path:
  - [x] `load_locale(backend, locale_name)` — full load pipeline
  - [x] Read JSON via existing `Cldr.Locale.Loader.read_locale_file!/1`
  - [x] Decode + transform (reuse Loader transformation pipeline)
  - [x] Insert into ETS via `:ets.insert_new/2` (race-safe)
  - [x] Loser processes poll ETS until data appears (with timeout)
  - [x] Queue migration to background process
- [x] Implement migration path:
  - [x] Background GenServer receives `:migrate` messages
  - [x] `send_after` with configurable delay (default 0ms — batch immediately)
  - [x] Drains pending queue, reads from ETS, calls `:persistent_term.put/2`, deletes from ETS
  - [x] All pending locales promoted in a single GC sweep
- [x] Implement `unload_locale/2`:
  - [x] `:persistent_term.erase/1` + `:ets.delete/2`
  - [x] Returns `:ok` or `{:error, :not_found}`

### Acceptance Criteria

- [x] `fetch_locale/2` returns `:error` for never-loaded locales
- [x] `load_locale/2` returns `{:ok, data}` with correct locale structure
- [x] `load_locale/2` is safe under concurrent calls (only one process loads)
- [x] After migration, `fetch_locale/2` hits `:persistent_term` (no ETS)
- [x] `unload_locale/2` removes from both `:persistent_term` and ETS
- [x] `known_loaded_locales/1` returns list of loaded locale atoms for a backend
- [x] `loaded?/2` returns boolean without loading

### Tests

- [x] `test/cldr/locale/runtime_store_test.exs`
  - [x] `fetch_locale/2` returns `:error` for unloaded locale
  - [x] `load_locale/2` loads locale and returns correct data shape
  - [x] `load_locale/2` twice is idempotent (no double load)
  - [x] Concurrent `load_locale/2` calls — only one loads, all get result
  - [x] After migration, `fetch_locale/2` returns data without ETS hit (verify via `:persistent_term.get/1`)
  - [x] `unload_locale/2` removes locale from all stores
  - [x] `known_loaded_locales/1` tracks loaded locales per backend
  - [x] `loaded?/2` returns correct boolean
  - [x] Loading non-existent locale file returns `{:error, :not_found}`
  - [x] Migration batches multiple locales into single operation

### Quality Gate

```
mix test test/cldr/locale/runtime_store_test.exs --trace
```

All tests pass. No warnings. No integration with backend yet.

---

## Phase 2: Backend Integration — Locale Validation

### Goal

Extend `Cldr.Backend` generated code so that `validate_locale/1` works for dynamically loaded locales.

### Steps

- [x] Modify `lib/cldr/backend/cldr_backend.ex`:
  - [x] Add a `do_validate_locale/1` fallback that checks runtime store before full parsing
  - [x] Insert check before the existing fallback at line 833
  - [x] Logic: if locale is in `:persistent_term` or ETS, construct `LanguageTag` from stored data and return `{:ok, tag}`
  - [x] If not in runtime store, fall through to existing `Cldr.Locale.new/2` path
- [x] Add `known_locale_name?/1` extension:
  - [x] Check compiled names first (existing)
  - [x] Fall back to `RuntimeStore.loaded?/2` (via extended `known_locale_names/0`)
- [x] Add `known_locale_names/0` extension:
  - [x] Merge compiled names with runtime-loaded names

### Acceptance Criteria

- [x] `validate_locale(:en)` still returns instantly (compiled path, no regression)
- [x] `load_locale(backend, "fr-CA")` then `validate_locale(:"fr-CA")` returns `{:ok, tag}`
- [x] `known_locale_name?(:"fr-CA")` returns `true` after loading
- [x] `known_locale_names()` includes dynamically loaded locales
- [x] Unloaded dynamic locale falls through to existing `Cldr.Locale.new/2` behavior (no crash)

### Tests

- [x] Add integration tests in `test/cldr/locale/runtime_store_integration_test.exs`
  - [x] Load locale, validate it, check LanguageTag fields
  - [x] Validate compiled locale — no regression
  - [x] Validate unknown/unloaded locale — existing behavior preserved
  - [x] `known_locale_names/0` includes dynamic locales

### Quality Gate

```
mix test test/cldr/locale/runtime_store_integration_test.exs --trace  # 7/7 pass
mix test --trace  # 13043/13043 pass, no regressions
```

---

## Phase 3: Backend Integration — Locale Data Accessors

### Goal

Extend the generated data accessor functions (`quote_marks_for/1`, `ellipsis_chars_for/1`, `lenient_parse_map/2`, `script_direction_from_locale/1`) to support dynamically loaded locales.

### Steps

- [x] Modify `lib/cldr/backend/cldr_backend.ex`:
  - [x] Add fallback `quote_marks_for/1` clause that reads delimiters from runtime store
  - [x] Add fallback `ellipsis_chars_for/1` clause that reads ellipsis from runtime store
  - [x] Add fallback `lenient_parse_map/2` clause that reads from runtime store
- [x] Modify `lib/cldr/backend/locale.ex`:
  - [x] Add fallback `script_direction_from_locale/1` clause that reads layout from runtime store
- [x] For each fallback: apply the same transformations as compile-time (regex compilation for lenient_parse, etc.)

### Acceptance Criteria

- [x] `quote("hello", locale: :en)` works (compiled path, no regression)
- [x] After `load_locale(backend, "fr-CA")`, `quote("hello", locale: :"fr-CA")` returns quotation marks
- [x] After `load_locale(backend, "fr-CA")`, `ellipsis("hello", locale: :"fr-CA")` works
- [x] After `load_locale(backend, "fr-CA")`, `script_direction_from_locale(:"fr-CA")` returns `:ltr`
- [x] `normalize_lenient_parse` works for dynamically loaded locales

### Tests

- [x] Extend `test/cldr/locale/runtime_store_integration_test.exs`
  - [x] Quote marks for dynamically loaded locale
  - [x] Ellipsis for dynamically loaded locale
  - [x] Script direction for dynamically loaded locale
  - [x] Lenient parse for dynamically loaded locale

### Quality Gate

```
mix test test/cldr/locale/runtime_store_integration_test.exs --trace  # 15/15 pass
mix test --trace  # 13051/13051 pass, no regressions
```

---

## Phase 4: Public API

### Goal

Add clean public API functions to `Cldr` and backend modules.

### Steps

- [x] Add to `lib/cldr.ex`:
  - [x] `Cldr.load_locale(backend, locale_name)` — delegates to `RuntimeStore.load_locale/2`
  - [x] `Cldr.unload_locale(backend, locale_name)` — delegates to `RuntimeStore.unload_locale/2`
  - [x] `Cldr.loaded_locale_names(backend)` — delegates to `RuntimeStore.known_loaded_locales/1`
  - [x] `Cldr.locale_loaded?(backend, locale_name)` — delegates to `RuntimeStore.loaded?/2`
- [x] Add to generated backend module (via `lib/cldr/backend/cldr_backend.ex`):
  - [x] `Backend.load_locale(locale_name)` — shorthand
  - [x] `Backend.unload_locale(locale_name)` — shorthand
  - [x] `Backend.loaded_locale_names()` — shorthand
  - [x] `Backend.locale_loaded?(locale_name)` — shorthand
- [x] Add typespecs and `@doc` for all public functions
- [ ] Document in `@moduledoc` section of `Cldr`

### Acceptance Criteria

- [x] `MyApp.Cldr.load_locale("fr-CA")` returns `:ok`
- [x] `MyApp.Cldr.locale_loaded?(:"fr-CA")` returns `true`
- [x] `MyApp.Cldr.loaded_locale_names()` includes `:"fr-CA"`
- [x] `MyApp.Cldr.unload_locale(:"fr-CA")` returns `:ok`
- [x] `MyApp.Cldr.locale_loaded?(:"fr-CA")` returns `false` after unload
- [x] All functions have typespecs
- [x] All functions have `@doc` with examples

### Tests

- [x] Add tests in `test/cldr/locale/runtime_store_api_test.exs`
  - [x] Happy path for all 4 API functions
  - [x] Error cases (invalid locale, already loaded, not loaded)
  - [x] Idempotent load/unload

### Quality Gate

```
mix test test/cldr/locale/runtime_store_api_test.exs --trace  # 14/14 pass
mix test --trace  # 13065/13065 pass, 0 failures
```

---

## Phase 5: Provider Integration

### Goal

Ensure that provider modules (Cldr.Number, Cldr.DateTime, etc.) can consume dynamically loaded locale data.

### Investigation Findings

**Every provider uses compiled function clauses per locale.** None of them have runtime data loading fallbacks. The pattern is universal:

1. Provider receives a locale name or `LanguageTag`
2. Extracts `cldr_locale_name` (an atom like `:en`, `:fr-CA`)
3. Calls a compiled function that pattern-matches on that atom
4. If no clause matches → `FunctionClauseError`

| Provider | Compiled functions per locale | Data keys needed | Fallback? |
|----------|------------------------------|------------------|-----------|
| Cldr.Number | ~15 (Format, Symbol, Transliterate, RBNF, via sub-backends) | `:number_formats`, `:number_symbols`, `:number_systems`, `:minimum_grouping_digits`, `:rbnf`, `:currencies` | `FunctionClauseError` |
| Cldr.DateTime | ~10 per locale × per calendar type | `:dates`, `:date_fields`, `:territories` | Returns error tuple, then `FunctionClauseError` |
| Cldr.Unit | ~5 (units_for per style, grammatical_features, gender) | `:units`, `:grammatical_features`, `:grammatical_gender` | Partial (some clauses) |
| Cldr.List | 2 (list_patterns_for, list_formats_for) | `:list_formats` | Validates then `FunctionClauseError` |
| Cldr.Territory | 8 (territories, subdivisions, inverted, from_code) | `:territories`, `:subdivisions` | Validates then `FunctionClauseError` |
| Cldr.Calendar | Inferred from DateTime — per locale per calendar | `:dates` → `:calendars` | Error tuple |
| Cldr.PersonName | 4 (formats_for, locale_order, space_replacement) | `:person_names` | Error string |

### Strategy: Catch-All Fallback Clauses

For each compiled function in each provider that currently only matches specific locale atoms, add a single catch-all clause that checks the runtime store:

```elixir
# Existing compiled clauses (no change):
def list_patterns_for(:en), do: %{...}
def list_patterns_for(:fr), do: %{...}

# New catch-all clause:
def list_patterns_for(locale_name) when is_atom(locale_name) do
  case Cldr.Locale.RuntimeStore.fetch_locale(backend, locale_name) do
    {:ok, locale_data} ->
      locale_data
      |> Map.get(:list_formats)
      |> # same transformation as compile time
    :error ->
      {:error, Cldr.Locale.locale_error(locale_name)}
  end
end
```

### Scope

This requires changes in **7 external packages** (ex_cldr_numbers, ex_cldr_dates_times, ex_cldr_units, ex_cldr_lists, ex_cldr_territories, ex_cldr_calendars, ex_cldr_person_names). Each change is small (1-3 lines per function) but there are ~50 functions total across all providers.

### Dependency Chain

```
ex_cldr (core)
  ├── Cldr.Locale.RuntimeStore  ← Phase 1-4 (this plan)
  ├── ex_cldr_numbers           ← add fallback clauses (separate PR)
  ├── ex_cldr_dates_times       ← add fallback clauses (separate PR)
  ├── ex_cldr_units             ← add fallback clauses (separate PR)
  ├── ex_cldr_lists             ← add fallback clauses (separate PR)
  ├── ex_cldr_territories       ← add fallback clauses (separate PR)
  ├── ex_cldr_calendars         ← add fallback cases (separate PR)
  └── ex_cldr_person_names      ← add fallback clauses (separate PR)
```

### Recommended Release Strategy

1. Release `ex_cldr` with `RuntimeStore` first (Phase 1-4)
2. Release provider updates that add fallback clauses, with a minimum dependency on the new `ex_cldr` version
3. Users upgrade all packages together

### Steps

- [x] Data contract verification: write tests proving RuntimeStore returns Loader-identical data
- [x] Fix transformation pipeline ordering bug (integerize_keys must run before atomize_keys(level: 1..1))
- [x] Add `Backend.fetch_locale_data/2` helper for provider catch-all clauses
- [x] Add catch-all clauses to cldr_lists, cldr_numbers, cldr_territories, cldr_units
- [x] Verify Architecture B providers (cldr_dates_times, cldr_calendars, cldr_person_names) already have catch-alls — no changes needed
- [ ] Add tests in each provider's test suite
- [ ] Update each provider's `mix.exs` to require the new `ex_cldr` version

### Per-Provider Change List

**Cldr.Number** (cldr_numbers):
- [x] `Cldr.Number.Format.Backend` — `all_formats_for/1`, `minimum_grouping_digits_for/1`, `default_grouping_for/1` catch-alls
- [x] `Cldr.Number.Symbol.Backend` — `number_symbols_for/1` catch-all
- [~] `Cldr.Number.Transliterate.Backend` — transliteration map catch-all (needs investigation)
- [~] `Cldr.Number.RBNF.Backend` — RBNF rules catch-all (uses separate processor, needs investigation)

**Cldr.DateTime** (cldr_dates_times):
- [x] Architecture B — already has catch-alls returning error tuples, no changes needed
- [ ] `Cldr.DateTime.Relative.Backend` — relative time patterns catch-all
- [ ] `Cldr.Date.Backend`, `Cldr.Time.Backend`, `Cldr.DateTime.Backend` — delegate catch-alls

**Cldr.Unit** (cldr_units):
- [x] `units_for/2` catch-all
- [x] `grammatical_features/1` catch-all (already returns error tuple)
- [x] `grammatical_gender/1` catch-all (already returns error tuple)

**Cldr.List** (cldr_lists):
- [x] `list_patterns_for/1` catch-all
- [x] `list_formats_for/1` catch-all

**Cldr.Territory** (cldr_territories):
- [x] `known_territories/1` catch-all
- [x] `known_subdivisions/1` catch-all
- [x] `available_territories/1` catch-all
- [x] `available_subdivisions/1` catch-all
- [x] `inverted_territories/1` catch-all
- [x] `inverted_subdivisions/1` catch-all
- [x] `from_territory_code/3` catch-all
- [x] `from_subdivision_code/3` catch-all

**Cldr.Calendar** (cldr_calendars):
- [x] Architecture B — already has catch-alls, no changes needed

**Cldr.PersonName** (cldr_person_names):
- [x] Architecture B — already has catch-alls, no changes needed

### Acceptance Criteria

- [ ] Number formatting works with dynamically loaded locales (needs provider tests)
- [ ] Date/time formatting works with dynamically loaded locales (Architecture B, should work)
- [ ] Unit formatting works with dynamically loaded locales (needs provider tests)
- [x] List formatting works with dynamically loaded locales
- [x] Territory display works with dynamically loaded locales
- [ ] Person name formatting works with dynamically loaded locales (Architecture B, should work)
- [x] No crashes when provider functions are called with dynamic locale
- [x] Fallback clauses delegate to `Backend.fetch_locale_data/2`

### Tests

- [x] Data contract tests in `test/cldr/locale/runtime_store_contract_test.exs` (27 tests)
- [ ] Provider-specific integration tests in each provider's test suite
- [ ] Each test: load locale → call provider function → assert correct output

### Quality Gate

```
# In-repo (done):
mix test test/cldr/locale/runtime_store_contract_test.exs --trace  # 27/27 pass
mix test --trace  # 13092/13092 pass, 0 failures

# In each provider repo (pending):
mix test --trace
```

---

## Phase 6: Edge Cases, Robustness, Performance

### Goal

Harden the implementation against edge cases and verify performance characteristics.

### Steps

- [ ] Error handling:
  - [ ] Locale JSON file not found → `{:error, :not_found}`
  - [ ] JSON decode failure → `{:error, {:decode_error, reason}}`
  - [ ] ETS table not initialized → auto-initialize or clear error
  - [ ] GenServer crash → ETS table survives (named table), GenServer restarts
- [ ] Race conditions:
  - [ ] `load_locale` + `unload_locale` concurrent → consistent state
  - [ ] `load_locale` during migration → ETS entry not deleted prematurely
  - [ ] Multiple backends → isolated data (keyed by `{backend, locale_name}`)
- [ ] Configuration:
  - [ ] `:runtime_locale_cache` option in backend config (default: `true`)
  - [ ] `:migration_delay` option (default: `0` — batch immediately)
  - [ ] Option to disable `:persistent_term` promotion (ETS only)
- [ ] Performance benchmarks:
  - [ ] Benchmark `validate_locale` for compiled vs dynamic locale
  - [ ] Benchmark concurrent load_locale (100 processes, same locale)
  - [ ] Benchmark migration GC impact (measure pause time)

### Acceptance Criteria

- [ ] All error paths return tagged tuples, no unhandled exceptions
- [ ] No race conditions under `:concurrent` test tag
- [ ] Configuration options work as documented
- [ ] Performance benchmarks within acceptable ranges:
  - [ ] Dynamic locale read: < 500ns
  - [ ] First load: < 100ms
  - [ ] Migration GC: < 500ms for 10 locales

### Tests

- [ ] `test/cldr/locale/runtime_store_edge_cases_test.exs`
  - [ ] Missing locale file
  - [ ] Corrupt JSON
  - [ ] Concurrent load + unload
  - [ ] Multiple backends isolation
  - [ ] GenServer restart preserves ETS data
- [ ] `test/cldr/locale/runtime_store_config_test.exs`
  - [ ] Config options are respected

### Quality Gate

```
mix test --trace
mix format --check-formatted
mix credo --strict  # if credo is configured
mix dialyzer        # if dialyzer is configured
```

---

## Phase 7: Documentation & Polish

### Goal

Production-ready documentation and final cleanup.

### Steps

- [ ] Module documentation:
  - [ ] `Cldr.Locale.RuntimeStore` — `@moduledoc` with architecture diagram
  - [ ] All public functions have `@doc` with examples and `@spec`
- [ ] Guide documentation:
  - [ ] Add section to `README.md` or existing docs about dynamic locale loading
  - [ ] Migration guide: how to switch from `locales: :all` to runtime loading
  - [ ] Performance characteristics documented
- [ ] Code cleanup:
  - [ ] No debug logging in production paths
  - [ ] Consistent error tuples across all functions
  - [ ] `@impl true` on GenServer callbacks
  - [ ] `@moduledoc false` on internal modules

### Acceptance Criteria

- [ ] All public functions have `@doc` with at least one example
- [ ] All public functions have `@spec`
- [ ] README or guide covers dynamic locale loading
- [ ] No `IO.inspect`, `dbg`, or debug artifacts in code
- [ ] `mix format` passes
- [ ] Full test suite passes

### Quality Gate

```
mix format --check-formatted
mix test --trace
mix docs  # if ex_doc configured
```

---

## Test Strategy

### TDD Protocol

For every step above:

1. **Red**: Write the test first. Run it. Confirm it fails for the right reason.
2. **Green**: Write the minimum code to make the test pass.
3. **Refactor**: Clean up while keeping tests green.

### Test Organization

```
test/cldr/locale/
  runtime_store_test.exs              # Phase 1: unit tests
  runtime_store_integration_test.exs  # Phase 2-3: backend integration
  runtime_store_api_test.exs          # Phase 4: public API
  runtime_store_edge_cases_test.exs   # Phase 6: edge cases
  runtime_store_config_test.exs       # Phase 6: configuration
```

### Test Helpers

- Use existing `TestBackend.Cldr` from `test/support/` if available
- Create fixture locale JSON files in `test/fixtures/locales/` for isolated tests
- Use `setup` blocks to clean `:persistent_term` and ETS between tests

### Concurrency Tests

Tag with `@tag :concurrent`. Use `Task.async_stream` or `Task.async` + `Task.yield_many` to simulate concurrent access.

---

## Data Format Contract: RuntimeStore ↔ Providers

### Requirement

The `RuntimeStore.fetch_locale(backend, locale_name)` function must return the **same data shape** as `Cldr.Locale.Loader.get_locale(locale_name, config)`. This is critical because:

1. The compile-time path: `Loader.get_locale/2` → decode JSON → transform → embed into function clauses
2. The runtime path: `RuntimeStore.fetch_locale/2` → return stored map → provider extracts same keys

Both paths must produce identical data structures. The simplest way to guarantee this: **use `Loader.do_get_locale/3` as the load pipeline inside RuntimeStore**.

### Data Shape

`RuntimeStore.fetch_locale/2` returns `{:ok, locale_map}` where `locale_map` is the same map that `Loader.get_locale/2` returns — a map with keys like:

```elixir
%{
  name: :en,
  delimiters: %{quotation_start: "...", quotation_end: "..."},
  ellipsis: %{final: "...", initial: "...", medial: "..."},
  lenient_parse: %{...},
  layout: %{character_order: :ltr},
  number_formats: %{...},
  number_symbols: %{...},
  dates: %{calendars: %{gregorian: %{...}}, time_zone_names: %{...}},
  list_formats: %{...},
  units: %{...},
  territories: %{...},
  person_names: %{...},
  # ... etc
}
```

### Transformation at Load Time

All JSON decoding and key transformations happen **once at load time**, not on every access. This includes:
- Atomizing keys
- Integerizing keys (number_formats, list_formats, date_fields)
- Structuring date formats
- Regex compilation for lenient_parse (done once, stored as compiled regex)

This matches the compile-time behavior where transformations happen once and the result is embedded as a literal.

### Provider Fallback Pattern

```elixir
def list_patterns_for(locale_name) when is_atom(locale_name) do
  case Cldr.Locale.RuntimeStore.fetch_locale(__cldr__(:backend), locale_name) do
    {:ok, locale_data} ->
      Map.get(locale_data, :list_formats)
    :error ->
      {:error, Cldr.Locale.locale_error(locale_name)}
  end
end
```

Each provider extracts exactly the keys it needs, same as it does at compile time.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Provider modules require changes in 7 external packages | **Confirmed** | High | Catch-all clauses are 1-3 lines each; coordinate releases |
| `:persistent_term` GC still causes issues in production | Low | Medium | Make promotion configurable, allow ETS-only mode |
| Race condition in load + migrate | Medium | Medium | Careful state machine, property-based tests |
| Memory leak from orphaned ETS entries | Low | Low | Cleanup on unload, periodic audit function |
| Provider transformation diverges from compile-time path | Medium | Medium | Use `Loader.do_get_locale/3` as single load pipeline |

---

## Open Questions

- [x] Should `RuntimeStore` be per-backend or global? → **Global, keyed by `{backend, locale_name}`**
- [ ] Should migration be opt-in or opt-out?
- [ ] Should there be a bulk `load_locales(backend, locale_names)` API?
- [ ] How should this interact with `Cldr.Locale.Cache` (the compile-time cache)?
- [ ] Provider PR sequencing: all at once or incremental?
- [ ] Minimum version bump strategy for provider packages?
