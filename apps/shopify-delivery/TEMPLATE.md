# Provenance: what in this directory is Shopify's template

This app started as Shopify's React Router app template, copied verbatim from
https://github.com/Shopify/shopify-app-template-react-router at commit
`e548c959eb00460f7141d42bd694cd50769c5e3e` (2026-09-08, "pin react-router 7.18.2").
The template is MIT-licensed (`LICENSE.md`, copyright Shopify).

Not copied: the template repo's `.github/`, and its agent config files (`.claude/`,
`.cursor/`, `.gemini/`, `.mcp.json`, `CLAUDE.md`, `AGENTS.md`).
`shopify.web.toml.liquid` was rendered to `shopify.web.toml` for npm, as `shopify app init`
would have done. The template's README is kept as `TEMPLATE-README.md`.

Template files this project changed, each in a later commit: `app/shopify.server.ts` (API
version 2026-07, an `afterAuth` hook that opens the shop's intake window),
`shopify.app.toml` (scopes and the orders webhooks), `package.json` (scripts and
dependencies), and `.gitignore` (the lockfile is committed so CI can `npm ci`).

**Template-provided, and not claimed as this project's work:** OAuth and the install flow,
session storage (Prisma, SQLite), webhook HMAC verification (`authenticate.webhook`), the
Admin GraphQL client (`admin.graphql`, `unauthenticated.admin`), App Bridge, and every file
in the first commit that added this directory. `git log --follow` on any file shows
whether it came from that commit.
