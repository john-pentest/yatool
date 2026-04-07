# CodeQL Go Tutorial Artifacts

This directory contains saved artifacts for the Go CodeQL tutorial cases from
`junk/nermishkin/codeql-gofix`.

## Layout

- `sarif/` - SARIF results for each test case
- `callgraph_svg/` - rendered call graphs for each test case

## Notes

The artifacts were produced from CodeQL databases built for the following cases:

- `example1_basic`
- `example2_dep_main_to_lib`
- `example3_dep_lib_to_main`
- `example4_cgo`
- `example5_codegen`
- `example6_vendor`
- `example7_proto`

The call graphs are based on CodeQL extraction results rather than plain AST-only
rendering:

- qualified names are shown when CodeQL resolves the callee symbol
- receiver/base type information is shown for method-style calls when available
- function declarations are annotated with `decl@path:line:col`
- external or leaf call targets that do not appear as local callers are still
  rendered as separate function-like nodes
- long labels are wrapped to stay inside graph nodes

For `vendor`-based extraction, the relevant runs use CodeQL with vendor
directories enabled.

