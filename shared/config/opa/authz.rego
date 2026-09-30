package vo.authz.v5

import rego.v1

# Rucio authorization policy — decision logic shared by both AUTHZ_MODE
# paths (direct: has_permission() queries this Rego directly; service:
# has_permission() calls authz-service, which queries this same Rego).
# See design-007 for the fold, design-005 for the contract this dispatch
# shape was originally built to satisfy.
#
# One dispatch line and one named rule per typed action. Everything else
# reaches the catch-all (privileged-operations).
#
# Privilege model:
#   rules, dids   ownership (design-003, design-004), or privilege
#   rses          privilege only: RSEs have no owning account in Rucio
#   protocols     privilege only: protocols belong to RSEs
#   replicas      ownership of every file's scope, or privilege

default allow := false

allow if { _action_allowed }

# Typed-endpoint action sets. Adding an action here without a dispatch line
# denies it for everyone, root included — it's no longer caught by the
# catch-all.
#
# Deliberately NOT listed, so they reach the catch-all (privileged only):
#   update_replicas_states, skip_availability_check (admin-only escalation),
#   approve_rule, reduce_rule, move_rule, access_rule_vo (design-004)

_rule_actions     := {"add_rule", "update_rule", "del_rule"}
_did_actions      := {"add_did", "add_dids", "attach_dids", "attach_dids_to_dids",
                       "detach_dids"}
_rse_actions      := {"add_rse", "update_rse", "del_rse",
                       "add_rse_attribute", "del_rse_attribute"}
_protocol_actions := {"add_protocol", "update_protocol", "del_protocol"}
_replica_actions  := {"add_replicas", "delete_replicas"}

_all_known_actions := _rule_actions | _did_actions | _rse_actions |
                      _protocol_actions | _replica_actions

# Dispatch

_action_allowed if { input.action == "add_rule";            _perm_add_rule }
_action_allowed if { input.action == "update_rule";         _perm_update_rule }
_action_allowed if { input.action == "del_rule";            _perm_del_rule }

_action_allowed if { input.action == "add_did";             _perm_add_did }
_action_allowed if { input.action == "add_dids";            _perm_add_dids }
_action_allowed if { input.action == "attach_dids";         _perm_attach_dids }
_action_allowed if { input.action == "attach_dids_to_dids"; _perm_attach_dids_to_dids }
_action_allowed if { input.action == "detach_dids";         _perm_detach_dids }

_action_allowed if { input.action == "add_rse";             _perm_add_rse }
_action_allowed if { input.action == "update_rse";          _perm_update_rse }
_action_allowed if { input.action == "del_rse";             _perm_del_rse }
_action_allowed if { input.action == "add_rse_attribute";   _perm_add_rse_attribute }
_action_allowed if { input.action == "del_rse_attribute";   _perm_del_rse_attribute }

_action_allowed if { input.action == "add_protocol";        _perm_add_protocol }
_action_allowed if { input.action == "update_protocol";     _perm_update_protocol }
_action_allowed if { input.action == "del_protocol";        _perm_del_protocol }

_action_allowed if { input.action == "add_replicas";        _perm_add_replicas }
_action_allowed if { input.action == "delete_replicas";     _perm_delete_replicas }

_action_allowed if {
    not _is_known_action(input.action)
    _is_privileged
}

_is_known_action(action) if { action in _all_known_actions }

# Rules (design-004)

_perm_add_rule if {
    _dst_rse_name_valid
    _src_rse_name_valid
    input.kwargs.account == input.issuer
    input.kwargs.locked == false
    count(input.kwargs.dids) > 0
    every did in input.kwargs.dids { did.scope in input.kwargs.owned_scopes }
}

_perm_add_rule if {
    _dst_rse_name_valid
    _src_rse_name_valid
    _is_privileged
}

_rule_reassignment_requested if {
    object.get(input.kwargs, ["options", "account"], null) != null
}

_perm_update_rule if { _is_privileged }
_perm_update_rule if {
    not _rule_reassignment_requested
    input.kwargs.rule_owner == input.issuer
    input.kwargs.rule_scope in input.kwargs.owned_scopes
}

_perm_del_rule if { _is_privileged }
_perm_del_rule if { input.kwargs.rule_owner == input.issuer }

# DIDs (design-003). Each action checks only the fields its own request
# shape has — add_dids/attach_dids_to_dids require every item in their
# list owned, not just one.

_perm_add_did if { _is_privileged }
_perm_add_did if { input.kwargs.scope in input.kwargs.owned_scopes }

_perm_add_dids if { _is_privileged }
_perm_add_dids if {
    count(input.kwargs.dids) > 0
    every did in input.kwargs.dids { did.scope in input.kwargs.owned_scopes }
}

_perm_attach_dids if { _is_privileged }
_perm_attach_dids if { input.kwargs.scope in input.kwargs.owned_scopes }

_perm_attach_dids_to_dids if { _is_privileged }
_perm_attach_dids_to_dids if {
    count(input.kwargs.attachments) > 0
    every attachment in input.kwargs.attachments {
        attachment.scope in input.kwargs.owned_scopes
    }
}

_perm_detach_dids if { _is_privileged }
_perm_detach_dids if { input.kwargs.scope in input.kwargs.owned_scopes }

