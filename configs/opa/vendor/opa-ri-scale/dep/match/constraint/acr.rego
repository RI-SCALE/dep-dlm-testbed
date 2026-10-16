package dep.match.constraint

import rego.v1

default acr_is_matched(_) := false

acr_is_matched(constraint) if {
	input.token.acr == constraint.rightOperand
}