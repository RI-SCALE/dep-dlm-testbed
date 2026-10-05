package dep.match.constraint

import rego.v1

default entitlement_is_matched(_) := false

entitlement_is_matched(constraint) if {
	some entitlement in input.token.entitlements
	entitlement == constraint.rightOperand
}