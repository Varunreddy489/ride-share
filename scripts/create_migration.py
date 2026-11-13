import logging
import os
import sys

import psycopg
from dotenv import load_dotenv
from psycopg import sql

logger = logging.getLogger(__name__)

load_dotenv()

pg_host = os.getenv("PG_HOST", "localhost")
db_port = os.getenv("DB_PORT", "5432")
pg_password = os.getenv("PG_PASSWORD", "postgresdb")
pg_user = os.getenv("PG_USER", "postgres")
db_name = os.getenv("DB_NAME", "ride_share")


def create_database() -> None:
    if not pg_user or not db_name:
        logger.error("PG_USER and DB_NAME must be set")
        sys.exit(1)

    try:
        with psycopg.connect(
            host=pg_host,
            port=db_port,
            user=pg_user,
            password=pg_password,
            dbname="postgres",
            autocommit=True,
        ) as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT 1 FROM pg_database WHERE datname = %s",
                    (db_name,),
                )
                if cursor.fetchone() is None:
                    cursor.execute(
                        sql.SQL("CREATE DATABASE {}").format(
                            sql.Identifier(db_name)
                        )
                    )
                    logger.info("Created database %s", db_name)
                else:
                    logger.info("Database %s already exists", db_name)
    except psycopg.errors.DuplicateDatabase:
        logger.info("Database %s was created by another process", db_name)
    except psycopg.Error:
        logger.exception("Could not create database %s", db_name)
        sys.exit(1)


if __name__ == "__main__":
    create_database()
