package dep.match.constraint

import data.dep.match.constraint.acr_is_matched
import data.dep.match.constraint.entitlement_is_matched
import rego.v1

default constraint_is_matched(_) := false

constraint_is_matched(rule) if not rule.constraint

# Every constraint must hold; an unknown leftOperand or operator fails closed.
constraint_is_matched(rule) if {
	rule.constraint
	every constraint in rule.constraint {
		_holds(constraint)
	}
}

_holds(constraint) if {
	constraint.leftOperand == "acr"
	constraint.operator == "eq"
	acr_is_matched(constraint)
}

_holds(constraint) if {
	constraint.leftOperand in {"entitlement", "entitlements"}
	constraint.operator == "eq"
	entitlement_is_matched(constraint)
}