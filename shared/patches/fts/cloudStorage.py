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
# Adds `region` and `sigv4_header_mode` — both real columns on t_cloudStorage,
# both required for S3v4-signed transfers (Copernicus/non-AWS S3 endpoints) —
# which the upstream ORM model omits entirely. Without these, S3v4 signing
# config can only be written via direct SQL (see init-testbed.sh's prior
# `INSERT INTO t_cloudStorage (cloudStorage_name, region, sigv4_header_mode)`).
# This patch, paired with the matching change in controllers/config/cloud.py,
# makes that same write reachable over the already-ADMIN-gated REST endpoint
# instead — it doesn't change what's writable or who can write it, only how.
# See docs/patches.md for the accompanying rationale entry.
# ===============================================================================
from sqlalchemy import Column, String, Integer, ForeignKey

from .base import Base


class CloudStorage(Base):
    __tablename__ = "t_cloudStorage"

    storage_name = Column(String(150), primary_key=True, name="cloudStorage_name")
    app_key = Column(String(255))
    app_secret = Column(String(255))
    service_api_url = Column(String(1024))
    region = Column(String(100))
    # ASSUMPTION FLAGGED: init-testbed.sh's original raw INSERT writes this as
    # an integer literal (1), not a string — typed Integer here to match.
    # Verify against the live t_cloudStorage schema (`DESCRIBE t_cloudStorage`
    # in the ftsdb container) before relying on this; if the column is
    # actually TINYINT(1)/boolean, SQLAlchemy's Integer still round-trips
    # fine, but worth confirming rather than assuming.
    sigv4_header_mode = Column(Integer)


class CloudStorageUser(Base):
    __tablename__ = "t_cloudStorageUser"

    user_dn = Column(String(700), primary_key=True)
    storage_name = Column(
        String(150),
        ForeignKey("t_cloudStorage.cloudStorage_name"),
        primary_key=True,
        name="cloudStorage_name",
    )
    access_token = Column(String(255))
    access_token_secret = Column(String(255))
    request_token = Column(String(255))
    request_token_secret = Column(String(255))
    vo_name = Column(String(100), primary_key=True)

    def is_access_requested(self):
        return not (self.request_token is None or self.request_token_secret is None)

    def is_registered(self):
        return not (self.access_token is None or self.access_token_secret is None)
