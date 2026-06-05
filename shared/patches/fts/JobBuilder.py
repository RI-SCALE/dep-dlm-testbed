#   Copyright 2015-2020 CERN
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

import base64
import itertools
import json
import socket
import time

from datetime import datetime
from urllib.parse import urlparse, parse_qsl, ParseResult, urlencode
from itertools import chain
from flask import current_app as app
from .JobBuilder_utils import *
from fts3rest.lib.middleware.fts3auth import credentials
from fts3rest.model import CloudStorage
from fts3rest.model.meta import Session

log = logging.getLogger(__name__)


class JobBuilder:
    """
    From a dictionary, build the internal representation of Job, Files and
    Data Management
    """

    def _get_params(self, submitted_params):
        """
        Returns proper parameters applying defaults and user values
        """
        params = dict()
        params.update(DEFAULT_PARAMS)
        params.update(submitted_params)
        # Some parameters may be explicitly None to pick the default, so re-apply defaults
        for k, v in params.items():
            if v is None and k in DEFAULT_PARAMS:
                params[k] = DEFAULT_PARAMS[k]

        # Enforce JSON type for 'job_metadata'
        if params["job_metadata"] is not None:
            params["job_metadata"] = metadata(
                params["job_metadata"],
                size_limit=app.config["fts3.JobMetadataSizeLimit"],
            )

        return params

    def _build_internal_job_params(self):
        """
        Generates the value for job.internal_job_params depending on the
        received protocol parameters
        """
        param_list = []
        if self.params.get("nostreams", None):
            param_list.append("nostreams:%d" % int(self.params["nostreams"]))
        if self.params.get("timeout", None):
            param_list.append("timeout:%d" % int(self.params["timeout"]))
        if self.params.get("buffer_size", None):
            param_list.append("buffersize:%d" % int(self.params["buffer_size"]))
        if self.params.get("strict_copy", False):
            param_list.append("strict")
        if self.params.get("disable_cleanup", False):
            param_list.append("disable-cleanup")
        if self.params.get("ipv4", False):
            param_list.append("ipv4")
        elif self.params.get("ipv6", False):
            param_list.append("ipv6")
        if self.params.get("s3alternate", False):
            param_list.append("s3alternate")

        if len(param_list) == 0:
            return None
        else:
            return ",".join(param_list)

    def _set_job_source_and_destination(self, entries):
        """
        Iterates through the files that belong to the job, and determines the
        'overall' job source and destination Storage Elements
        """
        # Multihop
        if self.job["job_type"] == "H":
            self.job["source_se"] = entries[0]["source_se"]
            self.job["dest_se"] = entries[-1]["dest_se"]
        # Regular transfers
        else:
            self.job["source_se"] = entries[0]["source_se"]
            self.job["dest_se"] = entries[0]["dest_se"]
            for elem in entries:
                if elem["source_se"] != self.job["source_se"]:
                    self.job["source_se"] = None
                if elem["dest_se"] != self.job["dest_se"]:
                    self.job["dest_se"] = None

    def _set_activity_query_string(self, url, file_dict):
        """
        Set the activity query string in the given url
        """
        query_p = parse_qsl(url.query)
        query_p.append(("activity", file_dict.get("activity", "default")))
        query_str = urlencode(query_p)
        return ParseResult(
            scheme=url.scheme,
            netloc=url.netloc,
            path=url.path,
            params=url.params,
            query=query_str,
            fragment=url.fragment,
        )

    def _populate_files(self, file_dict, f_index, shared_hashed_id):
        """
        From the dictionary file_dict, generate a list of transfers for a job
        """

        # FTS4: Fail all transfers if there are multiple destinations
        if (
            app.config["fts3.DbType"] == "postgresql"
            and app.config["fts3.ExperimentalPostgresSupport"]
        ):
            if len(file_dict["destinations"]) > 1:
                raise BadRequest(
                    "File transfers with multiple destinations are not allowed."
                )

        # Extract transfer tuples where each tuple has a source, destination
        # source token and destination token.  Source and destination
        # tokens will be None if the client is using X509 proxy certificates
        tuples = []

        # Use a combination of empty lists and itertools.zip_longest() to handle
        # the fact the JSON submit/job request will not contain source or
        # destination tokens if the client is using X509 proxy certificates
        src_tokens = file_dict.get("source_tokens", [])
        dst_tokens = file_dict.get("destination_tokens", [])

        for source, src_token in itertools.zip_longest(
            file_dict["sources"], src_tokens
        ):
            source_url = urlparse(source.strip())
            validate_url(source_url)
            if src_token is not None and not isinstance(src_token, str):
                raise BadRequest(
                    f"Source token is not a string: type(src_token)={type(src_token)}"
                )
            src_token_id = credentials.generate_token_id(src_token)
            for destination, dst_token in itertools.zip_longest(
                file_dict["destinations"], dst_tokens
            ):
                dest_url = urlparse(destination.strip())
                validate_url(dest_url)
                if dst_token is not None and not isinstance(dst_token, str):
                    raise BadRequest(
                        f"Destination token is not a string: type(dst_token)={type(dst_token)}"
                    )
                dst_token_id = credentials.generate_token_id(dst_token)
                tuples.append((source_url, dest_url, src_token_id, dst_token_id))

        # Create one File entry per matching pair
        if self.is_bringonline:
            initial_file_state = "STAGING"
        else:
            initial_file_state = "SUBMITTED"

        # Multiple replica job or multihop? Then, the initial state is NOT_USED
        if len(file_dict["sources"]) > 1 or self.params["multihop"]:
            # if self.is_bringonline:
            # set the first as STAGING and the rest as 'NOT_USED'
            # staging_and_multihop = True
            # raise HTTPBadRequest('Staging with multiple replicas is not allowed')
            # On multiple replica job, we mark all files initially with NOT_USED
            initial_file_state = "NOT_USED"
            # Multiple replicas, all must share the hashed-id
            if shared_hashed_id is None:
                shared_hashed_id = generate_hashed_id()
        vo_name = self.user.vos[0]

        for source, destination, src_token_id, dst_token_id in tuples:
            if len(file_dict["sources"]) > 1 or not is_dest_surl_uuid_enabled(vo_name):
                dest_uuid = None
            else:
                dest_uuid = str(
                    uuid.uuid5(BASE_ID, destination.geturl().encode("utf-8"))
                )
            if self.is_bringonline:
                # add the new query parameter only for root -> EOS-CTA for now
                if source.scheme == "root":
                    if source == destination:
                        destination = self._set_activity_query_string(
                            destination, file_dict
                        )
                    source = self._set_activity_query_string(source, file_dict)
            # Allow/disallow protocol translation
            self._validate_protocol_translation(source, destination)

            f = dict(
                job_id=self.job_id,
                file_index=f_index,
                dest_surl_uuid=dest_uuid,
                file_state=initial_file_state,
                file_state_initial="",
                source_surl=source.geturl(),
                dest_surl=destination.geturl(),
                source_se=get_storage_element(source),
                dest_se=get_storage_element(destination),
                vo_name=None,
                priority=self.job["priority"],
                user_filesize=safe_filesize(file_dict.get("filesize", 0)),
                selection_strategy=file_dict.get("selection_strategy", "auto"),
                checksum=file_dict.get("checksum", None),
                file_metadata=file_dict.get("metadata", None),
                staging_metadata=file_dict.get("staging_metadata", None),
                archive_metadata=file_dict.get("archive_metadata", None),
                activity=file_dict.get("activity", "default"),
                scitag=validate_scitag(file_dict.get("scitag", None)),
                src_token_id=src_token_id,
                dst_token_id=dst_token_id,
                hashed_id=(
                    shared_hashed_id if shared_hashed_id else generate_hashed_id()
                ),
            )
            if f["file_metadata"] is not None:
                f["file_metadata"] = metadata(
                    f["file_metadata"],
                    size_limit=app.config["fts3.FileMetadataSizeLimit"],
                )
            if f["staging_metadata"] is not None:
                f["staging_metadata"] = metadata(
                    f["staging_metadata"],
                    require_dict=True,
                    name_hint="Staging metadata",
                    size_limit=app.config["fts3.StagingMetadataSizeLimit"],
                )
            if f["archive_metadata"] is not None:
                f["archive_metadata"] = metadata(
                    f["archive_metadata"],
                    require_dict=True,
                    name_hint="Archive metadata",
                    size_limit=app.config["fts3.ArchiveMetadataSizeLimit"],
                )
            # Account for the fact file_dict may contain an activity set to None
            if f["activity"] is None:
                f["activity"] = "default"
            self.files.append(f)

    def _apply_selection_strategy(self):
        """
        On multiple-replica jobs, select the adequate file to go active
        """
        entry_state = "STAGING" if self.is_bringonline else "SUBMITTED"
        select_best_replica(
            self.files,
            self.user.vos[0],
            entry_state,
            self.files[0].get("selection_strategy", "auto"),
        )

    def _check_checksum(self):
        # If a checksum is provided, but no checksum is available, 'target' comparison
        # (Not nice, but need to keep functionality!) Also by default all files will have ADLER32 checksum type
        has_checksum = False
        for file_dict in self.files:
            if file_dict["checksum"] is not None:
                has_checksum = len(file_dict["checksum"]) > 0
            else:
                file_dict["checksum"] = "ADLER32"

        if type(self.job["checksum_method"]) == bool:
            if not self.job["checksum_method"] and has_checksum:
                self.job["checksum_method"] = "target"
            else:
                if not self.job["checksum_method"] and not has_checksum:
                    self.job["checksum_method"] = "none"
                else:
                    self.job["checksum_method"] = "both"

        self.job["checksum_method"] = self.job["checksum_method"][0]

    def _apply_auto_session_reuse(self):
        # Return early if SessionReuse not allowed
        if not app.config.get("fts3.AllowSessionReuse", True):
            return False
        # Return early if job type is already "Session Reuse"
        if self.job["job_type"] == "Y":
            return False

        auto_session_reuse = app.config.get("fts3.AutoSessionReuse", False)
        log.debug(
            "job_type={} AutoSessionReuse={}".format(
                self.job["job_type"], auto_session_reuse
            )
        )

        min_reuse_files = int(app.config.get("fts3.AutoSessionReuseMinFiles", 5))
        max_reuse_files = int(app.config.get("fts3.AutoSessionReuseMaxFiles", 1000))
        max_reuse_big_files = int(app.config.get("fts3.AutoSessionReuseMaxBigFiles", 2))
        max_size_small_file = int(
            app.config.get("fts3.AutoSessionReuseMaxSmallFileSize", 104857600)
        )  # 100MB
        max_size_big_file = int(
            app.config.get("fts3.AutoSessionReuseMaxBigFileSize", 1073741824)
        )  # 1GB

        auto_session_reuse_preconditions = (
            auto_session_reuse
            and not self.is_multiple_replica
            and not self.is_bringonline
            and self.job["source_se"]
            and self.job["dest_se"]
            and 1 <= min_reuse_files <= len(self.files) <= max_reuse_files
        )

        if auto_session_reuse and not auto_session_reuse_preconditions:
            log.debug("Skipping AutoSessionReuse: Preconditions not met")
            return False

        if auto_session_reuse_preconditions:
            small_files = 0
            big_files = 0

            for file in self.files:
                if 0 < file["user_filesize"] <= max_size_small_file:
                    small_files += 1
                elif max_size_small_file < file["user_filesize"] <= max_size_big_file:
                    big_files += 1

            if small_files + big_files < len(self.files):
                log.debug(
                    "Skipping AutoSessionReuse: small_files={} + big_files={} < total_files={}".format(
                        small_files, big_files, len(self.files)
                    )
                )
            elif big_files > max_reuse_big_files:
                log.debug(
                    "Skipping AutoSessionReuse: big_files={} > AutoSessionReuseMaxBigFiles={}".format(
                        big_files, max_reuse_big_files
                    )
                )
            else:
                self.job["job_type"] = "Y"
                log.info(
                    "AutoSessionReuse applied: small_files={} big_files={} / total_files={}".format(
                        small_files, big_files, len(self.files)
                    )
                )
                # Reset the hashed IDs to ensure they land on the same machine
                shared_hashed_id = generate_hashed_id()
                for file in self.files:
                    file["hashed_id"] = shared_hashed_id
                return True
        return False

    def _apply_job_type(self):
        if self.params["multihop"]:
            return "H"
        if safe_flag(self.params["reuse"]) and app.config.get(
            "fts3.AllowSessionReuse", True
        ):
            return "Y"
        return "N"

    def _validate_job_type_preconditions(self, unique_files):
        if self.is_multiple_replica:
            if self.job["job_type"] in ("H", "Y"):
                raise BadRequest(
                    "Can not request multiple replica job together with multihop or session reuse at the same time"
                )
            if unique_files > 1:
                raise BadRequest("Multiple replica jobs must only have one unique file")
        if self.job["job_type"] == "Y" and (
            not self.job["source_se"] or not self.job["dest_se"]
        ):
            raise BadRequest(
                "Reuse jobs must only contain transfers for the same source ad destination storage"
            )

    def _validate_overwrite_flag(self):
        """
        Validates and returns the correct overwrite flag
        If an invalid combination is detected, a user error is raised.

        Y -- overwrite enabled
        R -- overwrite enabled only on FTS retries
        M -- overwrite enabled only for intermediary hops
        D -- overwrite-when-only-on-disk feature enabled (overwrite if destination file has only disk locality)
        Q -- overwrite-hop + overwrite-when-only-on-disk behavior
        """

        overwrite_flags_count = sum(
            [
                safe_flag(self.params["overwrite"]),
                safe_flag(self.params["overwrite_on_retry"]),
                safe_flag(self.params["overwrite_when_only_on_disk"]),
                safe_flag(self.params["overwrite_hop"]),
            ]
        )
        # "overwrite_hop" and "overwrite_when_only_on_disk" allowed to work together
        if overwrite_flags_count > 1 and not (
            overwrite_flags_count == 2
            and self.params["overwrite_hop"]
            and self.params["overwrite_when_only_on_disk"]
        ):
            raise BadRequest("Incompatible overwrite flags used at the same time")
        if (
            self.params["overwrite_when_only_on_disk"]
            and safe_int(self.params["archive_timeout"]) <= 0
        ):
            raise BadRequest(
                "'overwrite-when-only-on-disk' requires 'archive-timeout' to be set"
            )
        if self.params["overwrite"]:
            return "Y"
        if self.params["overwrite_on_retry"]:
            return "R"
        if self.params["overwrite_hop"] and self.params["overwrite_when_only_on_disk"]:
            return "Q"  # Multihop + overwrite disk
        if self.params["overwrite_hop"]:
            return "M"
        if self.params["overwrite_when_only_on_disk"]:
            return "D"
        return None

    def _validate_overwrite_disk_destination(self, job_type, files_list):
        """
        When the "overwrite-when-only-on-disk" feature is enabled,
        restrict usage only to HTTP/DAV target endpoints (capable of Tape REST API).
        According to the job type:
            - Multihop jobs: the final destination must be checked
            - All other job types: all destinations must be checked

        If an invalid submission is detected, raises a user error
        """

        def _is_http_endpoint(endpoint):
            if not endpoint.startswith(tuple(["https://", "davs://", "mock://"])):
                raise BadRequest(
                    "'overwrite-when-only-on-disk' requires destination "
                    "to be HTTPs endpoint (Tape REST API required)"
                )

        if job_type == "H":
            destinations = files_list[-1]["destinations"]
        else:
            destinations = [file_dict["destinations"] for file_dict in files_list]
            destinations = list(chain.from_iterable(destinations))
        any(map(_is_http_endpoint, destinations))

    def _validate_protocol_translation(self, source, destination):
        if app.config.get("fts3.AllowProtocolTranslation", True):
            return
        source_prot = canonical_protocol(source)
        destination_prot = canonical_protocol(destination)

        if (
            source_prot in PROTOCOL_MATRIX.keys()
            and destination_prot in PROTOCOL_MATRIX.keys()
        ):
            if source_prot != destination_prot:
                raise BadRequest(
                    f"Protocol translation transfer between {source.geturl()} and {destination.geturl()} is not allowed ({source_prot} != {destination_prot})",
                )

    def _file_list_contains_a_token_list(self, files_list):
        """
        Returns true if the list of file contains at least one list of source or destination tokens
        """

        for file_dict in files_list:
            if "source_tokens" in file_dict:
                return True
            if "destination_tokens" in file_dict:
                return True
        return False

    def _all_cloud_storage(self, urls):
        """
        True if every URL in the list is backed by a cloud_storage credential
        (i.e. authenticates with static keys, not OIDC tokens). An empty list
        is not considered cloud-storage-backed.
        """
        if not urls:
            return False
        for url in urls:
            se = get_storage_element(urlparse(url.strip()))
            if not self._cloud_storage_exists(se):
                return False
        return True

    def _cloud_storage_exists(self, storage_element):
        """
        Return True if the given storage element is registered as a cloud_storage
        in FTS (t_cloudStorage). Cloud storages are named "<SERVICE>:<host>"
        (e.g. "S3:eodata.dataspace.copernicus.eu"); match on host.
        """
        if not storage_element:
            return False

        # Extract host whether storage_element is scheme://host:port,
        # host:port, or bare host.
        parsed = urlparse(storage_element)
        se_host = parsed.hostname
        if not se_host:
            se_host = storage_element.split("://")[-1].split(":")[0].split("/")[0]

        try:
            rows = Session.query(CloudStorage.storage_name).all()
        except Exception as ex:
            log.warning(f"cloud_storage lookup failed: {ex}")
            return False

        for (cs_name,) in rows:
            if not cs_name:
                continue
            cs_host = cs_name.split(":", 1)[1] if ":" in cs_name else cs_name
            cs_host = cs_host.split(":")[0]  # strip any trailing :port
            if cs_host == se_host:
                return True
        return False

    def _add_missing_tokens_if_necessary(self, files_list):
        """
        Adds missing tokens if "single token" end user
        """

        # If "single token" end user
        if self.user.method == "oauth2" and not self._file_list_contains_a_token_list(
            files_list
        ):
            # Get bearer token from HTTP headers
            http_auth_header = self.request.environ["HTTP_AUTHORIZATION"].split()
            bearer_token = http_auth_header[1]

            # Add bearer token as missing source and destination tokens
            for file_dict in files_list:
                file_dict["source_tokens"] = []
                for i in range(len(file_dict["sources"])):
                    file_dict["source_tokens"].append(bearer_token)

                file_dict["destination_tokens"] = []
                for i in range(len(file_dict["destinations"])):
                    file_dict["destination_tokens"].append(bearer_token)

    def _validate_transfer_tokens(self, files_list):
        for file_dict in files_list:
            sources = file_dict.get("sources", [])
            destinations = file_dict.get("destinations", [])
            source_tokens = file_dict.get("source_tokens", [])
            destination_tokens = file_dict.get("destination_tokens", [])
            if source_tokens or destination_tokens:
                # A side may legitimately have no token when it authenticates via
                # cloud_storage (static S3/GCS keys) instead of OIDC. Treat such a
                # side as satisfied so asymmetric token/cloud_storage transfers
                # (e.g. S3 source -> token-based WebDAV destination) are allowed.
                sources_need_token = not self._all_cloud_storage(sources)
                dests_need_token = not self._all_cloud_storage(destinations)

                if sources_need_token and not source_tokens:
                    raise BadRequest(
                        "source_tokens required for non-cloud-storage sources"
                    )
                if dests_need_token and not destination_tokens:
                    raise BadRequest(
                        "destination_tokens required for non-cloud-storage destinations"
                    )

                # Length / per-token checks apply ONLY to a side that carries tokens.
                # A cloud_storage side legitimately has an empty token list.
                if source_tokens:
                    if len(source_tokens) != len(sources):
                        raise BadRequest(
                            "Length of source_tokens should be equal to the length of sources."
                        )
                    for source, source_token in zip(sources, source_tokens):
                        if not source_token:
                            raise BadRequest(f"Token for source '{source}' is missing.")

                if destination_tokens:
                    if len(destination_tokens) != len(destinations):
                        raise BadRequest(
                            "Length of destination_tokens should be equal to the length of destinations."
                        )
                    for destination, destination_token in zip(
                        destinations, destination_tokens
                    ):
                        if not destination_token:
                            raise BadRequest(
                                f"Token for destination '{destination}' is missing."
                            )

    def _add_tokens_to_dict(self, tokens_dict, token_list):
        """
        Adds the specified tokens to the specified dictionary
        """

        for token in token_list:
            token_id = credentials.generate_token_id(token)
            tokens_dict[token_id] = token

    def _get_jwt_payload(self, token):
        """
        Extracts, decodes and parses the payload of the specified token
        """

        segments = token.split(".")
        if len(segments) < 3:
            raise Exception(f"Not enough token segments: min=3 actual={len(segments)}")
        payload = segments[1]
        len_payload_mod_4 = len(segments[1]) % 4
        if len_payload_mod_4 > 0:
            payload = payload + "=" * (4 - len_payload_mod_4)
        decoded_payload = base64.urlsafe_b64decode(payload)
        return json.loads(decoded_payload)

    def _populate_tokens(self, files_list):
        """
        Generates the list of tokens ready for the database
        """

        self.unmanaged_tokens = safe_flag(self.params["unmanaged_tokens"])
        if self.unmanaged_tokens and not app.config.get("fts3.AllowNonManagedTokens"):
            raise BadRequest("Unmanaged tokens are not allowed!")

        # Create a self.tokens attribute no matter what
        self.tokens = []

        if self.user.method != "oauth2" or not files_list:
            return

        tokens_dict = {}
        for file_dict in files_list:
            # Source and destination tokens will not be present when the client is
            # using X509 proxy certificates
            src_tokens = file_dict.get("source_tokens", [])
            dst_tokens = file_dict.get("destination_tokens", [])

            self._add_tokens_to_dict(tokens_dict, src_tokens)
            self._add_tokens_to_dict(tokens_dict, dst_tokens)

        for token_item in tokens_dict.items():
            token_id = token_item[0]
            token = token_item[1]

            try:
                jwt_payload = self._get_jwt_payload(token)
            except Exception as ex:
                log.warning(f"Failed to parse JWT: token_id={token_id} error={ex}")
                jwt_payload = {}

            token_dict = {
                "token_id": token_id,
                "access_token": token,
                "refresh_token": None,
                "unmanaged": self.unmanaged_tokens,
            }

            if "iss" in jwt_payload:
                token_dict["issuer"] = safe_issuer(jwt_payload["iss"])
            else:
                raise BadRequest("Token does not contain an iss claim")
            if "nbf" in jwt_payload:
                token_dict["nbf"] = jwt_payload["nbf"]
            else:
                # If token does not have a nbf claim just consider the current unix timestamp
                token_dict["nbf"] = int(time.time())
            if "exp" in jwt_payload:
                token_dict["exp"] = jwt_payload["exp"]
            else:
                raise BadRequest("Token does not contain an exp claim")
            if "scope" in jwt_payload:
                token_dict["scope"] = jwt_payload["scope"]
            else:
                raise BadRequest("Token does not contain a scope claim")
            if "aud" in jwt_payload:
                if jwt_payload["aud"] is None:
                    token_dict["audience"] = None
                elif isinstance(jwt_payload["aud"], str):
                    token_dict["audience"] = jwt_payload["aud"]
                elif isinstance(jwt_payload["aud"], list):
                    token_dict["audience"] = " ".join(jwt_payload["aud"])
                else:
                    raise BadRequest(
                        f"Token audience must be a null, string or list of strings: actual_type={type(jwt_payload['aud'])}"
                    )
            else:
                if app.config.get("fts3.VerifyAudience"):
                    raise BadRequest("Token does not contain an aud claim")
                else:
                    token_dict["audience"] = None
            self.tokens.append(token_dict)

    def _populate_transfers(self, files_list):
        """
        Initializes the list of transfers
        """
        job_type = self._apply_job_type()

        self.is_bringonline = (
            safe_int(self.params["copy_pin_lifetime"]) > 0
            or safe_int(self.params["bring_online"]) > 0
        )

        if self.is_bringonline:
            job_initial_state = "STAGING"
        else:
            job_initial_state = "SUBMITTED"

        max_time_in_queue = seconds_from_value(
            self.params.get("max_time_in_queue", None)
        )
        expiration_time = None
        if max_time_in_queue is not None:
            expiration_time = time.time() + max_time_in_queue

        if max_time_in_queue is not None and safe_int(self.params["bring_online"]) > 0:
            # Ensure that the bringonline and expiration delta is respected
            timeout_delta = seconds_from_value(
                app.config.get("fts3.BringOnlineAndExpirationDelta", None)
            )
            if timeout_delta is not None:
                log.debug(
                    "Will enforce BringOnlineAndExpirationDelta="
                    + str(timeout_delta)
                    + "s"
                )
                if (
                    max_time_in_queue - safe_int(self.params["bring_online"])
                    < timeout_delta
                ):
                    raise BadRequest(
                        "Bringonline and Expiration timeout must be at least "
                        + str(timeout_delta)
                        + " seconds apart"
                    )

        overwrite_flag = self._validate_overwrite_flag()

        if (
            overwrite_flag in ["M", "Q"]
            and job_type != "H"
            and not app.config.get("fts3.OverwriteHopValidation", True)
        ):
            log.warning(
                "Bad request: 'overwrite-hop' requires multihop job submission: "
                f"remote_addr={self.request.environ['REMOTE_ADDR']}"
            )

        if (
            overwrite_flag in ["M", "Q"]
            and job_type != "H"
            and app.config.get("fts3.OverwriteHopValidation", True)
        ):
            log.error(
                "Failing bad request: "
                "'overwrite-hop' requires multihop job submission: "
                f"remote_addr={self.request.environ['REMOTE_ADDR']}"
            )
            raise BadRequest("'overwrite-hop' requires multihop job submission")
        if overwrite_flag in ["D", "Q"]:
            self._validate_overwrite_disk_destination(job_type, files_list)

        self.job = dict(
            job_id=self.job_id,
            job_state=job_initial_state,
            job_type=job_type,
            retry=int(self.params["retry"]),
            retry_delay=int(self.params["retry_delay"]),
            job_params=self.params["gridftp"],
            submit_host=socket.getfqdn(),
            user_dn=None,
            voms_cred=None,
            vo_name=None,
            cred_id=None,
            submit_time=datetime.utcnow(),
            priority=max(min(int(self.params["priority"]), 5), 1),
            destination_spacetoken=self.params["destination_spacetoken"],
            overwrite_flag=overwrite_flag,
            dst_file_report=safe_flag(self.params["dst_file_report"]),
            source_spacetoken=self.params["source_spacetoken"],
            copy_pin_lifetime=safe_int(self.params["copy_pin_lifetime"]),
            checksum_method=self.params["verify_checksum"],
            bring_online=safe_int(self.params["bring_online"]),
            archive_timeout=safe_int(self.params["archive_timeout"]),
            job_metadata=self.params["job_metadata"],
            internal_job_params=self._build_internal_job_params(),
            max_time_in_queue=expiration_time,
        )

        if "credential" in self.params:
            self.job["user_cred"] = self.params["credential"]
        elif "credentials" in self.params:
            self.job["user_cred"] = self.params["credentials"]

        # Generate one single "hash" for all files for multihop, session reuse and bringonline jobs
        # (One single hash guarantees transfers are picked up by the same staging/transfer node)
        if self.job["job_type"] in ("H", "Y") or self.is_bringonline:
            shared_hashed_id = generate_hashed_id()
        else:
            shared_hashed_id = None

        # Files
        f_index = 0
        for file_dict in files_list:
            self._populate_files(file_dict, f_index, shared_hashed_id)
            f_index += 1

        if len(self.files) == 0:
            raise BadRequest("No valid pairs available")

        self._check_checksum()
        self._set_job_source_and_destination(self.files)
        self.is_multiple_replica, unique_files = has_multiple_options(self.files)
        self._validate_job_type_preconditions(unique_files)

        if self.is_multiple_replica:
            self.job["job_type"] = "R"
            # Apply selection strategy
            self._apply_selection_strategy()
        # For multihop + staging mark the first as STAGING
        elif self.params["multihop"] and self.is_bringonline:
            self.files[0]["file_state"] = "STAGING"
        # For multihop, mark the first as SUBMITTED
        elif self.params["multihop"]:
            self.files[0]["file_state"] = "SUBMITTED"

        auto_session_reuse_applied = self._apply_auto_session_reuse()
        log.debug(
            "job_type={} reuse={} AutoSessionReuse_applied={}".format(
                self.job["job_type"], self.params["reuse"], auto_session_reuse_applied
            )
        )

    def _set_user(self):
        """
        Set the user that triggered the action
        """
        self.job["user_dn"] = self.user.user_dn
        self.job["cred_id"] = self.user.delegation_id
        self.job["voms_cred"] = " ".join(self.user.voms_cred)
        self.job["vo_name"] = self.user.vos[0]
        for file in self.files:
            file["vo_name"] = self.user.vos[0]

    def _add_auth_method_on_job_metadata(self):
        if (
            self.params["job_metadata"] is not None
            and self.params["job_metadata"] != "None"
        ):
            self.params["job_metadata"].update({"auth_method": self.user.method})
        else:
            self.params["job_metadata"] = {"auth_method": self.user.method}

    def __init__(self, request, **kwargs):
        """
        Constructor
        """
        try:
            self.request = request
            self.user = request.environ["fts3.User.Credentials"]

            # Get the job parameters
            self.params = self._get_params(kwargs.pop("params", dict()))

            # Update auth method used
            self._add_auth_method_on_job_metadata()

            files_list = kwargs.pop("files", None)
            datamg_list = kwargs.pop("delete", None)

            # Be backwards compatible with single token clients
            self._add_missing_tokens_if_necessary(files_list)

            if datamg_list is not None:
                raise MethodNotAllowed(
                    description="Deletion jobs are no longer supported by FTS"
                )
            if files_list is None:
                raise BadRequest("No transfers operations specified")
            id_generator = self.params.get("id_generator", "standard")
            if id_generator == "deterministic":
                log.debug("Deterministic")
                sid = self.params.get("sid", None)
                if sid is not None:
                    log.info("sid: " + sid)
                    vo_id = uuid.uuid5(BASE_ID, self.user.vos[0])
                    self.job_id = str(uuid.uuid5(vo_id, str(sid)))
                else:
                    raise BadRequest("Need sid for deterministic job id generation")
            else:
                self.job_id = str(uuid.uuid1())
            self.files = []

            if self.user.method == "oauth2":
                self._validate_transfer_tokens(files_list)

            self._populate_tokens(files_list)

            if files_list is not None:
                self._populate_transfers(files_list)

            validate_submitted_file_limits(len(files_list))

            self._set_user()

            # Reject for SE banning
            # If any SE does not accept submissions, reject the whole job
            # Update wait_timeout and wait_timestamp if WAIT_AS is set
            if self.files:
                apply_banning(self.files)

        except ValueError as ex:
            raise BadRequest("Invalid value within the request: %s" % str(ex))
        except TypeError as ex:
            log.exception("JobBuilder -- printing stacktrace")
            raise BadRequest("Malformed request: %s" % str(ex))
        except KeyError as ex:
            raise BadRequest("Missing parameter: %s" % str(ex))
