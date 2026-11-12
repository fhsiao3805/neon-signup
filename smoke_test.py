import atexit
import os
import re
import sys
import uuid
from datetime import timedelta
from pathlib import Path

os.chdir(Path(__file__).resolve().parent)
sys.path.insert(0, os.getcwd())

import psycopg
from psycopg.conninfo import make_conninfo

# If TEST_DATABASE_URL is set (CI sets it to a Postgres started inside the
# job), run against that database instead of DATABASE_URL. This has to happen
# before app is imported: app reads DATABASE_URL and creates its tables at
# import time, and load_dotenv does not override variables that are already set.
test_database_url = os.environ.get("TEST_DATABASE_URL", "").strip()
if test_database_url:
    os.environ["DATABASE_URL"] = test_database_url

import app as appmod

# Run against a throwaway schema in the configured database so the smoke
# test never touches the real tables; the schema is dropped at the end.
# The schema is selected with a startup option, which Neon's connection
# pooler rejects, so use the direct endpoint (drop "-pooler" from the host).
schema = "smoke_" + uuid.uuid4().hex[:12]
direct_url = appmod.DATABASE_URL.replace("-pooler.", ".")
test_url = make_conninfo(direct_url, options=f"-c search_path={schema}")
with psycopg.connect(direct_url, autocommit=True) as conn:
    conn.execute(f"CREATE SCHEMA {schema}")


def drop_schema():
    with psycopg.connect(direct_url, autocommit=True) as conn:
        conn.execute(f"DROP SCHEMA {schema} CASCADE")


atexit.register(drop_schema)
appmod.DATABASE_URL = test_url
appmod.ADMIN_USERNAME = "alice"

# Start from the old weekday-based schema with one booking in it, so that
# init_db's migration is exercised too.
this_monday = appmod.week_start(appmod.now().date())
with psycopg.connect(appmod.DATABASE_URL) as conn:
    conn.execute(
        "CREATE TABLE users (id INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,"
        " username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL)"
    )
    conn.execute(
        "CREATE TABLE bookings (id INTEGER PRIMARY KEY GENERATED ALWAYS AS IDENTITY,"
        " weekday INTEGER NOT NULL, start TEXT NOT NULL,"
        " user_id INTEGER NOT NULL REFERENCES users(id), UNIQUE (weekday, start))"
    )
    conn.execute("INSERT INTO users (username, password_hash) VALUES ('legacy', 'x')")
    conn.execute("INSERT INTO bookings (weekday, start, user_id) VALUES (1, '14:00', 1)")
appmod.init_db()
with psycopg.connect(appmod.DATABASE_URL) as conn:
    row = conn.execute("SELECT day, start FROM bookings").fetchone()
    assert row == (this_monday + timedelta(days=1), "14:00"), row
    cols = [r[0] for r in conn.execute(
        "SELECT column_name FROM information_schema.columns"
        " WHERE table_schema = current_schema() AND table_name = 'bookings'")]
    assert "weekday" not in cols and "day" in cols, cols
appmod.app.config["TESTING"] = True
c = appmod.app.test_client()

def body(r):
    return r.get_data(as_text=True)

r = c.get("/")
assert r.status_code == 200 and "not logged in" in body(r), body(r)

r = c.post("/register", data={"username": "alice", "password": "pw"}, follow_redirects=True)
assert "Account created" in body(r), body(r)

r = c.post("/register", data={"username": "alice", "password": "pw"})
assert "already taken" in body(r), body(r)

r = c.post("/register", data={"username": "", "password": "pw"})
assert "Username is required" in body(r), body(r)

r = c.post("/login", data={"username": "alice", "password": "wrong"})
assert "Incorrect" in body(r), body(r)

r = c.post("/login", data={"username": "alice", "password": "pw"}, follow_redirects=True)
assert "logged in as <strong>alice</strong>" in body(r), body(r)

r = c.post("/logout", follow_redirects=True)
assert "logged out" in body(r) and "not logged in" in body(r), body(r)

r = c.post("/logout", follow_redirects=True)
assert "Please log in first" in body(r), body(r)

# Password must be hashed, not stored in plain text.
with psycopg.connect(appmod.DATABASE_URL) as conn:
    row = conn.execute("SELECT password_hash FROM users WHERE username = 'alice'").fetchone()
assert row[0] != "pw" and row[0].startswith(("scrypt:", "pbkdf2:")), row

# --- Sign-up sheet ---------------------------------------------------------

def login(username):
    c.post("/logout")
    r = c.post("/login", data={"username": username, "password": "pw"}, follow_redirects=True)
    assert f"Welcome, {username}" in body(r), body(r)

def th_count(html):
    return len(re.findall(r"<th[ >]", html))

# The sheet needs a login.
r = c.get("/sheet", follow_redirects=True)
assert "Please log in first" in body(r), body(r)

c.post("/register", data={"username": "bob", "password": "pw"})

# Work in next week, so every slot is still in the future.
monday = this_monday + timedelta(days=7)
wed = monday + timedelta(days=2)
sunday = monday + timedelta(days=6)
week = f"/sheet?week={monday.isoformat()}"
when = f"{appmod.format_day(wed)} at 2:30 pm"
slot = {"day": wed.isoformat(), "start": "14:30"}

