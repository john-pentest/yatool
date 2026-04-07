/**
 * @name CLI argument reaches executed command
 * @description Tracks command-line input into executed commands in tutorial Go cases.
 * @kind problem
 * @problem.severity warning
 * @security-severity 7.5
 * @id go/tutorial/cli-arg-command
 * @tags security external/cwe/cwe-078
 */
import go
import semmle.go.Concepts
import semmle.go.dataflow.ExternalFlow
import semmle.go.dataflow.TaintTracking

class CliArgSource extends DataFlow::Node {
  CliArgSource() { sourceNode(this, "commandargs") }
}

module Config implements DataFlow::ConfigSig {
  predicate isSource(DataFlow::Node source) { source instanceof CliArgSource }
  predicate isSink(DataFlow::Node sink) { sink = any(SystemCommandExecution sce).getCommandName() }
  predicate observeDiffInformedIncrementalMode() { any() }
}

module Flow = TaintTracking::Global<Config>;

from CliArgSource source, DataFlow::Node sink
where Flow::flow(source, sink)
select sink.asExpr(), "Command-line argument reaches executed command."
