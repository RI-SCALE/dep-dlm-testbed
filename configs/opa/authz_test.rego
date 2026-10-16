# Unit tests for vo.authz.v1 — run with `opa test configs/opa -v`
# (the vendored ODRL evaluator under vendor/ must be loaded too).
#
# Decision logic only: no stack, no bundle. The ODRL tier policy is injected
# per test with `with data.dep.odrl`, mirroring odrl/data.json.
package vo.authz.v1_test

import rego.v1

_ns := "urn:example:aai.example.org:group:"

_dep_operator := concat("", [_ns, "dep-operator:role=member"])

_dep_end_user := concat("", [_ns, "dep-end-user:role=member"])

_model_developer := concat("", [_ns, "model-developer:role=member"])

_unlisted := concat("", [_ns, "cms-production:role=member"])

_mfa := "https://refeds.org/profile/mfa"

_target := "https://dep-dlm.example.org/rucio"

_odrl := {"policies": [{"uid": "urn:test:tiers", "type": "Set", "permission": [
	{
		"action": "rucio:admin", "target": _target, "assignee": _dep_operator,
		"constraint": [{"leftOperand": "acr", "operator": "eq", "rightOperand": _mfa}],
	},
	{"action": "rucio:user", "target": _target, "assignee": _dep_end_user},
	{"action": "rucio:user", "target": _target, "assignee": _model_developer},
]}]}

_rule_id := "1f0e3dad99908345f7439f8ffabdffc4"

# Someone else's data on testbed RSEs whose names follow no convention: the
# decision depends on neither ownership nor request arguments.
_foreign_files := [{"scope": "ddmlab", "name": "f1"}, {"scope": "other-group", "name": "f2"}]

_user_actions := [
	["add_rule", {"account": "ddmlab", "locked": true, "rse_expression": "XRD4", "source_rse_expression": "TEAPOT1", "dids": _foreign_files}],
	["update_rule", {"rule_id": _rule_id, "options": {"account": "ddmlab", "lifetime": 3600}}],
	["del_rule", {"rule_id": _rule_id}],
	["add_did", {"scope": "ddmlab", "name": "f"}],
	["add_dids", {"dids": _foreign_files}],
	["attach_dids", {"scope": "other-group", "name": "c"}],
	["attach_dids_to_dids", {"attachments": _foreign_files}],
	["detach_dids", {"scope": "ddmlab", "name": "c"}],
	["add_replicas", {"rse": "COPERNICUS_S3", "files": _foreign_files}],
	["delete_replicas", {"rse": "XRD3", "files": _foreign_files}],
]

_admin_actions := [
	["add_rse", {"rse": "XRD3"}],
	["update_rse", {"rse": "XRD3", "parameters": {"rse": "anything"}}],
	["del_rse", {"rse": "XRD3"}],
	["add_rse_attribute", {"rse": "XRD3", "key": "fts", "value": "https://fts:8446"}],
	["add_protocol", {"rse": "XRD3", "scheme": "ftp"}],
	["add_scope", {"account": "dependuser", "scope": "dependuser"}],
	["approve_rule", {"rule_id": _rule_id}],
	["reduce_rule", {"rule_id": _rule_id}],
	["move_rule", {"rule_id": _rule_id}],
	["update_replicas_states", {"rse": "XRD3"}],
	["some_unknown_action", {}],
]

# ── Helpers ─────────────────────────────────────────────────────────────

_ok(issuer, action, claims, kwargs) if {
	data.vo.authz.v1.allow with input as {
		"issuer": issuer, "action": action,
		"token": {"entitlements": claims}, "kwargs": kwargs,
	}
		with data.dep.odrl as _odrl
}

_ok_mfa(issuer, action, claims, kwargs) if {
	data.vo.authz.v1.allow with input as {
		"issuer": issuer, "action": action,
		"token": {"entitlements": claims, "acr": _mfa}, "kwargs": kwargs,
	}
		with data.dep.odrl as _odrl
}

_root_ok(action, kwargs) if _ok("root", action, [], kwargs)

# ── User tier: rules, DIDs and replicas on any scope ────────────────────

