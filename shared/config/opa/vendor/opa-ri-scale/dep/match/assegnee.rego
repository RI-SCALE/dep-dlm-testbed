package dep.match

import rego.v1

default assegnee_is_matched(_) := false

assegnee_is_matched(rule) if {
    some entitlement in input.token.entitlements
	entitlement == rule.assignee
}

assegnee_is_matched(rule) if {
    not rule.assignee
}