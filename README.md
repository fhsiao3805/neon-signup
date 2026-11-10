# signup

The office-hours sign-up sheet from *Building Software Systems with AI*, as it is at the end of chapter 11, *Adding Accounts and a Database*: accounts, the sheet, a SQLite database, and the Google Cloud setup script `gcp_setup.sh`. This is the starting point for chapter 12, *Deployment*.

To start chapter 12 from here: click *Use this template* on GitHub, name your repository `signup`, clone it into your home folder, then in `~/signup`:

```
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # then fill in the values
flask --app app run
```

The app is configured through a `.env` file next to `app.py` (never commit it):

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | Postgres connection string, e.g. from Neon |
| `SECRET_KEY` | Random value that signs the session cookie: `python -c "import secrets; print(secrets.token_hex(32))"` |
| `SITE_NAME` | Title shown in the browser tab and page header |
| `ADMIN_USERNAME` | The user who can see who booked each slot |
| `TIMEZONE` | Optional IANA zone the office hours are in, e.g. `America/Los_Angeles` (default: the system zone) |

`python smoke_test.py` runs the end-to-end checks in a throwaway schema of the same database.

## Deploying to Cloud Run

`gcp_setup.sh` prepares the Google Cloud project (billing, APIs, build permission). After that, `deploy.sh` deploys the app:

```
bash deploy.sh
```

It stores `DATABASE_URL` and `SECRET_KEY` as Secret Manager secrets (created from `.env` the first time, then left alone unless you pass `--update-secrets`), passes `SITE_NAME`, `ADMIN_USERNAME` and `TIMEZONE` as plain environment variables, and never uploads `.env` itself (`.gcloudignore`). `Procfile` tells Cloud Run to serve the app with gunicorn.
