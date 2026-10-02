# Unit tests for vo.authz.v5 — run with `opa test policies/rego -v`.
#
# Decision logic only: no stack, no bundle. Data the deployed bundle would
# carry is injected per test with `with data.vo...`; without it the Rego's
# hardcoded fallbacks apply (rucio-admins/atlas-production → admin,
# rucio-users/atlas-users → user).
package vo.authz.v5_test

import rego.v1

_admin := "urn:example:aai.example.org:group:rucio-admins:role=member"

_user := "urn:example:aai.example.org:group:rucio-users:role=member"

_atlas_prod := "urn:example:aai.example.org:group:atlas-production:role=member"

_atlas_user := "urn:example:aai.example.org:group:atlas-users:role=member"

_cms_prod := "urn:example:aai.example.org:group:cms-production:role=member"

_dep_operator := "urn:example:aai.example.org:group:dep-operator:role=member"

_dep_end_user := "urn:example:aai.example.org:group:dep-end-user:role=member"

_model_developer := "urn:example:aai.example.org:group:model-developer:role=member"

_mfa := "https://refeds.org/profile/mfa"

_rule_id := "1f0e3dad99908345f7439f8ffabdffc4"

# Mirrors scripts/init-phase6.sh: randomaccount owns a scope named after it
# and one that is not; ddmlab owns a scope whose name starts with randomaccount.
_owned := "randomaccount"

_unnamed := "projectdata"

_foreign := "ddmlab"

_prefixed := "randomaccountleak"

_owned_files := [{"scope": _owned, "name": "f1"}, {"scope": _unnamed, "name": "f2"}]

_both_owned := [_owned, _unnamed]

# The phase 6 bundle's mapping, DEP personas included (design-008).
_bundle := {
	_admin: "admin", _atlas_prod: "admin", _dep_operator: "admin",
	_user: "user", _atlas_user: "user", _dep_end_user: "user", _model_developer: "user",
}

# ── Helpers ─────────────────────────────────────────────────────────────

_ok(issuer, action, claims, kwargs) if {
	data.vo.authz.v5.allow with input as {
		"issuer": issuer, "action": action,
		"token": {"entitlements": claims}, "kwargs": kwargs,
	}
}

_ok_acr(issuer, action, claims, acr, kwargs) if {
	data.vo.authz.v5.allow with input as {
		"issuer": issuer, "action": action,
		"token": {"entitlements": claims, "acr": acr}, "kwargs": kwargs,
	}
}

_root_ok(action, kwargs) if _ok("root", action, [], kwargs)

_user_rule(dids, owned, extra) := object.union(
	{"account": _owned, "locked": false, "rse_expression": "CERN_DATADISK", "dids": dids, "owned_scopes": owned},
	extra,
)

_update(extra) := object.union({"rule_id": _rule_id}, extra)

# ── Privilege from entitlements ─────────────────────────────────────────

test_admin_grants_del_rse if _ok("adminuser", "del_rse", [_admin], {})

test_user_denied_del_rse if not _ok(_owned, "del_rse", [_user], {})

test_no_claims_denied_privileged if not _ok(_owned, "del_rse", [], {})

test_atlas_production_is_admin if _ok("prod", "add_rse", [_atlas_prod], {"rse": "CERN_DATADISK"})

test_atlas_users_is_not_admin if not _ok(_owned, "add_rse", [_atlas_user], {"rse": "CERN_DATADISK"})

test_any_admin_claim_grants if _ok("adminuser", "del_rse", [_atlas_prod, _admin], {})

test_user_claims_together_grant_nothing if not _ok(_owned, "del_rse", [_user, _atlas_user], {})

test_naming_rule_blocks_admin if {
	not _ok("adminuser", "add_rule", [_admin], {"account": "adminuser", "locked": false, "rse_expression": "cern_bad"})
}

test_approve_rule_requires_admin if {
	not _ok(_owned, "approve_rule", [_user], {})
	_ok("adminuser", "approve_rule", [_admin], {})
}

# ── Authentication context (acr) ────────────────────────────────────────

test_acr_ignored_when_not_required if {
	_ok_acr("adminuser", "del_rse", [_admin], _mfa, {})
	_ok("adminuser", "del_rse", [_admin], {})
}

test_acr_match_allows if _ok_acr("adminuser", "del_rse", [_admin], _mfa, {}) with data.vo.policy.required_acr as _mfa

