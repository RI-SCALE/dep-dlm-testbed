package dep.validation.rule

import data.dep.validation.rule.rule_class_is_valid
import rego.v1

default permission_is_valid(_) := false

permission_is_valid(rule) if {
    rule_class_is_valid(rule)
    rule.target
}