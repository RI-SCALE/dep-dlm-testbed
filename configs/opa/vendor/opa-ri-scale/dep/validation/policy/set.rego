package dep.validation.policy

import data.dep.validation.policy.policy_class_is_valid
import rego.v1

default set_is_valid(_) := false

_policy_types := {"Set", "Policy"}

set_is_valid(policy) if {
    policy_class_is_valid(policy)
    policy.type in _policy_types
}