test_acr_missing_denies if not _ok("adminuser", "del_rse", [_admin], {}) with data.vo.policy.required_acr as _mfa

test_acr_differs_denies if {
	not _ok_acr("adminuser", "del_rse", [_admin], "urn:mace:incommon:iap:silver", {}) with data.vo.policy.required_acr as _mfa
}

test_root_unaffected_by_acr if _root_ok("del_rse", {}) with data.vo.policy.required_acr as _mfa

test_rule_self_service_unaffected_by_acr if {
	_ok(_owned, "del_rule", [_user], {"rule_id": _rule_id, "rule_owner": _owned}) with data.vo.policy.required_acr as _mfa
}

test_scope_ownership_unaffected_by_acr if {
	_ok(_owned, "add_did", [_user], {"scope": _owned, "name": "f", "owned_scopes": [_owned]}) with data.vo.policy.required_acr as _mfa
}

# ── add_rule: rule ownership AND data ownership (design-004) ────────────

test_add_rule_own_rule_own_data if _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _owned, "name": "f1"}], [_owned], {}))

test_add_rule_owned_unnamed_scope if _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _unnamed, "name": "f1"}], [_unnamed], {}))

test_add_rule_foreign_data_denied if not _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _foreign, "name": "f1"}], [], {}))

test_add_rule_prefix_foreign_denied if not _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _prefixed, "name": "f1"}], [_owned], {}))

test_add_rule_one_foreign_did_denied if {
	not _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _owned, "name": "f1"}, {"scope": _foreign, "name": "f2"}], [_owned], {}))
}

test_add_rule_empty_dids_denied if not _ok(_owned, "add_rule", [_user], _user_rule([], [_owned], {}))

test_add_rule_locked_denied if not _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _owned, "name": "f1"}], [_owned], {"locked": true}))

test_add_rule_other_account_denied if {
	not _ok(_owned, "add_rule", [_user], _user_rule([{"scope": _owned, "name": "f1"}], [_owned], {"account": _foreign}))
}

test_add_rule_admin_foreign_data if {
	_ok("adminuser", "add_rule", [_admin], {"account": "adminuser", "locked": false, "rse_expression": "CERN_DATADISK", "dids": [{"scope": _foreign, "name": "f1"}], "owned_scopes": []})
}

# ── del_rule / update_rule: facts from the rules table ──────────────────

test_owner_deletes_own_rule if _ok(_owned, "del_rule", [_user], {"rule_id": _rule_id, "rule_owner": _owned})

test_non_owner_delete_denied if not _ok(_owned, "del_rule", [_user], {"rule_id": _rule_id, "rule_owner": _foreign})

test_unresolvable_rule_delete_denied if not _ok(_owned, "del_rule", [_user], {"rule_id": _rule_id})

test_admin_deletes_any_rule if _ok("adminuser", "del_rule", [_admin], {"rule_id": _rule_id, "rule_owner": _foreign})

test_owner_updates_own_rule if {
	_ok(_owned, "update_rule", [_user], _update({"options": {"lifetime": 3600}, "rule_owner": _owned, "rule_scope": _owned, "owned_scopes": [_owned]}))
}

test_owner_update_unowned_scope_denied if {
	not _ok(_owned, "update_rule", [_user], _update({"options": {"lifetime": 3600}, "rule_owner": _owned, "rule_scope": _foreign, "owned_scopes": [_owned]}))
}

test_update_without_options_allowed if {
	_ok(_owned, "update_rule", [_user], _update({"rule_owner": _owned, "rule_scope": _owned, "owned_scopes": [_owned]}))
}

test_reassignment_denied_for_owner if {
	not _ok(_owned, "update_rule", [_user], _update({"options": {"account": _foreign}, "rule_owner": _owned, "rule_scope": _owned, "owned_scopes": [_owned]}))
}

test_reassignment_to_self_denied if {
	not _ok(_owned, "update_rule", [_user], _update({"options": {"account": _owned}, "rule_owner": _owned, "rule_scope": _owned, "owned_scopes": [_owned]}))
}

test_reassignment_allowed_for_admin if {
	_ok("adminuser", "update_rule", [_admin], _update({"options": {"account": _foreign}, "rule_owner": _owned, "rule_scope": _owned, "owned_scopes": []}))
}

test_unresolvable_rule_update_denied if {
	not _ok(_owned, "update_rule", [_user], _update({"options": {"lifetime": 3600}, "owned_scopes": [_owned]}))
}

