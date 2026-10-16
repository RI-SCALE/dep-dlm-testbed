package dep.validation.rule

import data.dep.validation.rule.permission_is_valid
import data.dep.validation.rule.prohibition_is_valid
import data.dep.validation.rule.obligation_is_valid
import data.dep.utils._is_permission_rule
import data.dep.utils._is_prohibition_rule
import data.dep.utils._is_obligation_rule
import rego.v1

default rule_class_is_valid(_) := false
default rule_is_valid(_) := false

rule_class_is_valid(rule) if {
    rule.action
}

rule_is_valid(policy) if {
    _is_permission_rule(policy)
    some rule in policy.permission
    permission_is_valid(rule)
}

rule_is_valid(policy) if {
    _is_prohibition_rule(policy)
    some rule in policy.prohibition
    prohibition_is_valid(rule)
}

rule_is_valid(policy) if {
    _is_obligation_rule(policy)
    some rule in policy.obligation
    obligation_is_valid(rule)
}