// `process.env.APP_ORIGIN` in main.ts is never actually
// evaluated at runtime: `@rollup/plugin-replace` (rollup.config.mjs)
// substitutes it for a literal string at build time, before GAS's V8
// runtime (which has no `process` global at all — see main.ts's own
// header comment) ever sees the compiled output. This ambient
// declaration exists only so `tsc --noEmit`/editor tooling sees a valid
// reference here, without pulling in the full `@types/node` package for
// one global.
declare const process: { env: { APP_ORIGIN?: string } };