# RSEs — no account column, so no ownership path; privilege only.

_perm_add_rse if {
    _is_privileged
    _rse_name_valid(input.kwargs.rse)
}

_perm_update_rse if {
    _is_privileged
    not input.kwargs.parameters.rse
}

_perm_update_rse if {
    _is_privileged
    _rse_name_valid(input.kwargs.parameters.rse)
}

_perm_del_rse if { _is_privileged }
_perm_add_rse_attribute if { _is_privileged }
_perm_del_rse_attribute if { _is_privileged }

# Protocols — privilege plus a scheme allowlist, checked even for root.

_default_allowed_schemes := {"davs", "s3", "https", "root", "xrdhttp", "gsiftp"}

_allowed_schemes := data.vo.policy.allowed_schemes if {
    data.vo.policy.allowed_schemes
} else := _default_allowed_schemes

_protocol_scheme_allowed if { not input.kwargs.scheme }
_protocol_scheme_allowed if { lower(input.kwargs.scheme) in _allowed_schemes }

_perm_add_protocol if { _is_privileged; _protocol_scheme_allowed }
_perm_update_protocol if { _is_privileged; _protocol_scheme_allowed }
_perm_del_protocol if { _is_privileged; _protocol_scheme_allowed }

# Replicas — ownership at the DID's scope grain (design-003), since a
# replica itself has no account column.

_all_file_scopes_owned if {
    count(input.kwargs.files) > 0
    every file in input.kwargs.files { file.scope in input.kwargs.owned_scopes }
}

_perm_add_replicas if { _is_privileged }

_perm_add_replicas if {
    _has_privilege_level("user")
    _rse_name_valid(input.kwargs.rse)
    _all_file_scopes_owned
}

_perm_add_replicas if {
    data.vo.policy.allow_replica_writes_to_allowlisted_rses == true
    _rse_name_valid(input.kwargs.rse)
    _all_file_scopes_owned
}

# No RSE-name check on delete — removing a record needs no naming guard.
_perm_delete_replicas if { _is_privileged }
_perm_delete_replicas if {
    _has_privilege_level("user")
    _all_file_scopes_owned
}

# RSE naming — data-driven allowlist/type set with hardcoded fallback.

_default_known_rse_types := {
    "DATADISK", "SCRATCHDISK", "LOCALGROUPDISK", "TAPE", "USERDISK",
}

_known_rse_types := data.vo.policy.known_rse_types if {
    data.vo.policy.known_rse_types
} else := _default_known_rse_types

_rse_name_valid(name) if { name in _allowlisted_rse_names }

_rse_name_valid(name) if {
    not name in _allowlisted_rse_names
    regex.match(`^[A-Z0-9]+_[A-Z0-9]+$`, name)
    parts := split(name, "_")
    count(parts) == 2
    parts[1] in _known_rse_types
}

_default_allowlisted_rse_names := set()

_allowlisted_rse_names := data.vo.policy.allowlisted_rse_names if {
    data.vo.policy.allowlisted_rse_names
} else := _default_allowlisted_rse_names

_dst_rse_name_valid if { not input.kwargs.rse_expression }
_dst_rse_name_valid if { _is_expression(input.kwargs.rse_expression) }
_dst_rse_name_valid if {
    not _is_expression(input.kwargs.rse_expression)
    _rse_name_valid(input.kwargs.rse_expression)
}

_src_rse_name_valid if { not input.kwargs.source_rse_expression }
_src_rse_name_valid if { _is_expression(input.kwargs.source_rse_expression) }
_src_rse_name_valid if {
    not _is_expression(input.kwargs.source_rse_expression)
    _rse_name_valid(input.kwargs.source_rse_expression)
}

_is_expression(expr) if { contains(expr, "=") }
_is_expression(expr) if { contains(expr, "&") }
_is_expression(expr) if { contains(expr, "|") }

# Authentication context. required_acr gates the OIDC privilege path only
# — root has no token and therefore no acr.

_acr_satisfied if { not data.vo.policy.required_acr }
_acr_satisfied if { input.token.acr == data.vo.policy.required_acr }

# Privilege — derived from the entitlements claim.

default _is_privileged := false

_is_privileged if { input.issuer == "root" }

_is_privileged if {
    _acr_satisfied
    _has_privilege_level("admin")
}

_has_privilege_level(level) if {
    entitlement := input.token.entitlements[_]
    _entitlement_privilege(entitlement) == level
}

# Bundle-driven when loaded; hardcoded fallback for CI/unit tests otherwise.

_entitlement_privilege(entitlement) := level if {
    level := data.vo.entitlement_policy[entitlement]
}

_entitlement_privilege(entitlement) := "admin" if {
    not data.vo.entitlement_policy
    entitlement in {
        "urn:example:aai.example.org:group:rucio-admins:role=member",
        "urn:example:aai.example.org:group:atlas-production:role=member",
    }
}

_entitlement_privilege(entitlement) := "user" if {
    not data.vo.entitlement_policy
    entitlement in {
        "urn:example:aai.example.org:group:rucio-users:role=member",
        "urn:example:aai.example.org:group:atlas-users:role=member",
    }
}