test_reduce_and_move_rule_privileged_only if {
	not _ok(_owned, "reduce_rule", [_user], {"rule_id": _rule_id})
	_ok("adminuser", "reduce_rule", [_admin], {"rule_id": _rule_id})
	not _ok(_owned, "move_rule", [_user], {"rule_id": _rule_id})
	_ok("adminuser", "move_rule", [_admin], {"rule_id": _rule_id})
}

# ── Scope ownership (DIDs) ──────────────────────────────────────────────

test_did_owned_scope if _ok(_owned, "add_did", [_user], {"scope": _owned, "name": "f", "owned_scopes": [_owned]})

test_did_owned_unnamed_scope if _ok(_owned, "add_did", [_user], {"scope": _unnamed, "name": "f", "owned_scopes": [_unnamed]})

test_did_prefix_foreign_denied if not _ok(_owned, "add_did", [_user], {"scope": _prefixed, "name": "f", "owned_scopes": [_owned]})

test_did_unowned_denied if not _ok(_owned, "add_did", [_user], {"scope": _foreign, "name": "f", "owned_scopes": [_owned]})

test_did_missing_owned_scopes_denied if not _ok(_owned, "add_did", [_user], {"scope": _owned, "name": "f"})

test_did_privileged_without_ownership if _ok("adminuser", "add_did", [_admin], {"scope": _foreign, "name": "f", "owned_scopes": []})

test_detach_follows_ownership if {
	_ok(_owned, "detach_dids", [_user], {"scope": _owned, "name": "c", "owned_scopes": [_owned]})
	not _ok(_owned, "detach_dids", [_user], {"scope": _foreign, "name": "c", "owned_scopes": [_owned]})
}

test_add_dids_all_owned if _ok(_owned, "add_dids", [_user], {"dids": _owned_files, "owned_scopes": _both_owned})

test_add_dids_one_unowned_denied if {
	not _ok(_owned, "add_dids", [_user], {"dids": [{"scope": _owned, "name": "f1"}, {"scope": _foreign, "name": "f2"}], "owned_scopes": [_owned]})
}

test_add_dids_empty_denied if not _ok(_owned, "add_dids", [_user], {"dids": [], "owned_scopes": [_owned]})

test_attach_dids_to_dids_requires_every_attachment if {
	_ok(_owned, "attach_dids_to_dids", [_user], {"attachments": [{"scope": _owned, "name": "c"}], "owned_scopes": [_owned]})
	not _ok(_owned, "attach_dids_to_dids", [_user], {"attachments": [{"scope": _foreign, "name": "c"}], "owned_scopes": [_owned]})
	not _ok(_owned, "attach_dids_to_dids", [_user], {"attachments": [{"scope": _owned, "name": "c"}, {"scope": _foreign, "name": "d"}], "owned_scopes": [_owned]})
}

# ── Replicas: ownership of every file's scope ───────────────────────────

test_add_replicas_admin_without_files if _ok("adminuser", "add_replicas", [_admin], {"rse": "CERN_DATADISK"})

test_add_replicas_user_all_owned if _ok(_owned, "add_replicas", [_user], {"rse": "CERN_DATADISK", "files": _owned_files, "owned_scopes": _both_owned})

test_add_replicas_one_foreign_denied if {
	not _ok(_owned, "add_replicas", [_user], {"rse": "CERN_DATADISK", "files": [{"scope": _owned, "name": "f1"}, {"scope": _foreign, "name": "f2"}], "owned_scopes": [_owned]})
}

test_add_replicas_without_files_denied if not _ok(_owned, "add_replicas", [_user], {"rse": "CERN_DATADISK"})

test_add_replicas_bad_rse_denied if not _ok(_owned, "add_replicas", [_user], {"rse": "cern_bad", "files": _owned_files, "owned_scopes": _both_owned})

test_add_replicas_no_claims_denied if not _ok("carol", "add_replicas", [], {"rse": "CERN_DATADISK", "files": _owned_files, "owned_scopes": _both_owned})

test_delete_replicas_admin_without_files if _ok("adminuser", "delete_replicas", [_admin], {"rse": "CERN_DATADISK"})

test_delete_replicas_no_rse_name_check if _ok(_owned, "delete_replicas", [_user], {"rse": "cern_bad", "files": _owned_files, "owned_scopes": _both_owned})

