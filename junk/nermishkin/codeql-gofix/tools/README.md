# CodeQL Case Tools

Utility scripts for post-processing CodeQL outputs for
`junk/nermishkin/codeql-gofix`.

## Files

- `render_callgraph_svg.py` - render a call graph SVG from an enriched CSV export
- `generate_callgraphs.sh` - batch-render all CSV files in a directory
- `generate_callgraph_csv.sh` - export enriched callgraph rows from a CodeQL database
- `generate_sarif.sh` - run `codeql database analyze` and write raw SARIF output
- `create_database.sh` - build a Go CodeQL database for a `ya make -r` target
- `ya_codeql_wrapper.sh` - internal wrapper used by `create_database.sh` during `database create`
- `generate_all_artifacts.sh` - convenience wrapper that runs SARIF generation and callgraph rendering
- `create_imported_databases.sh` - create per-program databases and import a shared unfinalized Go database
- `run_import_flow_experiment.sh` - compare data flow results before and after importing a shared Go database
- `verify_import_databases.sh` - compare full-build and import-build databases and print per-program timing
- `compare_unfinalized_import_orders.sh` - compare full, cached, and two import-order variants at unfinalized and finalized stages

## Examples

Render call graphs from CSV files:

```sh
junk/nermishkin/codeql-gofix/tools/generate_callgraphs.sh \
  /tmp/codeql_go_case_artifacts/callgraph_csv \
  junk/nermishkin/codeql-gofix/_artifacts/callgraph_svg
```

Generate SARIF from a database and query or query suite:

```sh
junk/nermishkin/codeql-gofix/tools/generate_sarif.sh \
  /path/to/codeql \
  /tmp/example1_basic-db \
  /path/to/query-or-suite.qls \
  junk/nermishkin/codeql-gofix/_artifacts/sarif/example1_basic.sarif
```

Generate SARIF and render callgraphs from an existing CSV directory:

```sh
junk/nermishkin/codeql-gofix/tools/generate_all_artifacts.sh \
  /path/to/codeql \
  /tmp/example1_basic-db \
  /path/to/query-or-suite.qls \
  /tmp/codeql_go_case_artifacts/callgraph_csv \
  junk/nermishkin/codeql-gofix/_artifacts/sarif/example1_basic.sarif \
  junk/nermishkin/codeql-gofix/_artifacts/callgraph_svg
```


Queries live in `tools/queries/` and include:

- `cli_arg_command.ql`
- `vendor_arg_flow.ql`
- `enriched_callgraph.ql`
- `import_shared_flow.ql`
- `tutorial_cases.qls`

Create a database for a tutorial case:

```sh
junk/nermishkin/codeql-gofix/tools/create_database.sh   /path/to/codeql   /tmp/example1_basic-db   junk/nermishkin/codeql-gofix/example1_basic/hello   --overwrite
```

Generate callgraph CSV from a database:

```sh
junk/nermishkin/codeql-gofix/tools/generate_callgraph_csv.sh   /path/to/codeql   /tmp/example1_basic-db   /tmp/example1_basic.csv
```

Build separate program databases that import one shared library database:

```sh
junk/nermishkin/codeql-gofix/tools/create_imported_databases.sh \
  /home/yngwie/codeql-home/codeql/codeql \
  /tmp/codeql-example8-import \
  junk/nermishkin/codeql-gofix/example8_import_shared_lib
```

Compare flow results before and after import for `example8_import_shared_lib`:

```sh
junk/nermishkin/codeql-gofix/tools/run_import_flow_experiment.sh \
  /usr/local/bin/codeql \
  /tmp/codeql-example8-flow
```

Verify database equivalence and measure speedup with a prebuilt shared database:

```sh
junk/nermishkin/codeql-gofix/tools/verify_import_databases.sh \
  /home/yngwie/codeql-home/codeql/codeql \
  /tmp/codeql-example8-verify
```

Compare full unfinalized build, cached build, and both import orders:

```sh
junk/nermishkin/codeql-gofix/tools/compare_unfinalized_import_orders.sh \
  /home/yngwie/codeql-home/codeql/codeql \
  /tmp/codeql-example8-import-orders
```

Benchmark cold and warm `codeql database create` runs for a target and compare `security-extended` results:

```sh
junk/nermishkin/codeql-gofix/tools/benchmark_database_create_cache.sh \
  /home/yngwie/codeql-home/codeql/codeql \
  /tmp/codeql-worker-cache-bench \
  security/digger/cmd/worker
```

- `build_fragment_bundle_databases.sh` - build full and fragment-injected databases using ya graph keyed fragment bundles
- `verify_fragment_bundle_databases.sh` - verify that fragment-bundle injection matches full builds for both example programs
- `benchmark_database_create_cache.sh` - build the same database twice with cold and warm `ya` cache, measure timings and compare `security-extended` findings

Registry-based fragment cache tools:

- `create_fragment_cached_database.sh` - build a final CodeQL DB using ya-emitted `codeql_fragment.json` manifests and fragment cache injection
- `verify_fragment_cache_source_change.sh` - verify that after a harmless source change in the top-level app, dependencies are restored from cache and only the app is rebuilt
- `build_fragment_cache.py` - materialize fragment cache from bootstrap registry manifests
- `inject_fragment_cache.py` - inject cached fragments by subtracting warm executed manifests from the cache index

Create a fragment-cached database for a target:

```sh
junk/nermishkin/codeql-gofix/tools/create_fragment_cached_database.sh   /home/yngwie/codeql-home/codeql/codeql   /tmp/codeql-fragment-create   junk/nermishkin/codeql-gofix/example8_import_shared_lib/cmd/hello_one
```

Verify that after changing only the app source, dependencies are restored from cache and only one Go node is rebuilt:

```sh
junk/nermishkin/codeql-gofix/tools/verify_fragment_cache_source_change.sh   /home/yngwie/codeql-home/codeql/codeql   /tmp/codeql-fragment-verify-source-change   junk/nermishkin/codeql-gofix/example8_import_shared_lib/cmd/hello_one   junk/nermishkin/codeql-gofix/example8_import_shared_lib/cmd/hello_one/main.go
```

