#!/usr/bin/env bash
# gcp_setup.sh — set up a Google Cloud project for a Flask app and deploy it.
#
# Not interactive: all arguments up front, nothing is asked. Log in first
# with: gcloud auth login
# Safe to run more than once: every step checks first and skips what is done,
# so on a project that is already set up it goes straight to the deploy.
#
# Usage (Mac terminal or Git Bash on Windows), from the folder of your app:
#   bash gcp_setup.sh --project my-app-4821 --billing 0A1B2C-3D4E5F-6A7B8C
#   bash gcp_setup.sh --project my-app-4821      (project already has billing)
#   bash gcp_setup.sh --deploy-only              (redeploy gcloud's current project)
#   bash gcp_setup.sh                            (print this help)
#
# Options:
#   --project  ID     the project id. Lowercase letters, digits, hyphens.
#                     If it does not exist it is created. If it exists it is reused.
#                     Default: gcloud's current project (gcloud config get-value project).
#   --billing  ID     your billing account id. Needed only if the project has no
#                     billing yet. Find it with: gcloud billing accounts list
#   --app      NAME   the website name on Cloud Run (default: the project id)
#   --region   NAME   where it runs (default: us-west1)
#   --no-deploy       do everything except the deploy
#   --deploy-only     skip the setup checks (steps 2-5) and just deploy. Faster, but
#                     if the project is not set up you get Google's raw error.

set -u

usage() { sed -n '2,/^$/p' "$0"; }

if [ $# -eq 0 ]; then usage; exit 0; fi

PROJECT=""
BILLING=""
APP=""
REGION="us-west1"
DEPLOY=1
DEPLOY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --billing) BILLING="$2"; shift 2 ;;
    --app)     APP="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --no-deploy) DEPLOY=0; shift ;;
    --deploy-only) DEPLOY_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; echo "Run: bash gcp_setup.sh --help"; exit 1 ;;
  esac
done

if [ "$DEPLOY" = 0 ] && [ "$DEPLOY_ONLY" = 1 ]; then
  echo "--no-deploy and --deploy-only together would do nothing. Pick one."
  exit 1
fi

if [ -z "$PROJECT" ]; then
  # No --project: use the project gcloud is pointed at (the last one this script set up).
  PROJECT=$(gcloud config get-value project 2>/dev/null)
  if [ -z "$PROJECT" ]; then
    echo "No --project given and gcloud has no current project."
    echo "Example: bash gcp_setup.sh --project my-app-4821 --billing 0A1B2C-3D4E5F-6A7B8C"
    exit 1
  fi
  echo "No --project given. Using gcloud's current project: $PROJECT"
fi
[ -z "$APP" ] && APP="$PROJECT"

step() { echo; echo "== $1"; }
fail() { echo "ERROR: $1"; exit 1; }

deploy_app() {
  # Cloud Run builds from a Dockerfile if there is one, otherwise it detects the
  # language (Python, Node.js, ...). This only checks we are in an app folder.
  if [ ! -f requirements.txt ] && [ ! -f package.json ] && [ ! -f Dockerfile ]; then
    fail "no requirements.txt, package.json or Dockerfile here. Run this script from the folder of your app, or use --no-deploy."
  fi
  # On a new project, the roles/run.builder grant from step 5 can take a minute
  # or two to take effect, and the first deploy fails with PERMISSION_DENIED.
  # Retry that case only; any other error fails right away.
  LOG=$(mktemp)
  OK=0
  for i in 1 2 3 4; do
    gcloud run deploy "$APP" --source . --project "$PROJECT" --region "$REGION" --allow-unauthenticated --quiet 2>&1 | tee "$LOG"
    if [ "${PIPESTATUS[0]}" = 0 ]; then OK=1; break; fi
    grep -q "PERMISSION_DENIED" "$LOG" || break
    [ "$i" = 4 ] && break
    echo "build permission not active yet, waiting 60 s and trying again ($i/3)..."; sleep 60
  done
  rm -f "$LOG"
  [ "$OK" = 1 ] || fail "deploy failed. Read the message above."
  echo
  echo "Your website:"
  gcloud run services describe "$APP" --project "$PROJECT" --region "$REGION" --format="value(status.url)"
}

# 1. Logged in? The script never asks. Log in before running it.
step "1. Google account"
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
[ -z "$ACCOUNT" ] && fail "not logged in. Run: gcloud auth login   and then run this script again."
echo "Logged in as $ACCOUNT"

