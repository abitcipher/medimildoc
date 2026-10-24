import { readFileSync, existsSync } from 'node:fs';
import typescript from '@rollup/plugin-typescript';
import replace from '@rollup/plugin-replace';

// Minimal .env parser — deliberately not the `dotenv` package: this is a
// single KEY=VALUE-per-line file with no interpolation/multiline/export
// syntax to support, and pulling in a whole dependency for that felt like
// more than this needed (justify every new dependency).
// `@rollup/plugin-replace` below *is* a real, justified addition — it's
// the standard Rollup-ecosystem way to swap `process.env.X` references
// for literal values at build time (same publisher as the
// `@rollup/plugin-typescript` already in use), which is otherwise
// unavailable here: GAS's V8 runtime has no `process` global at all (see
// this file's own header comment on why nothing in dist/ can reference
// one).
function loadDotEnv(path) {
  if (!existsSync(path)) return {};
  const env = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/);
    if (match) env[match[1]] = match[2];
  }
  return env;
}

// APP_ORIGIN used to be a hand-edited `const` in
// src/main.ts, swapped back and forth between the real deploy and a
// local tunnel URL for every dev/push cycle (exactly the kind of manual
// step that's easy to forget — confirmed live, more than once this
// session, pushing with the wrong origin still baked in). Now it's
// build-time config instead: apps_script/.env (gitignored, mirrors
// infra/.env's own pattern) for local overrides, falling back to the
// real deployed origin so a plain `npm run push` with no .env at all
// still does the right (production) thing.
const env = loadDotEnv(new URL('.env', import.meta.url).pathname);
const appOrigin = env.APP_ORIGIN || 'https://hrda.artcomplect.com';

// GAS's V8 runtime executes each file as global (script) scope, not a
// module — there's no `require`/`import` at runtime. `format: 'es'` is a
// deliberate trick, not the "real" output type: with no actual external
// imports/exports left in the bundle, Rollup's ESM output degenerates to
// plain top-level statements with no wrapper, so onOpen/showSidebar/
// getContext land as plain global function declarations that Apps Script
// can call directly. `iife`/`cjs` would hide them inside a closure instead.
export default {
  input: 'src/main.ts',
  // GAS calls onOpen/showSidebar/getContext from outside the bundle — Rollup
  // sees no in-bundle caller and, with tree-shaking on, drops all of them
  // (confirmed: it emitted an empty chunk). Must stay off for this entry.
  treeshake: false,
  output: {
    file: 'dist/main.js',
    format: 'es',
  },
  plugins: [
    replace({
      preventAssignment: true,
      values: {
        'process.env.APP_ORIGIN': JSON.stringify(appOrigin),
      },
    }),
    typescript(),
  ],
};
