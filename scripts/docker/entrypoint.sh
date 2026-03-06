#!/bin/bash

set -Eeo pipefail

# set environment variables with docker secrets in /run/secrets/*
supportedSecrets=( "DB_PASSWORD"
                   "DATABASE_URL"
                   "APP_KEY"
                   "MAIL_PASSWORD"
                   "REDIS_PASSWORD"
                   "AWS_ACCESS_KEY_ID"
                   "AWS_SECRET_ACCESS_KEY"
                   "AWS_KEY"
                   "AWS_SECRET"
                   "LOCATION_IQ_API_KEY"
                   "WEATHERAPI_KEY"
                   "MAPBOX_API_KEY"
                  )

for secret in "${supportedSecrets[@]}"; do
    envFile="${secret}_FILE"
    if [ -n "${!envFile}" ] && [ -f "${!envFile}" ]; then
        val="$(< "${!envFile}")"
        export "${secret}"="$val"
        echo "${secret} environment variable was set by secret ${envFile}"
    fi
done

if expr "$1" : "apache" 1>/dev/null || [ "$1" = "php-fpm" ]; then

    ROOT=/var/www/html
    ARTISAN="php ${ROOT}/artisan"

    # Avoid stale bootstrap/cache config using old environment values.
    ${ARTISAN} config:clear >/dev/null 2>&1 || true

    # Ensure only one Apache MPM is enabled at runtime.
    a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
    a2enmod mpm_prefork >/dev/null 2>&1 || true

    # Railway expects the app to listen on $PORT.
    APP_PORT="${PORT:-80}"
    sed -ri "s/^Listen [0-9]+$/Listen ${APP_PORT}/" /etc/apache2/ports.conf
    sed -ri "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${APP_PORT}>/" /etc/apache2/sites-available/000-default.conf
    echo "Apache configured to listen on port ${APP_PORT}."

    # Ensure storage directories are present
    STORAGE=${ROOT}/storage
    mkdir -p ${STORAGE}/logs
    mkdir -p ${STORAGE}/app/public
    mkdir -p ${STORAGE}/framework/views
    mkdir -p ${STORAGE}/framework/cache
    mkdir -p ${STORAGE}/framework/sessions
    chown -R www-data:www-data ${STORAGE}
    chmod -R g+rw ${STORAGE}

    # Fallback to SQLite when an unreachable local MariaDB/MySQL config is present.
    if [ "${DB_CONNECTION:-sqlite}" = "mariadb" ] || [ "${DB_CONNECTION:-sqlite}" = "mysql" ]; then
        if [ -z "${DB_HOST:-}" ] || [ "${DB_HOST:-}" = "127.0.0.1" ] || [ "${DB_HOST:-}" = "localhost" ]; then
            echo "DB_CONNECTION=${DB_CONNECTION} with DB_HOST=${DB_HOST:-<empty>} is not usable on Railway single-service deploy; falling back to sqlite."
            export DB_CONNECTION="sqlite"
            unset DATABASE_URL
        fi
    fi

    if [ "${DB_CONNECTION:-sqlite}" == "sqlite" ]; then
        dbPath="${DB_DATABASE:-/var/www/html/storage/database.sqlite}"
        export DB_DATABASE="$dbPath"
        unset SESSION_CONNECTION
        if [ ! -f "$dbPath" ]; then
            echo "Creating sqlite database at ${dbPath} — make sure it will be saved in a persistent volume."
            touch "$dbPath"
            chown www-data:www-data "$dbPath"
        fi
    fi

    if [ -z "${APP_KEY:-}" ]; then
        ${ARTISAN} key:generate --no-interaction
        key=$(grep APP_KEY .env | cut -c 9-)
        echo "APP_KEY generated: $key — save it for later usage."
    else
        echo "APP_KEY already set."
    fi

    # Run database bootstrap but do not block web startup if setup fails.
    if ! ${ARTISAN} waitfordb; then
        echo "Warning: waitfordb failed, continuing startup so the app logs remain accessible."
    fi

    # monica:setup can fail in non-interactive cloud boots (docs/scout prompts).
    # Use a minimal, deterministic bootstrap for Railway runtime.
    if ! ${ARTISAN} migrate --force; then
        echo "Warning: migrate failed, continuing startup."
    fi
    if ! ${ARTISAN} scout:setup --force; then
        echo "Warning: scout:setup failed, continuing startup."
    fi

    # if [ ! -f "${STORAGE}/oauth-public.key" -o ! -f "${STORAGE}/oauth-private.key" ]; then
    #     echo "Passport keys creation ..."
    #     ${ARTISAN} passport:keys
    #     ${ARTISAN} passport:client --personal --no-interaction
    #     echo "! Please be careful to backup $ROOT/storage/oauth-public.key and $ROOT/storage/oauth-private.key files !"
    # fi

fi

exec "$@"
