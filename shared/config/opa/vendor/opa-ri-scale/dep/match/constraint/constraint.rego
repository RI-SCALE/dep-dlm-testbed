package dep.match.constraint

import data.dep.match.constraint.acr_is_matched
import data.dep.match.constraint.entitlement_is_matched
import rego.v1

default constraint_is_matched(_) := false

constraint_is_matched(rule) if not rule.constraint

# Every constraint must hold; an unknown leftOperand or operator fails closed.
constraint_is_matched(rule) if {
	rule.constraint
	every c in rule.constraint { _holds(c) }
}

_holds(c) if { c.leftOperand == "acr"; c.operator == "eq"; acr_is_matched(c) }
_holds(c) if { c.leftOperand in {"entitlement", "entitlements"}; c.operator == "eq"; entitlement_is_matched(c) }
