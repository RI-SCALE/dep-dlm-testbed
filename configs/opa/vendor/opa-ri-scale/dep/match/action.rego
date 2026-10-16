package dep.match

import rego.v1

default action_is_matched(_) := false

action_is_matched(rule) if {
    input.action == rule.action
}

action_is_matched(rule) if {
    not rule.action
}