if [ "$DEPLOY_ONLY" = 1 ]; then
  step "Deploy $APP to $REGION (--deploy-only: setup checks skipped)"
  deploy_app
  echo
  echo "Done."
  exit 0
fi

# 2. Project exists? Create it if not.
step "2. Project $PROJECT"
# describe also succeeds for a project pending deletion, so look at its state.
STATE=$(gcloud projects describe "$PROJECT" --format="value(lifecycleState)" 2>/dev/null)
if [ "$STATE" = "ACTIVE" ]; then
  echo "Project exists. Reusing it."
elif [ -n "$STATE" ]; then
  fail "project $PROJECT is $STATE (deleted). Restore it with: gcloud projects undelete $PROJECT   or pick another id."
else
  [ -z "$BILLING" ] && fail "project $PROJECT does not exist, and a new project needs --billing."
  echo "Creating project..."
  gcloud projects create "$PROJECT" --name="$PROJECT" --quiet \
    || fail "could not create $PROJECT. Project ids are unique across all of Google Cloud; pick another id."
fi
gcloud config set project "$PROJECT" --quiet
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format="value(projectNumber)")
echo "Project number: $PROJECT_NUMBER"

# 3. Billing linked? Link it if not.
step "3. Billing"
BILLING_ON=$(gcloud billing projects describe "$PROJECT" --format="value(billingEnabled)" 2>/dev/null)
LINKED=$(gcloud billing projects describe "$PROJECT" --format="value(billingAccountName)" 2>/dev/null)
if [ "$BILLING_ON" = "True" ]; then
  echo "Billing is on ($LINKED). Leaving it."
elif [ -z "$BILLING" ]; then
  fail "project $PROJECT has no billing. Run again with --billing ID (find it with: gcloud billing accounts list)."
else
  # A project created seconds ago can refuse the link for a short while. Retry.
  OK=0
  for i in 1 2 3 4 5 6; do
    if gcloud billing projects link "$PROJECT" --billing-account="$BILLING" --quiet; then OK=1; break; fi
    echo "link refused, waiting 15 s and trying again ($i/6)..."; sleep 15
  done
  [ "$OK" = 1 ] || fail "could not link billing after 6 tries. Link it in the console, then run this script again."
  echo "Linked."
fi

# 4. APIs on? Turn on the ones a source deploy needs.
step "4. APIs"
NEEDED="run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com compute.googleapis.com"
ENABLED=$(gcloud services list --enabled --format="value(config.name)" 2>/dev/null)
TO_ENABLE=""
for api in $NEEDED; do
  if echo "$ENABLED" | grep -qx "$api"; then
    echo "on:  $api"
  else
    TO_ENABLE="$TO_ENABLE $api"
  fi
done
if [ -n "$TO_ENABLE" ]; then
  echo "turning on:$TO_ENABLE (this takes a minute)"
  gcloud services enable $TO_ENABLE --quiet || fail "could not enable APIs"
fi

# 5. Permission for the build. Cloud Build runs as the project's compute
#    service account, which needs roles/run.builder to deploy from source.
step "5. Build permission"
SA="$PROJECT_NUMBER-compute@developer.gserviceaccount.com"
HAS_ROLE=$(gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
  --filter="bindings.role=roles/run.builder AND bindings.members=serviceAccount:$SA" \
  --format="value(bindings.role)" 2>/dev/null)
if [ -n "$HAS_ROLE" ]; then
  echo "$SA already has roles/run.builder"
else
  FOUND=0
  for i in 1 2 3 4 5 6; do
    if gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then FOUND=1; break; fi
    echo "waiting for $SA to appear..."; sleep 10
  done
  [ "$FOUND" = 1 ] || fail "$SA does not exist. In an older project it may have been deleted or disabled; check IAM > Service accounts in the console."
  # --condition=None: older projects can have conditional bindings, and then
  # gcloud refuses to add a binding non-interactively without it.
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" --role="roles/run.builder" --condition=None --quiet >/dev/null \
    || fail "could not grant roles/run.builder to $SA. You need Owner or Project IAM Admin on $PROJECT."
  echo "$SA has roles/run.builder"
fi

# 6. Deploy.
if [ "$DEPLOY" = 1 ]; then
  step "6. Deploy $APP to $REGION"
  deploy_app
else
  step "6. Deploy skipped (--no-deploy)"
  echo "When ready, from the app folder:"
  echo "  gcloud run deploy $APP --source . --region $REGION --allow-unauthenticated"
fi

echo
echo "Done."