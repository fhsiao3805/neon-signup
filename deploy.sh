#!/usr/bin/env bash
# deploy.sh — deploy this app to Cloud Run, with its secrets in Secret Manager.
#
# Reads the values from .env but never uploads .env itself (see .gcloudignore):
#   DATABASE_URL, SECRET_KEY         -> Secret Manager secrets of the same name.
#                                       Created from .env on first run; secrets
#                                       that already exist are left alone.
#   SITE_NAME, ADMIN_USERNAME, TIMEZONE, ATTACHMENTS_BUCKET
#                                    -> plain environment variables on the service.
#
# Usage, from the app folder, after `gcloud auth login`:
#   bash deploy.sh                       deploy signup-messi to gcloud's current project
#   bash deploy.sh --update-secrets      also push .env's DATABASE_URL and SECRET_KEY
#                                        as new secret versions (changes production!)
#   bash deploy.sh --project ID --region us-west1 --app signup-messi
#
# Project setup (billing, APIs, build permission) is gcp_setup.sh's job: run it once first.

set -u

usage() { sed -n '2,/^$/p' "$0"; }

APP="signup-messi"
PROJECT=""
REGION=""
UPDATE_SECRETS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --app)     APP="$2"; shift 2 ;;
    --update-secrets) UPDATE_SECRETS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; echo "Run: bash deploy.sh --help"; exit 1 ;;
  esac
done

step() { echo; echo "== $1"; }
fail() { echo "ERROR: $1"; exit 1; }

# The value of one variable in .env (first match; Windows line endings tolerated).
env_value() { grep -m1 "^$1=" .env | cut -d= -f2- | tr -d '\r'; }

[ -f .env ] || fail "no .env here. Run this script from the folder of your app."
[ -f app.py ] || fail "no app.py here. Run this script from the folder of your app."

if [ -z "$PROJECT" ]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null)
  [ -z "$PROJECT" ] && fail "no --project given and gcloud has no current project."
fi
if [ -z "$REGION" ]; then
  REGION=$(gcloud config get-value run/region 2>/dev/null)
  [ -z "$REGION" ] && REGION="us-west1"
fi

step "1. Project $PROJECT, region $REGION, service $APP"
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
[ -z "$ACCOUNT" ] && fail "not logged in. Run: gcloud auth login   and then run this script again."
echo "Logged in as $ACCOUNT"
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)" 2>/dev/null)
[ -z "$PROJECT_NUMBER" ] && fail "cannot read project $PROJECT. Does it exist, and are you allowed to use it?"
# Cloud Run runs the app as the project's default compute service account.
SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"

step "2. Secrets in Secret Manager"
gcloud services enable secretmanager.googleapis.com --project "$PROJECT" --quiet \
  || fail "could not enable the Secret Manager API"
for NAME in DATABASE_URL SECRET_KEY; do
  VALUE=$(env_value "$NAME")
  [ -z "$VALUE" ] && fail "$NAME is empty in .env"
  if gcloud secrets describe "$NAME" --project "$PROJECT" >/dev/null 2>&1; then
    if [ "$UPDATE_SECRETS" = 1 ]; then
      printf '%s' "$VALUE" | gcloud secrets versions add "$NAME" --project "$PROJECT" --data-file=- >/dev/null \
        || fail "could not add a new version of $NAME"
      echo "$NAME: new version added from .env"
    else
      echo "$NAME: already exists, left as is (--update-secrets pushes the value in .env)"
    fi
  else
    printf '%s' "$VALUE" | gcloud secrets create "$NAME" --project "$PROJECT" \
        --replication-policy=automatic --data-file=- >/dev/null \
      || fail "could not create secret $NAME"
    echo "$NAME: created from .env"
  fi
  gcloud secrets add-iam-policy-binding "$NAME" --project "$PROJECT" \
      --member="serviceAccount:$SA" --role="roles/secretmanager.secretAccessor" \
      --condition=None --quiet >/dev/null \
    || fail "could not let $SA read $NAME"
done
echo "$SA can read both secrets"

step "3. Deploy $APP to $REGION"
# ^|^ makes | the separator, so values may contain commas.
ENV_VARS="^|^SITE_NAME=$(env_value SITE_NAME)|ADMIN_USERNAME=$(env_value ADMIN_USERNAME)"
TIMEZONE=$(env_value TIMEZONE)
[ -n "$TIMEZONE" ] && ENV_VARS="$ENV_VARS|TIMEZONE=$TIMEZONE"
ATTACHMENTS_BUCKET=$(env_value ATTACHMENTS_BUCKET)
[ -n "$ATTACHMENTS_BUCKET" ] && ENV_VARS="$ENV_VARS|ATTACHMENTS_BUCKET=$ATTACHMENTS_BUCKET"
gcloud run deploy "$APP" --source . --project "$PROJECT" --region "$REGION" \
    --allow-unauthenticated --quiet \
    --set-secrets="DATABASE_URL=DATABASE_URL:latest,SECRET_KEY=SECRET_KEY:latest" \
    --set-env-vars="$ENV_VARS" \
  || fail "deploy failed. Read the message above."

echo
echo "Your website:"
gcloud run services describe "$APP" --project "$PROJECT" --region "$REGION" --format="value(status.url)"
echo
echo "Done."
