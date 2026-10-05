package dep.validation.rule

import data.dep.validation.rule.rule_class_is_valid
import rego.v1

default obligation_is_valid(_) := false

obligation_is_valid(rule) if {
    rule_class_is_valid(rule)
}