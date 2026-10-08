package dep.match

import data.dep.utils.parsed_policies
import data.dep.match.action_is_matched
import data.dep.match.target_is_matched
import data.dep.match.assegnee_is_matched
import data.dep.match.constraint.constraint_is_matched
import rego.v1

rule_is_matched(rule) if {
	action_is_matched(rule)
	target_is_matched(rule)
	assegnee_is_matched(rule)
	constraint_is_matched(rule)
}

# Policies with a matching permission.
matched_permissions contains policy if {
	some policy in parsed_policies
	some rule in policy.permission
	rule_is_matched(rule)
}

# Policies with a matching prohibition; any match denies.
matched_prohibitions contains policy if {
	some policy in parsed_policies
	some rule in policy.prohibition
	rule_is_matched(rule)
}