test_end_user_performs_every_user_action if {
	every pair in _user_actions { _ok("dependuser", pair[0], [_dep_end_user], pair[1]) }
}

test_model_developer_performs_every_user_action if {
	every pair in _user_actions { _ok("modeldeveloper", pair[0], [_model_developer], pair[1]) }
}

test_user_tier_denied_every_admin_action if {
	every pair in _admin_actions { not _ok("dependuser", pair[0], [_dep_end_user], pair[1]) }
	every pair in _admin_actions { not _ok("modeldeveloper", pair[0], [_model_developer], pair[1]) }
}

test_user_tier_needs_no_mfa if _ok("dependuser", "add_did", [_dep_end_user], {"scope": "ddmlab", "name": "f"})

test_user_tier_ignores_request_arguments if {
	_ok("dependuser", "add_rule", [_dep_end_user], {})
	_ok("dependuser", "add_rule", [_dep_end_user], {"rse_expression": "not a valid name"})
}

# ── Admin tier: everything ──────────────────────────────────────────────

test_operator_with_mfa_performs_everything if {
	every pair in _user_actions { _ok_mfa("depoperator", pair[0], [_dep_operator], pair[1]) }
	every pair in _admin_actions { _ok_mfa("depoperator", pair[0], [_dep_operator], pair[1]) }
}

test_operator_without_mfa_gets_nothing if {
	every pair in _user_actions { not _ok("depoperator", pair[0], [_dep_operator], pair[1]) }
	every pair in _admin_actions { not _ok("depoperator", pair[0], [_dep_operator], pair[1]) }
}

# ── No tier ─────────────────────────────────────────────────────────────

test_no_entitlements_gets_nothing if {
	every pair in _user_actions { not _ok("carol", pair[0], [], pair[1]) }
}

test_unlisted_entitlement_gets_nothing if {
	every pair in _user_actions { not _ok("carol", pair[0], [_unlisted], pair[1]) }
}

test_mfa_alone_grants_nothing if not _ok_mfa("carol", "add_did", [], {"scope": "ddmlab", "name": "f"})

test_missing_token_gets_nothing if {
	not data.vo.authz.v1.allow with input as {"issuer": "carol", "action": "add_did", "kwargs": {}}
		with data.dep.odrl as _odrl
}

# ── Admin accounts (userpass, no token) ─────────────────────────────────

test_root_performs_everything if {
	every pair in _user_actions { _root_ok(pair[0], pair[1]) }
	every pair in _admin_actions { _root_ok(pair[0], pair[1]) }
}

test_unlisted_account_without_token_gets_nothing if not _ok("ddmlab", "add_did", [], {"scope": "ddmlab", "name": "f"})

test_listed_account_is_admin if {
	_ok("ddmlab", "add_rse_attribute", [], {"rse": "XRD3"}) with data.vo.policy.admin_accounts as ["root", "ddmlab"]
	_ok("ddmlab", "add_rule", [], {"rse_expression": "XRD4"}) with data.vo.policy.admin_accounts as ["root", "ddmlab"]
}

test_listing_replaces_default if {
	not _root_ok("del_rse", {"rse": "XRD3"}) with data.vo.policy.admin_accounts as ["ddmlab"]
}

# ── ODRL prohibitions win over permissions ──────────────────────────────

test_prohibition_revokes_user_tier if {
	odrl := {"policies": [
		_odrl.policies[0],
		{"uid": "urn:test:ban", "type": "Set", "prohibition": [{"action": "rucio:user", "target": _target, "assignee": _dep_end_user}]},
	]}
	not data.vo.authz.v1.allow with input as {
		"issuer": "dependuser", "action": "add_did",
		"token": {"entitlements": [_dep_end_user]}, "kwargs": {"scope": "ddmlab", "name": "f"},
	}
		with data.dep.odrl as odrl
}

test_listed_account_with_token_needs_a_tier if {
	not data.vo.authz.v1.allow with input as {
		"issuer": "root", "action": "del_rse",
		"token": {"sub": "x", "entitlements": []}, "kwargs": {},
	}
		with data.dep.odrl as _odrl
}
