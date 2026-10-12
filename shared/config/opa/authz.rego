package vo.authz.v5

import rego.v1

# Rucio authorization policy — role-based, claims only (ADR-008).
#
# The decision depends on the action and the token's claims alone. The tier
# comes from the vendored ODRL evaluator (data.dep), which matches the
# token's entitlements (group + role) and acr against the ODRL tier policy:
#
#   admin   every action (e.g. dep-operator, with MFA)
#   user    rules, DIDs and replicas, on any scope and whoever created them
#           (e.g. dep-end-user, model-developer)
#   none    nothing
#
# There are no ownership checks (scope or rule) and no checks on request
# arguments such as RSE names or protocol schemes. Accounts without a token
# (userpass) reach the admin tier only when listed in
# data.vo.policy.admin_accounts (default root).

default allow := false

allow if _is_admin

allow if {
	input.action in _user_actions
	_has_tier("user")
}

# Everything not listed here (RSEs, protocols, accounts, scopes,
# approve_rule, reduce_rule, move_rule, update_replicas_states, ...) is
# admin-only.
_user_actions := {
	"add_rule", "update_rule", "del_rule",
	"add_did", "add_dids", "attach_dids", "attach_dids_to_dids", "detach_dids",
	"add_replicas", "delete_replicas",
}

_admin_accounts := data.vo.policy.admin_accounts if {
	data.vo.policy.admin_accounts
} else := ["root"]

_rucio_target := data.vo.policy.rucio_target if {
	data.vo.policy.rucio_target
} else := "https://dep-dlm.example.org/rucio"

default _is_admin := false

_is_admin if input.issuer in _admin_accounts

_is_admin if _has_tier("admin")

# acr (MFA) constraints live in the ODRL policy, so they are enforced here.
_has_tier(level) if {
	data.dep.allow with input as {
		"action": concat(":", ["rucio", level]),
		"resource": {"id": _rucio_target},
		"token": input.token,
	}
}
