package dep.validation.policy

import data.dep.validation.policy.policy_class_is_valid
import data.dep.utils._rule
import rego.v1

default offer_is_valid(_) := false

offer_is_valid(policy) if {
    policy_class_is_valid(policy)
    policy.type == "Offer"
    some rule_type in _rule
    some rule in policy[rule_type]
    rule.assegner
}