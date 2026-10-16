#!/usr/bin/env python3
from rucio.db.sqla.util import build_database, create_base_vo, create_root_account
from sqlalchemy.exc import IntegrityError

# build_database() is Alembic-based and already tolerates re-runs (checks
# current migration version, no-ops if at head). create_base_vo()/
# create_root_account() aren't — each does a raw INSERT with no existence
# check, so re-running this script against an already-bootstrapped
# database previously failed with psycopg.errors.UniqueViolation on the
# VOS_PK constraint. Guarded here since a bootstrap script that isn't
# safe to run twice is a footgun on any re-install or re-triggered Job.
build_database()

try:
    create_base_vo()
except IntegrityError:
    print("Base VO already exists, skipping")

try:
    create_root_account()
except IntegrityError:
    print("Root account already exists, skipping")

print("DB bootstrap complete")
