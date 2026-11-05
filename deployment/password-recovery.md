# Password recovery

For the Firebase test deployment, Supabase Authentication → URL Configuration
uses Site URL `https://plugy-test.web.app` and an allowed Redirect URL of
`https://plugy-test.web.app/**`. The wildcard is an allow-list pattern, not a page.
The actual form URL is `https://plugy-test.web.app/reset-password`.

Web password reset requests explicitly return to `/reset-password` on the current
application origin. Dashboard-generated reset emails returning to the Site URL
also open the form when Supabase emits its verified password-recovery event.
The SDK handles both implicit recovery links and PKCE code exchange. No recovery
tokens are copied into outgoing reset URLs or application error messages.

The recovery screen takes precedence over normal startup/navigation and requires
a verified Supabase recovery session to save. Visiting the page alone or having
an unrelated signed-in session does not enable reset. Expired links show a request
for a fresh email. Users enter matching passwords of at least eight characters;
Supabase's configured password policy remains authoritative. On completion,
returning to sign-in signs out the local recovery session.

English/Arabic mobile tests cover validation, save failures, success and expired
links. Mocked Supabase tests verify recovery session acceptance, unrelated-session
rejection, password update and local sign-out under both brand configurations.
Live reset emails, credentials and Supabase configuration were not changed by
these tests. No SQL migration is required.
