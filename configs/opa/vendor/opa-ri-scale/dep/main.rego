package dep

import data.dep.match.matched_permissions
import data.dep.match.matched_prohibitions
import data.dep.validation.policy.policy_is_valid
import data.dep.validation.rule.rule_is_valid

import rego.v1

default allow := false
default allow_and_valid := false

allow if {
    data.override.allow
}

allow if {
	not data.override.allow
	count(matched_permissions) > 0
	count(matched_prohibitions) == 0
}

allow_and_valid if {
    data.override.allow
}

allow_and_valid if {
    not data.override.allow
    allow
    some policy in matched_permissions
    policy_is_valid(policy)
    rule_is_valid(policy)
}