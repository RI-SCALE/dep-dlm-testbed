#   Copyright Members of the EMI Collaboration, 2013.
#   Copyright 2013-2025 CERN
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
# === DEP DLM testbed patch ===================================================
# Removes the forced trailing-slash normalization on `issuer` in
# set_token_provider() below. That normalization directly conflicts with
# fts3rest/__init__.py's _load_providers_from_db(), whose own comment states
# the providers dict is keyed by the issuer EXACTLY as stored, with NO
# trailing-slash normalization, because it must match the raw 'iss' claim
# from the JWT verbatim. Keycloak (and most IdPs) issue tokens with no
# trailing slash on `iss` — so a provider row this endpoint force-normalizes
# to end in "/" can never match a real token, and every submission fails
# with "Issuer not found in configured providers" regardless of how the
# provider was registered. This patch makes the endpoint store `issuer`
# byte-for-byte as given, consistent with what the runtime lookup actually
# requires. It doesn't change auth, ownership, or any other field — only
# removes a normalization step that was silently breaking every provider
# registered through this endpoint. See docs/patches.md.
# ===============================================================================
import logging
from urllib.parse import unquote, urlparse

from flask import request, Response
from fts3rest.controllers.config import audit_configuration
from fts3rest.model import TokenProvider
from werkzeug.exceptions import BadRequest

from fts3rest.model import *
from fts3rest.lib.helpers.accept import accept
from fts3rest.lib.helpers.jsonify import jsonify
from fts3rest.lib.helpers.misc import get_input_as_dict
from fts3rest.lib.middleware.fts3auth.authorization import (
    authorize,
    require_certificate,
)
from fts3rest.lib.middleware.fts3auth.constants import ADMIN
from fts3rest.model.meta import Session

log = logging.getLogger(__name__)


"""
Configuration of OAuth2 Token Providers
"""


@authorize(ADMIN)
@accept(html_template="/config/token_providers.html")
def get_token_providers():
    """
    Get list of configured OAuth2 token providers
    """
    return Session.query(TokenProvider).all()


@authorize(ADMIN)
@jsonify
def set_token_provider():
    """
    Add or modify an OAuth2 token provider entry
    """
    input_dict = get_input_as_dict(request)
    log.warning(f"Setting new token provider: {input_dict}")
    if "name" not in input_dict:
        raise BadRequest("Missing TokenProvider name!")
    if "issuer" not in input_dict:
        raise BadRequest("Missing TokenProvider issuer!")
    else:
        try:
            result = urlparse(input_dict["issuer"])
            if not all([result.scheme, result.scheme]):
                raise BadRequest("Invalid TokenProvider issuer!")
        except AttributeError:
            raise BadRequest("Invalid TokenProvider issuer!")
    if "client_id" not in input_dict:
        raise BadRequest("Missing TokenProvider Client ID!")
    if "client_secret" not in input_dict:
        raise BadRequest("Missing TokenProvider Client Secret!")

    # DEP DLM testbed patch: issuer stored EXACTLY as given — no forced
    # trailing slash. See file header for why.
    issuer = input_dict.get("issuer")

    provider = TokenProvider(
        name=input_dict.get("name"),
        issuer=issuer,
        client_id=input_dict.get("client_id"),
        client_secret=input_dict.get("client_secret"),
        required_submission_scope=input_dict.get("required_submission_scope", None),
        vo_mapping=input_dict.get("vo_mapping", None),
    )
    try:
        Session.merge(provider)
        Session.commit()
    except Exception:
        Session.rollback()
        raise
    return provider


@authorize(ADMIN)
@jsonify
def delete_token_provider(provider_name):
    """
    Delete an existing OAuth2 token provider
    """
    try:
        name = unquote(provider_name)
        Session.query(TokenProvider).filter(TokenProvider.name == name).delete()
        audit_configuration(
            "token-provider-delete", f"Provider {name} has been deleted"
        )
        Session.commit()
    except:
        Session.rollback()
        raise
    return Response([""], status=204)
