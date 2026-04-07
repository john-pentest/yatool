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
- `tutorial_cases.qls`

Create a database for a tutorial case:

```sh
junk/nermishkin/codeql-gofix/tools/create_database.sh   /path/to/codeql   /tmp/example1_basic-db   junk/nermishkin/codeql-gofix/example1_basic/hello   --overwrite
```

Generate callgraph CSV from a database:

```sh
junk/nermishkin/codeql-gofix/tools/generate_callgraph_csv.sh   /path/to/codeql   /tmp/example1_basic-db   /tmp/example1_basic.csv
```
