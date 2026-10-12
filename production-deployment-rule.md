# LAVIDA Production Deployment Rule

The one and only production domain for LAVIDA Connect is:

https://app.lavida.agency

All production deployments, production origins, authentication redirects, payment callbacks, email links, CORS settings, canonical URLs, PWA configuration, environment variables, and hosting or DNS changes must preserve this origin.

Do not replace it with `app.lavida.com`, `lavida.com`, a `chatgpt.site` URL, a preview URL, localhost, or a newly created production instance. Preview URLs may be used only for internal testing.

Before deployment, verify:

- production domain is `app.lavida.agency`;
- production origin is `https://app.lavida.agency`;
- no unintended `app.lavida.com` configuration exists;
- existing Supabase, authentication, payment, order, pricing, printing, marketplace, professional services, notification, and user data remain intact;
- the build or static publish output succeeds;
- deployment targets the existing LAVIDA project.

If deployment is blocked by Git, DNS, hosting, Cloudflare, Supabase, or another dependency, do not change domains as a workaround. Fix the deployment configuration or report the exact blocker and required owner action.
