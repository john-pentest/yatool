/**
 * @name CLI argument flows into vendor dependency call
 * @description Tracks command-line input into the vendor dependency call in the tutorial vendor case using an existing vendored library.
 * @kind problem
 * @problem.severity warning
 * @security-severity 6.5
 * @id go/tutorial/vendor-arg-flow
 * @tags security external/cwe/cwe-020
 */
import go
import semmle.go.dataflow.ExternalFlow
import semmle.go.dataflow.TaintTracking

class CliArgSource extends DataFlow::Node {
  CliArgSource() { sourceNode(this, "commandargs") }
}

module Config implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node source) { source instanceof CliArgSource }
  predicate isSink(DataFlow::Node sink) {
    exists(CallExpr call, Function f |
      sink.asExpr() = call.getArgument(0) and
      f = call.getTarget() and
      f.getPackage().getPath() = "github.com/golang/protobuf/proto" and
      f.getName() = "String"
    )
  }
  predicate observeDiffInformedIncrementalMode() { any() }
}

module Flow = TaintTracking::Global<Config>;

from CliArgSource source, DataFlow::Node sink
where Flow::flow(source, sink)
select sink.asExpr(), "Command-line argument flows into vendor dependency call."