# alice is ADMIN_USERNAME, so she is the administrator.
login("alice")
r = c.get("/sheet")
assert r.status_code == 200 and "You are the administrator" in body(r), body(r)
assert "Week of" in body(r) and "Next week" in body(r), body(r)
r = c.get(week)
assert th_count(body(r)) == 1 + 7 + 4, body(r)              # corner, 7 days, 4 time rows
assert body(r).count(">Book</button>") == 28, body(r)        # all 28 slots free
assert re.search(r"<th[^>]*>Monday<", body(r)).start() < re.search(r"<th[^>]*>Sunday<", body(r)).start(), body(r)
assert f"{sunday:%b} {sunday.day}" in body(r), body(r)       # the week ends on Sunday
assert "2:00 pm" in body(r) and "4:00 pm" in body(r), body(r)
assert f"{wed:%b} {wed.day}" in body(r), body(r)             # real dates in the header
assert "This week" in body(r), body(r)                       # link back from another week

# Two weeks ago is entirely in the past: nothing can be booked there.
past_monday = this_monday - timedelta(days=14)
r = c.get(f"/sheet?week={past_monday.isoformat()}")
assert r.status_code == 200 and ">Book</button>" not in body(r), body(r)

# bob is not the administrator; he books a slot.
login("bob")
r = c.get(week)
assert "You are the administrator" not in body(r), body(r)
r = c.post("/book", data=slot, follow_redirects=True)
assert f"Booked {when}" in body(r), body(r)
assert "Yours" in body(r) and ">Cancel</button>" in body(r), body(r)
assert body(r).count(">Book</button>") == 27, body(r)

# Sunday is part of the week: bob can book a Sunday slot, it shows in the
# same week as Monday, and he can cancel it again.
sunday_slot = {"day": sunday.isoformat(), "start": "15:00"}
r = c.post("/book", data=sunday_slot, follow_redirects=True)
assert f"Booked {appmod.format_day(sunday)} at 3:00 pm" in body(r), body(r)
assert f"Week of {appmod.format_day(monday)}" in body(r), body(r)
assert body(r).count(">Cancel</button>") == 2, body(r)
assert body(r).count(">Book</button>") == 26, body(r)
with psycopg.connect(appmod.DATABASE_URL) as conn:
    row = conn.execute("SELECT day FROM bookings WHERE start = '15:00'").fetchone()
assert row == (sunday,) and row[0].weekday() == 6, row
r = c.post("/book", data=sunday_slot, follow_redirects=True)
assert "already been taken" in body(r), body(r)
r = c.post("/cancel", data=sunday_slot, follow_redirects=True)
assert f"Cancelled {appmod.format_day(sunday)} at 3:00 pm" in body(r), body(r)
assert body(r).count(">Book</button>") == 27, body(r)

# A Saturday slot can be booked too.
saturday = monday + timedelta(days=5)
r = c.post("/book", data={"day": saturday.isoformat(), "start": "14:30"}, follow_redirects=True)
assert f"Booked {appmod.format_day(saturday)} at 2:30 pm" in body(r), body(r)
c.post("/cancel", data={"day": saturday.isoformat(), "start": "14:30"})

# A Sunday in the past cannot be booked.
past_sunday = this_monday - timedelta(days=1)
r = c.post("/book", data={"day": past_sunday.isoformat(), "start": "14:30"}, follow_redirects=True)
assert "in the past" in body(r), body(r)

# Booking the same slot twice, an invalid slot, or a past slot fails.
r = c.post("/book", data=slot, follow_redirects=True)
assert "already been taken" in body(r), body(r)
r = c.post("/book", data={"day": "not-a-date", "start": "14:30"}, follow_redirects=True)
assert "not a valid slot" in body(r), body(r)
r = c.post("/book", data={"day": wed.isoformat(), "start": "16:00"}, follow_redirects=True)
assert "not a valid slot" in body(r), body(r)
r = c.post("/book", data={"day": past_monday.isoformat(), "start": "14:30"}, follow_redirects=True)
assert "in the past" in body(r), body(r)

# A third user sees the slot as taken, without the name, and cannot book or cancel it.
c.post("/register", data={"username": "carol", "password": "pw"})
login("carol")
r = c.get(week)
assert ">Taken</span>" in body(r) and "bob" not in body(r).split("<table")[1], body(r)
r = c.post("/book", data=slot, follow_redirects=True)
assert "already been taken" in body(r), body(r)
r = c.post("/cancel", data=slot, follow_redirects=True)
assert "no booking in that slot" in body(r) and ">Taken</span>" in body(r), body(r)

# The administrator sees who booked it.
login("alice")
r = c.get(week)
assert "Taken by <strong>bob</strong>" in body(r), body(r)

# bob cancels his own booking and the slot is free again.
login("bob")
r = c.post("/cancel", data=slot, follow_redirects=True)
assert f"Cancelled {when}" in body(r), body(r)
assert body(r).count(">Book</button>") == 28, body(r)

print("ALL SMOKE TESTS PASSED")
