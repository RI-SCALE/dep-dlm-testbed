#   Copyright Members of the EMI Collaboration, 2013.
#   Copyright 2013-2020 CERN
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
# set_cloud_storage() below accepts two extra fields (region,
# sigv4_header_mode) not present upstream — see the matching model patch
# (model/cloudStorage.py) for why. This is additive only: every upstream
# field, decorator, and auth check (@require_certificate + @authorize(ADMIN),
# already verified against this testbed's host cert) is untouched. It does
# not change who can write cloud storage config or what auth is required —
# only which fields are accepted once they're authorized to. See
# docs/patches.md for the accompanying rationale entry.
# ===============================================================================
import logging

from flask import request, Response
from werkzeug.exceptions import BadRequest, NotFound

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
Configuration of cloud storages
"""


@require_certificate
@authorize(ADMIN)
@accept(html_template="/config/cloud_storage.html")
def get_cloud_storages():
    """
    Get a list of cloud storages registered
    """
    storages = Session.query(CloudStorage).all()
    for storage in storages:
        users = Session.query(CloudStorageUser).filter(
            CloudStorageUser.storage_name == storage.storage_name
        )
        setattr(storage, "users", list(users))
    return storages


@require_certificate
@authorize(ADMIN)
@jsonify
def set_cloud_storage():
    """
    Add or modify a cloud storage entry
    """
    input_dict = get_input_as_dict(request)
    if "storage_name" not in input_dict:
        raise BadRequest("Missing storage name")

    storage = CloudStorage(
        storage_name=input_dict.get("storage_name"),
        app_key=input_dict.get("app_key", None),
        app_secret=input_dict.get("app_secret", None),
        service_api_url=input_dict.get("service_api_url", None),
        # DEP DLM testbed patch: S3v4 signing config, see model/cloudStorage.py
        region=input_dict.get("region", None),
        sigv4_header_mode=input_dict.get("sigv4_header_mode", None),
    )
    try:
        Session.merge(storage)
        Session.commit()
    except Exception:
        Session.rollback()
        raise
    return Response(storage.storage_name, status=201)


@require_certificate
@authorize(ADMIN)
@jsonify
def get_cloud_storage(storage_name):
    """
    Get a list of users registered for a given storage name
    """
    storage = Session.query(CloudStorage).get(storage_name)
    if not storage:
        raise NotFound("The storage does not exist")

    users = Session.query(CloudStorageUser).filter(
        CloudStorageUser.storage_name == storage_name
    )
    return users


@require_certificate
@authorize(ADMIN)
def remove_cloud_storage(storage_name):
    """
    Remove a registered cloud storage
    """
    storage = Session.query(CloudStorage).get(storage_name)
    if not storage:
        raise NotFound("The storage does not exist")

    try:
        Session.query(CloudStorageUser).filter(
            CloudStorageUser.storage_name == storage_name
        ).delete()
        Session.delete(storage)
        Session.commit()
    except Exception:
        Session.rollback()
        raise

    return Response([""], status=204)


@require_certificate
@authorize(ADMIN)
@jsonify
def add_user_to_cloud_storage(storage_name):
    """
    Add a user or a VO credentials to the storage
    """
    storage = Session.query(CloudStorage).get(storage_name)
    if not storage:
        raise NotFound("The storage does not exist")

    input_dict = get_input_as_dict(request)
    if not input_dict.get("user_dn", None) and not input_dict.get("vo_name", None):
        raise BadRequest("One of user_dn or vo_name must be specified")
    elif input_dict.get("user_dn", None) and input_dict.get("vo_name", None):
        raise BadRequest("Only one of user_dn or vo_name must be specified")

    cuser = CloudStorageUser(
        user_dn=input_dict.get("user_dn", ""),
        storage_name=storage_name,
        access_token=input_dict.get("access_key", input_dict.get("access_token", None)),
        access_token_secret=input_dict.get(
            "secret_key", input_dict.get("access_token_secret", None)
        ),
        request_token=input_dict.get("request_token"),
        request_token_secret=input_dict.get("request_token_secret"),
        vo_name=input_dict.get("vo_name", ""),
    )

    try:
        Session.merge(cuser)
        Session.commit()
    except Exception:
        Session.rollback()
        raise

    ret = dict(
        storage_name=cuser.storage_name, user_dn=cuser.user_dn, vo_name=cuser.vo_name
    )
    return Response(ret, status=201)


@require_certificate
@authorize(ADMIN)
def remove_user_from_cloud_storage(storage_name, id):
    """
    Delete credentials for a given user/vo
    """
    storage = Session.query(CloudStorage).get(storage_name)
    if not storage:
        raise NotFound("The storage does not exist")

    users = (
        Session.query(CloudStorageUser)
        .filter(CloudStorageUser.storage_name == storage_name)
        .filter((CloudStorageUser.vo_name == id) | (CloudStorageUser.user_dn == id))
    )

    try:
        for user in users:
            Session.delete(user)
        Session.commit()
    except Exception:
        Session.rollback()
        raise

    return Response([""], status=204)
