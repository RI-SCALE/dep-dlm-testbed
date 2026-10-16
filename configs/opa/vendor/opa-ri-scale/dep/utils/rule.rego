package dep.utils

import rego.v1

default _is_permission_rule(_) := false
default _is_prohibition_rule(_) := false
_is_obligation_rule(_) := false

_rule := {"permission", "prohibition", "obligation"}

_is_permission_rule(policy) if {
    policy.permission
}

_is_prohibition_rule(policy) if {
    policy.prohibition
}

_is_obligation_rule(policy) if {
    policy.obligation
}