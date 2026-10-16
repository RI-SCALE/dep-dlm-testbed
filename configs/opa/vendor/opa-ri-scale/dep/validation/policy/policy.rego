package dep.validation.policy

import data.dep.validation.policy.set_is_valid
import data.dep.validation.policy.offer_is_valid
import data.dep.validation.policy.agreement_is_valid
import data.dep.utils._rule
import rego.v1

default policy_class_is_valid(_) := false
default policy_is_valid(_) := false

policy_class_is_valid(policy) if {
    policy.uid
    policy.type
    some rule_type in _rule
    policy[rule_type]
}

policy_is_valid(policy) if true in [
    set_is_valid(policy),
    offer_is_valid(policy),
    agreement_is_valid(policy)
]