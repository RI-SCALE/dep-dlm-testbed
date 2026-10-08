package dep_test

import rego.v1

_conflict := {"policies": [{
	"uid": "p4", "type": "Set",
	"permission": [{"action": "read", "target": "t", "assignee": "member"}],
	"prohibition": [{"action": "read", "target": "t", "assignee": "member"}],
}]}

test_prohibition_overrides_permission if {
	not data.dep.allow with data.dep.odrl as _conflict
		with input as {"action": "read", "resource": {"id": "t"}, "token": {"entitlements": ["member"]}}
}

test_prohibition_overrides_permission_in_allow_and_valid if {
	not data.dep.allow_and_valid with data.dep.odrl as _conflict
		with input as {"action": "read", "resource": {"id": "t"}, "token": {"entitlements": ["member"]}}
}