# ── RSE-name allowlist ──────────────────────────────────────────────────

test_unlisted_name_needs_convention if not _ok("adminuser", "add_rse", [_admin], {"rse": "NOTANRSE"})

test_allowlisted_testbed_rse if {
	_ok("adminuser", "add_rse", [_admin], {"rse": "XRD3"}) with data.vo.policy.allowlisted_rse_names as ["XRD3", "XRD4", "TEAPOT1", "TEAPOT2"]
}

test_convention_still_applies_with_allowlist if {
	_ok("adminuser", "add_rse", [_admin], {"rse": "CERN_DATADISK"}) with data.vo.policy.allowlisted_rse_names as ["XRD3"]
	not _ok("adminuser", "add_rse", [_admin], {"rse": "cern_bad"}) with data.vo.policy.allowlisted_rse_names as ["XRD3"]
}

# ── Root bootstrap ──────────────────────────────────────────────────────

test_root_bootstrap if {
	_root_ok("del_rse", {})
	_root_ok("add_rse", {"rse": "CERN_DATADISK"})
	_root_ok("some_unknown_action", {})
	_root_ok("add_did", {"scope": _foreign, "name": "d"})
	_root_ok("del_rule", {"rule_id": _rule_id})
	_root_ok("add_replicas", {"rse": "XRD3"})
}

test_root_blocked_by_naming_rule if not _root_ok("add_rule", {"account": "root", "locked": false, "rse_expression": "cern_bad"})

# ── Bundle-driven entitlement policy ────────────────────────────────────

test_bundle_custom_entitlement if {
	_ok("cmsuser", "del_rse", [_cms_prod], {}) with data.vo.entitlement_policy as {_cms_prod: "admin", _user: "user"}
}

test_bundle_removed_entitlement_loses_privilege if {
	not _ok("adminuser", "del_rse", [_admin], {}) with data.vo.entitlement_policy as {_atlas_prod: "admin"}
	_ok("prod", "del_rse", [_atlas_prod], {}) with data.vo.entitlement_policy as {_atlas_prod: "admin"}
}

test_bundle_user_tier_reaches_add_replicas if {
	_ok(_owned, "add_replicas", [_user], {"rse": "CERN_DATADISK", "files": _owned_files, "owned_scopes": _both_owned}) with data.vo.entitlement_policy as {_admin: "admin", _user: "user"}
	not _ok(_owned, "add_replicas", [_atlas_user], {"rse": "CERN_DATADISK", "files": _owned_files, "owned_scopes": _both_owned}) with data.vo.entitlement_policy as {_admin: "admin", _user: "user"}
}

# ── DEP personas (design-008) — need the bundle mapping ─────────────────

test_dep_operator_is_admin if {
	_ok("depoperator", "del_rse", [_dep_operator], {}) with data.vo.entitlement_policy as _bundle
	_ok("depoperator", "add_rse", [_dep_operator], {"rse": "CERN_DATADISK"}) with data.vo.entitlement_policy as _bundle
	_ok("depoperator", "approve_rule", [_dep_operator], {}) with data.vo.entitlement_policy as _bundle
}

test_dep_end_user_is_user_tier if {
	not _ok("dependuser", "del_rse", [_dep_end_user], {}) with data.vo.entitlement_policy as _bundle
	_ok("dependuser", "add_did", [_dep_end_user], {"scope": _owned, "name": "f", "owned_scopes": [_owned]}) with data.vo.entitlement_policy as _bundle
	_ok("dependuser", "add_replicas", [_dep_end_user], {"rse": "CERN_DATADISK", "files": _owned_files, "owned_scopes": _both_owned}) with data.vo.entitlement_policy as _bundle
	not _ok("dependuser", "add_replicas", [_dep_end_user], {"rse": "CERN_DATADISK"}) with data.vo.entitlement_policy as _bundle
}

test_model_developer_is_user_tier if {
	not _ok("modeldeveloper", "del_rse", [_model_developer], {}) with data.vo.entitlement_policy as _bundle
	_ok("modeldeveloper", "add_rule", [_model_developer], {"account": "modeldeveloper", "locked": false, "rse_expression": "CERN_DATADISK", "dids": [{"scope": _owned, "name": "f1"}], "owned_scopes": [_owned]}) with data.vo.entitlement_policy as _bundle
}

test_dep_personas_unknown_without_bundle if not _ok("depoperator", "del_rse", [_dep_operator], {})
