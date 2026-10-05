package dep.match

import rego.v1

default target_is_matched(_) := false

target_is_matched(rule) if {
    input.resource.id == rule.target
}

target_is_matched(rule) if {
    not rule.target
}