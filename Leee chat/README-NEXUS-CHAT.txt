NEXUS CHAT - UPDATED PROJECT PACKAGE
====================================

FILES
-----
NEXUS-CHAT-upgraded.html      Main web app.
NEXUS-CHAT-supabase-setup.sql Database/storage/security migration.
manifest.webmanifest          PWA install metadata.
sw.js                         Service worker for app shell and push notifications.
nexus-icon.svg                App icon.
supabase/functions/send-push/index.ts
                              Server-side push sender (must be deployed/configured).

IMPORTANT SECURITY NOTE ABOUT PASSWORDS
---------------------------------------
This project intentionally DOES NOT save users' readable passwords in a custom database table.
Supabase Auth handles password verification, salted password hashes, sign-in and password reset.
The app cannot retrieve a user's original password. Do not create a plaintext password table and
never put a Supabase service_role/secret key in the HTML.

SETUP STEPS
-----------
1. Back up important Supabase data first.
2. In Supabase Dashboard > SQL Editor, run NEXUS-CHAT-supabase-setup.sql.
   It creates/migrates tables, moves old profile phone numbers to private_info, configures RLS,
   creates private/public storage buckets with 50 MiB per-file limits, and locks down call signaling.
3. In NEXUS-CHAT-upgraded.html, set:
   SUPABASE_URL = your project URL
   SUPABASE_ANON_KEY = your publishable/anon key
   Never use service_role here.
4. Host the app over HTTPS (localhost is okay for development). Put manifest.webmanifest,
   sw.js and nexus-icon.svg beside the HTML file.
5. STORAGE: profile pictures and public Moments videos are in nexus-public-media (public).
   Private chat attachments and voice notes are in nexus-chat-media (private). The configured
   per-file maximum is 50 MiB. Supabase plan/storage quotas still limit total stored data.
6. CALLS: configure a TURN service and fill TURN_CONFIG in the HTML with the real server URL,
   username and credential. STUN alone does not work across every carrier/NAT. Do not use made-up
   TURN credentials; get them from a TURN provider or your own coturn server.
7. PUSH NOTIFICATIONS:
   a. Generate a VAPID key pair with a trusted web-push tool, e.g. `npx web-push generate-vapid-keys`.
   b. Put the VAPID public key in VAPID_PUBLIC_KEY in the HTML.
   c. Deploy the folder `supabase/functions/send-push` as an Edge Function named send-push.
   d. Set Edge Function secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (for example
      mailto:your-real-admin-email@example.com), plus standard Supabase environment variables.
      SUPABASE_SERVICE_ROLE_KEY must exist only as a server-side Edge Function secret.
   e. Enable notifications from inside NEXUS CHAT on each device. Push support depends on browser,
      OS, HTTPS, notification permissions, and on iOS typically installing the web app to Home Screen.
8. TEST with two different user accounts/devices: signup/login, text messages, read receipts,
   image/video/voice uploads, profile picture, contact picker (if supported), Moments, call both ways,
   push notifications while the app is backgrounded/closed, and logout.

LIMITATIONS / IMPORTANT NOTES
-----------------------------
- Contact Picker availability is browser-dependent. The app only imports contacts the user selects;
  it cannot silently read the entire phone address book. iOS browser support is limited.
- Push notifications do not work until VAPID keys and the Edge Function are configured and deployed.
- Calls require camera/microphone permissions and HTTPS; TURN credentials are required for dependable
  connectivity on many mobile networks. Test calls with two real devices on different networks.
- The SQL setup is a migration and intentionally removes older RLS policies on the NEXUS-owned app
  tables before adding the safer policies. Back up first and run only on the intended project.
- Passwords are never shown or recoverable by the app. Users who forget them must use password reset.
- This is a project baseline, not a guarantee of production readiness; run real-device and security
  testing before opening it to the public.
