from io import StringIO
import json
import logging.config
import os

import MySQLdb
from flask import Flask
from flask import request
from sqlalchemy import engine_from_config, event
from werkzeug.exceptions import HTTPException

from fts3rest.config.config import fts3_config_load
from fts3rest.config.routing import base, cstorage
from fts3rest.lib.helpers.connection_validator import (
    connection_validator,
    connection_set_sqlmode,
)
from fts3rest.lib.heartbeat import Heartbeat
from fts3rest.lib.middleware.fts3auth.fts3authmiddleware import FTS3AuthMiddleware
from fts3rest.lib.middleware.timeout import TimeoutHandler
from fts3rest.lib.openidconnect import oidc_manager
from fts3rest.model.meta import init_model, Session
from fts3rest.model import TokenProvider


def _load_configuration(config_file, test):
    # ConfigParser doesn't handle files without headers.
    # If the configuration file doesn't start with [fts3],
    # add it for backwards compatibility, as before migrating to Flask
    # the config file didn't have a header.
    with open(config_file, "r") as config:
        content = None
        for line in config:
            if not line.isspace() and not line.lstrip().startswith("#"):
                config.seek(0)
                if line.lstrip().startswith("[fts3]"):
                    content = StringIO(config.read())
                else:
                    content = StringIO("[fts3]\n" + config.read())
                break
        if not content:
            raise IOError("Empty configuration file")

    # Load configuration
    logging.config.fileConfig(content)
    content.seek(0)
    fts3cfg = fts3_config_load(content, test)
    content.close()
    return fts3cfg


def _load_db(app):
    # Setup the SQLAlchemy database engine
    kwargs = dict()
    if app.config["sqlalchemy.url"].startswith("mysql://"):
        kwargs["connect_args"] = {"cursorclass": MySQLdb.cursors.SSCursor}
    engine = engine_from_config(app.config, "sqlalchemy.", pool_recycle=7200, **kwargs)
    init_model(engine)

    # Disable for sqlite the isolation level to work around issues with savepoints
    if app.config["sqlalchemy.url"].startswith("sqlite"):

        @event.listens_for(engine, "connect")
        def do_connect(dbapi_connection, connection_record):
            dbapi_connection.isolation_level = None

    # Catch dead connections
    event.listens_for(engine, "checkout")(connection_validator)
    event.listens_for(engine, "connect")(connection_set_sqlmode)

    # Flask will automatically remove database sessions at the end of the request or when the application shuts down:
    @app.teardown_appcontext
    def shutdown_session(exception=None):
        Session.remove()


def _load_providers_from_db():
    """
    Load provider configuration from the database
    """
    log = logging.getLogger(__name__)
    providers = {}

    try:
        token_providers = Session.query(TokenProvider).all()
        if not token_providers:
            log.info("No token providers found in the database.")

        for provider in token_providers:
            # Keep the issuer exactly as stored: it must match the raw `iss`
            # claim (see OIDCmanager.get_token_issuer)
            provider_url = provider.issuer

            providers[provider_url] = {
                "client_id": provider.client_id,
                "client_secret": provider.client_secret,
                "oauth_scope_fts": provider.required_submission_scope,
                "vo": provider.vo_mapping,
            }
            log.info(f"Loaded token provider from database: {provider_url}")
    except Exception as e:
        log.error(f"Failed to load providers from database: {str(e)}")

    return providers


def create_app(default_config_file=None, test=False):
    """
    Create a new fts-rest Flask app
    :param default_config_file: Config file to use if the environment variable
    FTS3CONFIG is not set
    :param test: True if testing. FTS3TESTCONFIG will be used instead of FTS3CONFIG
    :return: the app
    """
    current_dir = os.path.abspath(os.path.dirname(__file__))
    static_dir = os.path.join(current_dir, "..", "static")
    app = Flask(__name__, static_folder=static_dir, static_url_path="")

    if test:
        config_file = os.environ.get("FTS3TESTCONFIG", default_config_file)
    else:
        config_file = os.environ.get("FTS3CONFIG", default_config_file)
    if not config_file:
        raise ValueError("The configuration file has not been specified")

    fts3cfg = _load_configuration(config_file, test)
    log = logging.getLogger(__name__)

    if (
        fts3cfg["fts3.DbType"] == "postgresql"
        and not fts3cfg["fts3.ExperimentalPostgresSupport"]
    ):
        raise ValueError(
            "Failed to create fts3rest web application: "
            "Invalid configuration file: "
            "fts3.DbType cannot be set to postgresql if fts3.ExperimentalPostgresSupport is not set to true: "
            f"config_file={config_file}"
        )

    # Add configuration
    app.config.update(fts3cfg)

    # Add routes
    base.do_connect(app)
    cstorage.do_connect(app)

    # Add DB
    _load_db(app)

    # Load token providers from database
    app.config["fts3.Providers"] = _load_providers_from_db()

    # FTS3 authentication/authorization middleware
    app.wsgi_app = FTS3AuthMiddleware(app.wsgi_app, app.config)

    # Catch DB Timeout
    app.wsgi_app = TimeoutHandler(app.wsgi_app, app.config)

    # Convert errors to JSON
    @app.errorhandler(HTTPException)
    def handle_exception(e):
        """Return JSON instead of HTML for HTTP errors."""
        # start with the correct headers and status code from the error
        response = e.get_response()
        # replace the body with JSON
        response.data = json.dumps(
            {
                "status": f"{e.code} {e.name}",
                "message": e.description,
            }
        )
        response.content_type = "application/json"
        return response

    # Log http request information after each request
    @app.after_request
    def log_request_info(response):
        log.info(
            '[From %s] [%s] "%s %s"'
            % (request.remote_addr, response.status, request.method, request.full_path)
        )
        return response

    # Heartbeat thread
    if not test:
        Heartbeat("fts_rest", int(app.config.get("fts3.HeartBeatInterval", 60))).start()

    # Start OIDC clients
    if app.config["fts3.Providers"]:
        oidc_manager.setup(app.config)
    else:
        log.info("OpenID Connect support disabled. No providers found in database")

    return app
