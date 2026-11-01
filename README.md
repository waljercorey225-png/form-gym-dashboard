# FORM local app

This demo uses CSV files as its local database. App data and API requests stay on this computer; it does not connect to Neon. The existing page still loads its fonts and gym image from Google Fonts and Unsplash.

## Start

Double-click the `FORM Gym Dashboard` shortcut on your Desktop. It starts the local server when needed and opens <http://localhost:4173/>. You can also run `start-local-server.cmd` manually.

Demo login: `corey` / `corey`.

## Local data

- `data/members.csv` stores demo accounts and subscription status.
- `data/plans.csv` stores the seven weekly workout plans.
- `data/exercises.csv` stores plan exercises and display details.
- `data/exercise_catalog.csv` stores the independent exercise library and strength/time-only entry type.
- `data/exercise_logs.csv` stores individual strength and timed exercise entries.
- `data/exercise_completions.csv` stores exercise checkoffs.
- `data/sessions.csv` stores completed sessions.
- `data/Steps.csv` and the local Garmin archive provide weekly movement and health metrics.
- `data/garmin-connect/` holds weekly CSV exports from Garmin Connect (Sleep, HRV Status, Resting Heart Rate, Stress, Body Battery, Steps). Drop new ones in and restart the server; they fill in or override the archive for the same dates.

Checkoffs and session logs are written to CSV as they happen. The API serves only on localhost. Authentication tokens are kept in memory and expire when the server stops. Passwords are plain text for this local demo; do not use real account credentials or expose the server to a network.

## Public access setup

The public version is hosted on GitHub Pages and cannot sign anyone in until Supabase is configured. The local CSV server must never be exposed to the internet. The public build uses Supabase Auth and Postgres row-level security instead; new cloud accounts start with subscriptions inactive. The schema includes the exercise library/logs and health-metric tables used by the new views.

1. Create a Supabase project and run `supabase/schema.sql` in its SQL Editor.
2. Copy `cloud-config.example.js` to `cloud-config.js`. Fill in the project URL and the public anon/publishable key from Supabase Project Settings. Never put a service-role key in this file.
3. Run `build-site.ps1`. It creates `dist` with only `index.html` and `cloud-config.js`; upload only that folder to a static host such as Netlify. Do not upload the workspace root or `data` folder.
4. Sign up from the hosted app with an email address and password, then confirm the email if prompted.
5. Replace `REPLACE_WITH_YOUR_SIGNUP_EMAIL` in `supabase/import-existing-data.sql` with that account email and run the script in Supabase SQL Editor. It imports the current steps, sessions, and exercise checkoffs and preserves the active flag from the local demo. Sign out and back in afterward.

The Garmin JSON archive is not included in the public build or current SQL import. The Metrics view reads it locally; adding those private health records to Supabase requires a separate, intentional import for the account owner.

The import script marks the selected account active to preserve the local demo state; this is not payment verification. New accounts remain inactive until authorized. Connect a billing provider before accepting real subscriptions. Supabase Auth handles passwords; the local plaintext demo password is not deployed.

The project has no Node/npm dependency. For phone access from anywhere, deploy the generated static bundle after configuring Supabase. Google Fonts and the existing gym image remain externally hosted assets.

## GitHub Pages

Every push to `main` publishes the site through `.github/workflows/pages.yml`, which replaces steps 2 and 3 above. Add the project URL and public anon/publishable key as repository variables named `SUPABASE_URL` and `SUPABASE_ANON_KEY` (Settings > Secrets and variables > Actions > Variables), then re-run the workflow.

The repository is public, so `.gitignore` allows only named app files. `data/`, `cloud-config.js`, and `supabase/import-existing-data.sql` stay on this computer.
